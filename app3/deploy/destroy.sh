#!/usr/bin/env bash
# destroy.sh - Destrucción completa de app3
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

sanity_check
ACCT="$(account_id)"
log "Destruyendo app3 en cuenta=${ACCT} region=${REGION}"

state() { state_get "$1"; }
PREFIX="${PREFIX:-aws-obs-app3}"
VPC_NAME="${PREFIX}-vpc"
DB_INSTANCE="${PREFIX}-db"
ALB_NAME="${PREFIX}-alb"
ASG_NAME="${PREFIX}-asg"
LT_NAME="${PREFIX}-lt"

VPC_ID=$(state VPC_ID)
# Si no hay VPC_ID en el estado, lo buscamos por nombre
if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  VPC_ID=$(awsc ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME}" --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")
fi

ALB_ARN=$(state ALB_ARN)
TG_ARN=$(state TG_ARN)
ASG_NAME=$(state ASG_NAME); [ -z "${ASG_NAME}" ] && ASG_NAME="${PREFIX}-asg"
LT_ID=$(state LT_ID)

# Cargamos recursos de red de forma dinámica desde AWS basándonos en la VPC
if [ -n "${VPC_ID}" ] && [ "${VPC_ID}" != "None" ]; then
  log "Cargando recursos de red de forma dinamica para la VPC ${VPC_ID}..."
  SUBNETS=$(awsc ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[*].SubnetId' --output text 2>/dev/null | tr '\t' ' ' || echo "")
  NAT_GW_ID=$(awsc ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" --query 'NatGateways[?State==`available` || State==`pending` || State==`deleting`].NatGatewayId' --output text 2>/dev/null || echo "")
  NAT_EIP_ALLOC=$(awsc ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" --query 'NatGateways[?State==`available` || State==`pending` || State==`deleting`].NatGatewayAddresses[0].AllocationId' --output text 2>/dev/null || echo "")
  IGW_ID=$(awsc ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=${VPC_ID}" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null || echo "")
  
  # Security groups creados
  SG_ALB_ID=$(awsc ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-sg-alb" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
  SG_APP_ID=$(awsc ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-sg-app" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
  SG_DB_ID=$(awsc ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-sg-db" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
else
  SUBNETS=""
  NAT_GW_ID=""
  NAT_EIP_ALLOC=""
  IGW_ID=""
  SG_ALB_ID=""
  SG_APP_ID=""
  SG_DB_ID=""
fi

# 1. Auto Scaling Group
log "[1/10] Auto Scaling Group"
if [ -n "${ASG_NAME}" ]; then
  ASG_EXIST_CHECK=$(awsc autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME}" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null || echo "")
  if [ -n "${ASG_EXIST_CHECK}" ] && [ "${ASG_EXIST_CHECK}" != "None" ]; then
    awsc autoscaling update-auto-scaling-group --auto-scaling-group-name "${ASG_NAME}" --min-size 0 --max-size 0 --desired-capacity 0 >/dev/null || true
    awsc autoscaling delete-auto-scaling-group --auto-scaling-group-name "${ASG_NAME}" --force-delete >/dev/null || true
    ok "ASG ${ASG_NAME} borrado"
  else
    ok "ASG ya no existe"
  fi
fi

# 2. Launch Template
log "[2/10] Launch Template"
LT_ID=$(state LT_ID)
if [ -n "${LT_ID}" ]; then
  if awsc ec2 describe-launch-templates --launch-template-ids "${LT_ID}" >/dev/null 2>&1; then
    awsc ec2 delete-launch-template --launch-template-id "${LT_ID}" >/dev/null
    ok "Launch Template borrado"
  else
    ok "Launch Template ya no existe"
  fi
fi

# 3. Target Group & ALB
log "[3/10] Target Group & ALB"
if [ -n "${ALB_ARN}" ] && awsc elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" >/dev/null 2>&1; then
  awsc elbv2 delete-load-balancer --load-balancer-arn "${ALB_ARN}" >/dev/null
  # Esperar un poco a que el ALB se borre y libere el target group
  sleep 10
  ok "ALB borrado"
fi

if [ -n "${TG_ARN}" ] && awsc elbv2 describe-target-groups --target-group-arns "${TG_ARN}" >/dev/null 2>&1; then
  awsc elbv2 delete-target-group --target-group-arn "${TG_ARN}" >/dev/null
  ok "Target Group borrado"
fi

# 4. DynamoDB Table
log "[4/10] DynamoDB Table"
TABLE_NAME=$(state TABLE_NAME); [ -z "${TABLE_NAME}" ] && TABLE_NAME="${PREFIX}-users"
if exists dynamodb describe-table --table-name "${TABLE_NAME}"; then
  awsc dynamodb delete-table --table-name "${TABLE_NAME}" >/dev/null
  awsc dynamodb wait table-not-exists --table-name "${TABLE_NAME}"
  ok "Tabla DynamoDB ${TABLE_NAME} borrada"
else
  ok "Tabla DynamoDB ya no existe"
fi

# 5. Security Groups
log "[5/10] Security Groups"
for sg in "${SG_ALB_ID}" "${SG_APP_ID}" "${SG_DB_ID}"; do
  if [ -n "${sg}" ] && [ "${sg}" != "None" ]; then
    # Revocamos todas las reglas de ingreso y egreso para romper dependencias cruzadas de inmediato
    awsc ec2 revoke-security-group-ingress --group-id "${sg}" --ip-permissions "$(awsc ec2 describe-security-groups --group-ids "${sg}" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null)" >/dev/null 2>&1 || true
    awsc ec2 revoke-security-group-egress --group-id "${sg}" --ip-permissions "$(awsc ec2 describe-security-groups --group-ids "${sg}" --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null)" >/dev/null 2>&1 || true
  fi
done

# Borramos los grupos de seguridad una vez rotas las dependencias
for sg in "${SG_ALB_ID}" "${SG_APP_ID}" "${SG_DB_ID}"; do
  if [ -n "${sg}" ] && [ "${sg}" != "None" ]; then
    if awsc ec2 delete-security-group --group-id "${sg}" >/dev/null 2>&1; then
      ok "Security Group ${sg} borrado"
    else
      warn "No se pudo borrar Security Group ${sg}"
    fi
  fi
done

# 6. NAT Gateway & EIP
log "[6/10] NAT Gateway"
NAT_GWS=$(awsc ec2 describe-nat-gateways --filter "Name=vpc-id,Values=${VPC_ID}" --query 'NatGateways[?State!=`deleted`].NatGatewayId' --output text 2>/dev/null | tr '\t' ' ' || echo "")
for gw in ${NAT_GWS}; do
  if [ -n "${gw}" ]; then
    EIP_ALLOC=$(awsc ec2 describe-nat-gateways --nat-gateway-ids "${gw}" --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' --output text 2>/dev/null || echo "")
    if awsc ec2 delete-nat-gateway --nat-gateway-id "${gw}" >/dev/null 2>&1; then
      ok "Petición de borrado de NAT Gateway ${gw} enviada"
      if [ -n "${EIP_ALLOC}" ] && [ "${EIP_ALLOC}" != "None" ]; then
        state_set "EIP_TO_RELEASE_${gw}" "${EIP_ALLOC}"
      fi
    else
      warn "No se pudo borrar NAT Gateway ${gw}"
    fi
  fi
done

# Esperamos a que todos se eliminen para poder liberar las EIPs y borrar subredes (modo rápido asíncrono)
for gw in ${NAT_GWS}; do
  if [ -n "${gw}" ]; then
    EIP_ALLOC=$(state_get "EIP_TO_RELEASE_${gw}")
    if [ -n "${EIP_ALLOC}" ] && [ "${EIP_ALLOC}" != "None" ]; then
      # Intentamos liberar la EIP (puede requerir que el NAT se haya disuelto, lo hacemos best-effort)
      awsc ec2 release-address --allocation-id "${EIP_ALLOC}" >/dev/null 2>&1 && ok "EIP ${EIP_ALLOC} liberado" || true
    fi
  fi
done

# 7. Subnets & VPC
log "[7/10] Subnets & VPC"
for sn in ${SUBNETS}; do
  if [ -n "${sn}" ] && awsc ec2 describe-subnets --subnet-ids "${sn}" >/dev/null 2>&1; then
    awsc ec2 delete-subnet --subnet-id "${sn}" >/dev/null 2>&1 && ok "Subnet ${sn} borrada" || warn "Subnet ${sn} no se pudo borrar"
  fi
done

# IGW
if [ -n "${IGW_ID}" ] && awsc ec2 describe-internet-gateways --internet-gateway-ids "${IGW_ID}" >/dev/null 2>&1; then
  awsc ec2 detach-internet-gateway --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}" >/dev/null 2>&1 || true
  awsc ec2 delete-internet-gateway --internet-gateway-id "${IGW_ID}" >/dev/null 2>&1 && ok "IGW borrado"
fi

# 8. VPC
log "[8/10] VPC"
if [ -n "${VPC_ID}" ] && [ "${VPC_ID}" != "None" ] && awsc ec2 describe-vpcs --vpc-ids "${VPC_ID}" >/dev/null 2>&1; then
  # Borramos todas las tablas de ruteo custom para liberar la VPC
  log "Borrando tablas de ruteo custom en ${VPC_ID}..."
  CUSTOM_RTS=$(awsc ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null | tr '\t' ' ' || echo "")
  for rt in ${CUSTOM_RTS}; do
    if [ -n "${rt}" ] && [ "${rt}" != "None" ]; then
      awsc ec2 delete-route-table --route-table-id "${rt}" >/dev/null 2>&1 && ok "Route Table ${rt} borrada" || true
    fi
  done

  awsc ec2 delete-vpc --vpc-id "${VPC_ID}" >/dev/null && ok "VPC borrada"
fi

# Cleanup
rm -f "${STATE_FILE}"
rm -rf "${TMP_DIR}"
echo
ok "DESTROY COMPLETO - app3 eliminada por completo"