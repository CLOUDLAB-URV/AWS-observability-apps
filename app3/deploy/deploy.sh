#!/usr/bin/env bash
# deploy.sh - Despliegue completo de app3 (Web App + DynamoDB + ALB + ASG)
# Arquitectura: VPC -> ALB -> ASG (EC2) -> DynamoDB
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

sanity_check
ACCT="$(account_id)"
log "Cuenta: ${ACCT}  Region: ${REGION}  Perfil: ${PROFILE}"

# ------------------------------------------------------------------
# Configuración (overrides via entorno)
# ------------------------------------------------------------------
PREFIX="${PREFIX:-aws-obs-app3}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
MIN_SIZE="${MIN_SIZE:-3}"
MAX_SIZE="${MAX_SIZE:-5}"
DESIRED_CAPACITY="${DESIRED_CAPACITY:-3}"
KEY_NAME="${KEY_NAME:-}"

# Nombres derivados
VPC_NAME="${PREFIX}-vpc"
ALB_NAME="${PREFIX}-alb"
TG_NAME="${PREFIX}-tg"
LT_NAME="${PREFIX}-lt"
ASG_NAME="${PREFIX}-asg"
SG_ALB="${PREFIX}-sg-alb"
SG_APP="${PREFIX}-sg-app"
PROFILE_NAME="${PREFIX}-ec2-profile"

# ------------------------------------------------------------------
# 1) VPC + Subnets + IGW + NAT Gateway
# ------------------------------------------------------------------
log "[1/9] VPC + Networking"
VPC_ID=$(awsc ec2 describe-vpcs --filters "Name=tag:Name,Values=${VPC_NAME}" --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
if [ -n "${VPC_ID}" ] && [ "${VPC_ID}" != "None" ]; then
  ok "VPC ya existe: ${VPC_ID}"
else
  VPC_ID=$(awsc ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
  awsc ec2 create-tags --resources "${VPC_ID}" --tags "Key=Name,Value=${VPC_NAME}"
  awsc ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-hostnames
  awsc ec2 modify-vpc-attribute --vpc-id "${VPC_ID}" --enable-dns-support
  awsc ec2 wait vpc-available --vpc-ids "${VPC_ID}"
  ok "VPC creada: ${VPC_ID}"
fi
state_set VPC_ID "${VPC_ID}"

# 2 AZs
AZS=($(awsc ec2 describe-availability-zones --query 'AvailabilityZones[0:2].ZoneName' --output text))
AZ1="${AZS[0]}"
AZ2="${AZS[1]}"

# Public subnets
PUBLIC_SUBNET_1=$(get_or_create_subnet "${VPC_ID}" "10.0.1.0/24" "${AZ1}" "public-1")
PUBLIC_SUBNET_2=$(get_or_create_subnet "${VPC_ID}" "10.0.2.0/24" "${AZ2}" "public-2")
PUBLIC_SUBNET_IDS="${PUBLIC_SUBNET_1},${PUBLIC_SUBNET_2}"

# Private subnets (para EC2)
PRIVATE_SUBNET_1=$(get_or_create_subnet "${VPC_ID}" "10.0.11.0/24" "${AZ1}" "private-1")
PRIVATE_SUBNET_2=$(get_or_create_subnet "${VPC_ID}" "10.0.12.0/24" "${AZ2}" "private-2")
PRIVATE_SUBNET_IDS="${PRIVATE_SUBNET_1},${PRIVATE_SUBNET_2}"

# IGW
IGW_ID=$(get_or_create_igw "${VPC_ID}")

# NAT Gateway (uno solo en public-1 para ahorrar costos)
log "Verificando NAT Gateway existente..."
NAT_GW_ID=$(awsc ec2 describe-nat-gateways --filter "Name=subnet-id,Values=${PUBLIC_SUBNET_IDS%%,*}" "Name=state,Values=available" --query 'NatGateways[0].NatGatewayId' --output text 2>/dev/null)
if [ -z "${NAT_GW_ID}" ] || [ "${NAT_GW_ID}" = "None" ]; then
  NAT_EIP_ALLOC=$(awsc ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
  NAT_GW_ID=$(awsc ec2 create-nat-gateway --subnet-id "${PUBLIC_SUBNET_IDS%%,*}" --allocation-id "${NAT_EIP_ALLOC}" --query 'NatGateway.NatGatewayId' --output text)
  ok "Petición de creación de NAT Gateway enviada: ${NAT_GW_ID}"
else
  ok "NAT Gateway ya existe: ${NAT_GW_ID}"
fi

# Route tables - check if they already exist
PUBLIC_RT=$(awsc ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" "Name=route.gateway-id,Values=${IGW_ID}" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "")
if [ -z "${PUBLIC_RT}" ] || [ "${PUBLIC_RT}" = "None" ]; then
  PUBLIC_RT=$(awsc ec2 create-route-table --vpc-id "${VPC_ID}" --query 'RouteTable.RouteTableId' --output text)
  awsc ec2 create-route --route-table-id "${PUBLIC_RT}" --destination-cidr-block 0.0.0.0/0 --gateway-id "${IGW_ID}" >/dev/null
else
  ok "Route table pública ya existe: ${PUBLIC_RT}"
fi

# Associate public subnets
for subnet in $(echo "${PUBLIC_SUBNET_IDS}" | tr ',' ' '); do
  awsc ec2 associate-route-table --route-table-id "${PUBLIC_RT}" --subnet-id "${subnet}" >/dev/null 2>&1 || true
done

# Private route table
NAT_GW_ID=$(awsc ec2 describe-nat-gateways --filter "Name=subnet-id,Values=${PUBLIC_SUBNET_IDS%%,*}" --query 'NatGateways[0].NatGatewayId' --output text)
PRIVATE_RT=$(awsc ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}" "Name=route.nat-gateway-id,Values=${NAT_GW_ID}" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || echo "")
if [ -z "${PRIVATE_RT}" ] || [ "${PRIVATE_RT}" = "None" ]; then
  PRIVATE_RT=$(awsc ec2 create-route-table --vpc-id "${VPC_ID}" --query 'RouteTable.RouteTableId' --output text)
  awsc ec2 create-route --route-table-id "${PRIVATE_RT}" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NAT_GW_ID}" >/dev/null
else
  ok "Route table privada ya existe: ${PRIVATE_RT}"
fi

# Associate private subnets
for subnet in $(echo "${PRIVATE_SUBNET_IDS}" | tr ',' ' '); do
  awsc ec2 associate-route-table --route-table-id "${PRIVATE_RT}" --subnet-id "${subnet}" >/dev/null 2>&1 || true
done

state_set VPC_ID "${VPC_ID}"
state_set PUBLIC_SUBNET_IDS "${PUBLIC_SUBNET_IDS}"
state_set PRIVATE_SUBNET_IDS "${PRIVATE_SUBNET_IDS}"
state_set IGW_ID "${IGW_ID}"

# ------------------------------------------------------------------
# 2) Security Groups
# ------------------------------------------------------------------
log "[2/9] Security Groups"

# SG ALB
SG_ALB_ID=$(awsc ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-sg-alb" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
if [ -n "${SG_ALB_ID}" ] && [ "${SG_ALB_ID}" != "None" ]; then
  ok "SG ALB ya existe: ${SG_ALB_ID}"
else
  SG_ALB_ID=$(awsc ec2 create-security-group --group-name "${PREFIX}-sg-alb" --description "ALB SG" --vpc-id "${VPC_ID}" --query 'GroupId' --output text)
fi
awsc ec2 authorize-security-group-ingress --group-id "${SG_ALB_ID}" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
awsc ec2 authorize-security-group-ingress --group-id "${SG_ALB_ID}" --protocol tcp --port 443 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
state_set SG_ALB_ID "${SG_ALB_ID}"
ok "SG ALB: ${SG_ALB_ID}"

# SG App (EC2)
SG_APP_ID=$(awsc ec2 describe-security-groups --filters "Name=group-name,Values=${PREFIX}-sg-app" "Name=vpc-id,Values=${VPC_ID}" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "")
if [ -n "${SG_APP_ID}" ] && [ "${SG_APP_ID}" != "None" ]; then
  ok "SG App ya existe: ${SG_APP_ID}"
else
  SG_APP_ID=$(awsc ec2 create-security-group --group-name "${PREFIX}-sg-app" --description "App SG" --vpc-id "${VPC_ID}" --query 'GroupId' --output text)
fi
awsc ec2 authorize-security-group-ingress --group-id "${SG_APP_ID}" --protocol tcp --port 8000 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
awsc ec2 authorize-security-group-ingress --group-id "${SG_APP_ID}" --protocol tcp --port 22 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
state_set SG_APP_ID "${SG_APP_ID}"
ok "SG App: ${SG_APP_ID}"

# ------------------------------------------------------------------
# 3) DynamoDB Table (PK = username)
# ------------------------------------------------------------------
log "[3/9] DynamoDB Table"
TABLE_NAME="${PREFIX}-users"
if exists dynamodb describe-table --table-name "${TABLE_NAME}"; then
  ok "Tabla DynamoDB ya existe: ${TABLE_NAME}"
else
  awsc dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=username,AttributeType=S \
    --key-schema AttributeName=username,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  awsc dynamodb wait table-exists --table-name "${TABLE_NAME}"
  ok "Tabla DynamoDB creada: ${TABLE_NAME}"
fi
state_set TABLE_NAME "${TABLE_NAME}"

# ------------------------------------------------------------------
# 4) IAM Role para EC2 (SSM, CloudWatch, DynamoDB)
# ------------------------------------------------------------------
log "[4/9] IAM Role para EC2"
TRUST_DOC='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ROLE_NAME="${PREFIX}-ec2-role"
PROFILE_NAME="${PREFIX}-ec2-profile"

if exists iam get-instance-profile --instance-profile-name "LabInstanceProfile"; then
  warn "LabInstanceProfile detectado: Reutilizando LabInstanceProfile preexistente (evitando crear roles)"
  PROFILE_NAME="LabInstanceProfile"
  state_set IAM_PROFILE "LabInstanceProfile"
else
  if exists iam get-role --role-name "${ROLE_NAME}"; then
    ROLE_ARN=$(awsc iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)
  else
    ROLE_ARN=$(awsc iam create-role --role-name "${ROLE_NAME}" --assume-role-policy-document "${TRUST_DOC}" --query 'Role.Arn' --output text)
    awsc iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
    awsc iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
    awsc iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess
  fi
  state_set ROLE_ARN "${ROLE_ARN}"

  if ! exists iam get-instance-profile --instance-profile-name "${PREFIX}-ec2-profile"; then
    awsc iam create-instance-profile --instance-profile-name "${PREFIX}-ec2-profile" >/dev/null
    awsc iam add-role-to-instance-profile --instance-profile-name "${PREFIX}-ec2-profile" --role-name "${ROLE_NAME}"
  fi
  state_set IAM_PROFILE "${PREFIX}-ec2-profile"
fi

# ------------------------------------------------------------------
# 5) ALB + Target Group
# ------------------------------------------------------------------
log "[5/9] Application Load Balancer"
ALB_NAME="${PREFIX}-alb"
if exists elbv2 describe-load-balancers --names "${PREFIX}-alb"; then
  ALB_ARN=$(awsc elbv2 describe-load-balancers --names "${PREFIX}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
else
  PUBLIC_SUBNET_IDS_LIST=$(awsc ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=public-*" --query 'Subnets[*].SubnetId' --output text | tr '\t' ' ')
  ALB_ARN=$(awsc elbv2 create-load-balancer --name "${PREFIX}-alb" --subnets ${PUBLIC_SUBNET_IDS_LIST} --security-groups "${SG_ALB_ID}" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
fi
state_set ALB_ARN "${ALB_ARN}"
ALB_DNS=$(awsc elbv2 describe-load-balancers --load-balancer-arns "${ALB_ARN}" --query 'LoadBalancers[0].DNSName' --output text)

# Target Group
TG_NAME="${PREFIX}-tg"
if exists elbv2 describe-target-groups --names "${TG_NAME}"; then
  TG_ARN=$(awsc elbv2 describe-target-groups --names "${TG_NAME}" --query 'TargetGroups[0].TargetGroupArn' --output text)
else
  TG_ARN=$(awsc elbv2 create-target-group --name "${TG_NAME}" --protocol HTTP --port 8000 --vpc-id "${VPC_ID}" --health-check-path /health --health-check-interval-seconds 30 --health-check-timeout-seconds 5 --healthy-threshold-count 2 --unhealthy-threshold-count 3 --query 'TargetGroups[0].TargetGroupArn' --output text)
fi
state_set TG_ARN "${TG_ARN}"

# Listener HTTP 80
if ! awsc elbv2 describe-listeners --load-balancer-arn "${ALB_ARN}" --query "Listeners[?Port==\`80\`]" --output text | grep -q .; then
  awsc elbv2 create-listener --load-balancer-arn "${ALB_ARN}" --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn="${TG_ARN}" >/dev/null
fi

# ------------------------------------------------------------------
# 6) Launch Template
# ------------------------------------------------------------------
log "[6/9] Launch Template"
LT_NAME="${PREFIX}-lt"

# Create user data script file
cat > "${TMP_DIR}/user_data.sh" <<'USERDATA_EOF'
#!/bin/bash
yum update -y
yum install -y python3 python3-pip git amazon-cloudwatch-agent
mkdir -p /opt/app3/src/web
cd /opt/app3/src/web

# Create requirements.txt
cat > requirements.txt <<'REQEOF'
flask<3.0
gunicorn<22.0
boto3
REQEOF

# Create app.py
cat > app.py <<'APP_EOF'
import os
import sys
import json
import datetime
import boto3
from botocore.exceptions import ClientError
from flask import Flask, request, jsonify, render_template_string

app = Flask(__name__)

TABLE_NAME = os.environ.get('TABLE_NAME', 'aws-obs-app3-users')
REGION = os.environ.get('AWS_DEFAULT_REGION', 'us-east-1')

dynamodb = boto3.resource('dynamodb', region_name=REGION)
table = dynamodb.Table(TABLE_NAME)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>App3 - Auto-scaling Web App</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 40px auto; padding: 20px; }
        .card { border: 1px solid #ddd; border-radius: 8px; padding: 20px; margin: 20px 0; background: #fafafa; }
        .success { border-color: #28a745; background: #d4edda; }
        .error { border-color: #dc3545; background: #f8d7da; }
        input, button { padding: 10px; margin: 5px; }
        button { background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        button:hover { background: #0056b3; }
        pre { background: #f8f9fa; padding: 10px; overflow-x: auto; }
    </style>
</head>
<body>
    <h1>App3 - Auto-scaling Web App with DynamoDB</h1>
    
    <div class="card {% if db_status == 'ok' %}success{% else %}error{% endif %}">
        <h3>Database Status: {{ db_status.upper() }}</h3>
        <p>{{ db_message }}</p>
    </div>

    <div class="card">
        <h3>Create User</h3>
        <form method="POST" action="/users">
            <input type="text" name="username" placeholder="Username" required>
            <input type="email" name="email" placeholder="Email" required>
            <button type="submit">Create User</button>
        </form>
        {% if user_created %}
        <p style="color: green;">User created successfully!</p>
        {% endif %}
    </div>

    <div class="card">
        <h3>All Users</h3>
        <pre>{{ users_json }}</pre>
    </div>
</body>
</html>
"""

def get_db_connection(db_select=None):
    try:
        table.load()
        return table
    except Exception:
        return None

def init_db():
    return True

@app.route('/')
def index():
    conn = get_db_connection()
    db_status = 'ok' if conn else 'error'
    db_message = f'Connected to DynamoDB Table ({TABLE_NAME})' if conn else f'Cannot scan DynamoDB table ({TABLE_NAME})'
    
    users = []
    if conn:
        try:
            resp = table.scan()
            users = resp.get('Items', [])
        except Exception as e:
            users = [{'error': str(e)}]

    import json
    return render_template_string(HTML_TEMPLATE, 
                                  db_status=db_status, 
                                  db_message=db_message,
                                  users_json=json.dumps(users, indent=2, default=str),
                                  user_created=False)

@app.route('/users', methods=['POST'])
def create_user():
    username = request.form.get('username')
    email = request.form.get('email')
    
    try:
        table.put_item(
            Item={
                'username': username,
                'email': email,
                'created_at': datetime.datetime.utcnow().isoformat() + 'Z'
            }
        )
        user_created = True
    except Exception as e:
        return f"Error creating user: {e}", 500
    
    users = []
    try:
        resp = table.scan()
        users = resp.get('Items', [])
    except Exception as e:
        users = [{'error': str(e)}]
        
    return render_template_string(HTML_TEMPLATE,
                                  db_status='ok',
                                  db_message=f'Connected to DynamoDB Table ({TABLE_NAME})',
                                  users_json=json.dumps(users, indent=2, default=str),
                                  user_created=user_created)

@app.route('/health')
def health():
    try:
        table.scan(Limit=1)
        return jsonify({"status": "healthy", "database": "connected"}), 200
    except Exception as e:
        return jsonify({"status": "unhealthy", "database": f"disconnected: {e}"}), 503

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8000)
APP_EOF

pip3 install -r requirements.txt

# Create systemd service
cat > /etc/systemd/system/app3.service <<'SVC'
[Unit]
Description=App3 Flask Web App
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/app3/src/web
Environment=TABLE_NAME={{TABLE_NAME}}
Environment=AWS_DEFAULT_REGION={{REGION}}
ExecStart=/usr/local/bin/gunicorn --bind 0.0.0.0:8000 --workers 2 app:app
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC

# Replace placeholders
sed -i "s/{{TABLE_NAME}}/TABLE_NAME_PLACEHOLDER/g" /etc/systemd/system/app3.service
sed -i "s/{{REGION}}/REGION_PLACEHOLDER/g" /etc/systemd/system/app3.service

systemctl daemon-reload
systemctl enable app3
systemctl start app3

# CloudWatch Agent
cat > /opt/aws/amazon-cloudwatch-agent/bin/config.json <<'CW'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/aws/ec2/app3",
            "log_stream_name": "{instance_id}/system"
          },
          {
            "file_path": "/var/log/app3.log",
            "log_group_name": "/aws/ec2/app3",
            "log_stream_name": "{instance_id}/app"
          }
        ]
      }
    }
  }
}
CW
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json
systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent
USERDATA_EOF

# Reemplazar los marcadores de posición localmente antes de codificar en base64
sed -i "s/TABLE_NAME_PLACEHOLDER/${TABLE_NAME}/g" "${TMP_DIR}/user_data.sh"
sed -i "s/REGION_PLACEHOLDER/${REGION}/g" "${TMP_DIR}/user_data.sh"

USER_DATA=$(base64 -w0 < "${TMP_DIR}/user_data.sh")

# Borramos plantilla vieja para evitar que herede parámetros rotos (como un KeyPair vacío)
if exists ec2 describe-launch-templates --launch-template-names "${LT_NAME}"; then
  awsc ec2 delete-launch-template --launch-template-name "${LT_NAME}" >/dev/null
fi

# Construimos JSON de datos de plantilla según si hay clave SSH o no
if [ -n "${KEY_NAME}" ]; then
  LT_DATA="{
    \"ImageId\": \"$(awsc ec2 describe-images --owners amazon --filters Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2 --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)\",
    \"InstanceType\": \"${INSTANCE_TYPE}\",
    \"KeyName\": \"${KEY_NAME}\",
    \"SecurityGroupIds\": [\"${SG_APP_ID}\"],
    \"UserData\": \"${USER_DATA}\",
    \"IamInstanceProfile\": {\"Name\": \"${PROFILE_NAME}\"},
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Name\", \"Value\": \"${PREFIX}-instance\"}]
    }]
  }"
else
  LT_DATA="{
    \"ImageId\": \"$(awsc ec2 describe-images --owners amazon --filters Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2 --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)\",
    \"InstanceType\": \"${INSTANCE_TYPE}\",
    \"SecurityGroupIds\": [\"${SG_APP_ID}\"],
    \"UserData\": \"${USER_DATA}\",
    \"IamInstanceProfile\": {\"Name\": \"${PROFILE_NAME}\"},
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [{\"Key\": \"Name\", \"Value\": \"${PREFIX}-instance\"}]
    }]
  }"
fi

LT_ID=$(awsc ec2 create-launch-template \
  --launch-template-name "${LT_NAME}" \
  --version-description "v1" \
  --launch-template-data "${LT_DATA}" --query 'LaunchTemplate.LaunchTemplateId' --output text)
ok "Launch Template creado: ${LT_NAME}"

LT_VERSION=$(awsc ec2 describe-launch-template-versions --launch-template-id "${LT_ID}" --versions \$Latest --query 'LaunchTemplateVersions[0].VersionNumber' --output text)
state_set LT_ID "${LT_ID}"
state_set LT_VERSION "${LT_VERSION}"

# ------------------------------------------------------------------
# 7) Auto Scaling Group
# ------------------------------------------------------------------
log "[7/9] Auto Scaling Group"
ASG_NAME="${PREFIX}-asg"
ASG_EXIST_CHECK=$(awsc autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${ASG_NAME}" --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null || echo "")
if [ -z "${ASG_EXIST_CHECK}" ] || [ "${ASG_EXIST_CHECK}" = "None" ]; then
  awsc autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "${ASG_NAME}" \
    --launch-template "LaunchTemplateId=${LT_ID},Version=${LT_VERSION}" \
    --min-size 1 --max-size 2 --desired-capacity 1 \
    --vpc-zone-identifier "${PRIVATE_SUBNET_IDS}" \
    --target-group-arns "${TG_ARN}" \
    --health-check-type ELB --health-check-grace-period 300 \
    --tags "Key=Name,Value=${PREFIX}-app,PropagateAtLaunch=true" \
    --termination-policies Default
  ok "Auto Scaling Group creado: ${ASG_NAME}"
else
  ok "Auto Scaling Group ya existe: ${ASG_NAME}. Actualizando plantilla y capacidades..."
  awsc autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "${ASG_NAME}" \
    --launch-template "LaunchTemplateId=${LT_ID},Version=${LT_VERSION}" \
    --min-size "${MIN_SIZE}" --max-size "${MAX_SIZE}" --desired-capacity "${DESIRED_CAPACITY}" >/dev/null
  ok "Auto Scaling Group actualizado con plantilla ${LT_ID} versión ${LT_VERSION} y capacidades (${MIN_SIZE}-${MAX_SIZE})"
fi
state_set ASG_NAME "${ASG_NAME}"

# ------------------------------------------------------------------
# 8) CloudWatch Log Groups
# ------------------------------------------------------------------
log "[8/9] CloudWatch Log Groups"
for lg in /aws/ec2/app3 /aws/ec2/app3/system /aws/ec2/app3/app; do
  if ! exists logs describe-log-groups --log-group-name-prefix "$lg"; then
    awsc logs create-log-group --log-group-name "$lg" >/dev/null
    awsc logs put-retention-policy --log-group-name "$lg" --retention-in-days 14 >/dev/null
  fi
done

# ------------------------------------------------------------------
# Resumen
# ------------------------------------------------------------------
log "[9/9] Deploy completo"

echo
ok "APP3 DESPLEGADA (DYNAMODB)"
echo "  ALB DNS:      http://${ALB_DNS}"
echo "  Table Name:   ${TABLE_NAME}"
echo "  ASG:          ${ASG_NAME}"
echo "  Estado:       ${STATE_FILE}"
echo
echo "Probar:"
echo "  curl http://${ALB_DNS}/health"
echo "  curl http://${ALB_DNS}/"