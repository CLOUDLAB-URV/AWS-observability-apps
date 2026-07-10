#!/usr/bin/env bash
# destroy.sh — Borra todos los recursos de app1 en orden inverso al deploy.
# Idempotente: si un recurso ya no existe, lo skippea.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

sanity_check
ACCT="$(account_id)"
log "Destruyendo app1 en cuenta=${ACCT} region=${REGION}"

# Recarga nombres desde estado siesta, sino usa defaults ya cargados por common.sh
state() { state_get "$1"; }
API_ID="$(state API_ID)"
API_NAME_S="$(state API_NAME)"; [ -n "${API_NAME_S}" ] && API_NAME="${API_NAME_S}"
BUCKET_NAME="$(state BUCKET_NAME)"; [ -z "${BUCKET_NAME}" ] && BUCKET_NAME="${BUCKET_NAME:-${PREFIX}-metrics}"
TABLE_NAME="$(state TABLE_NAME)"; [ -z "${TABLE_NAME}" ] && TABLE_NAME="${TABLE_NAME:-${PREFIX}-metrics}"
FN_UPLOAD="$(state FN_UPLOAD)"; [ -z "${FN_UPLOAD}" ] && FN_UPLOAD="${PREFIX}-upload"
FN_PROCESS="$(state FN_PROCESS)"; [ -z "${FN_PROCESS}" ] && FN_PROCESS="${PREFIX}-process"
ROLE_UPLOAD="${PREFIX}-upload-role"
ROLE_PROCESS="${PREFIX}-process-role"

# ------------------------------------------------------------------
# 1) API Gateway REST API (borra recursivamente stages + deployments + resources)
# ------------------------------------------------------------------
log "[1/6] API Gateway"
if [ -n "${API_ID}" ]; then
  if exists apigateway get-rest-api --rest-api-id "${API_ID}"; then
    awsc apigateway delete-rest-api --rest-api-id "${API_ID}"
    ok "api ${API_ID} borrada"
  else
    ok "api ya no existe"
  fi
else
  # Re-deriva por nombre si no tenemos ID
  API_ID_BY_NAME="$(awsc apigateway get-rest-apis --query "items[?name==\`${API_NAME}\`].id" --output text 2>/dev/null || true)"
  if [ -n "${API_ID_BY_NAME}" ]; then
    awsc apigateway delete-rest-api --rest-api-id "${API_ID_BY_NAME}"
    ok "api ${API_ID_BY_NAME} (por nombre) borrada"
  else
    ok "api no encontrada (skip)"
  fi
fi

# ------------------------------------------------------------------
# 2) Notificacion S3 (quitar antes de borrar bucket)
# ------------------------------------------------------------------
log "[2/6] Quitar notificacion S3"
if exists s3api head-bucket --bucket "${BUCKET_NAME}"; then
  awsc s3api put-bucket-notification-configuration \
    --bucket "${BUCKET_NAME}" \
    --notification-configuration '{}' >/dev/null 2>&1 || warn "no se pudo limpiar notification (continuando)"
  ok "notificacion vaciada"
else
  ok "bucket no existe (skip)"
fi

# ------------------------------------------------------------------
# 3) Lambdas
# ------------------------------------------------------------------
log "[3/6] Lambdas"
for fn in "${FN_UPLOAD}" "${FN_PROCESS}"; do
  if exists lambda get-function --function-name "${fn}"; then
    awsc lambda delete-function --function-name "${fn}"
    ok "lambda ${fn} borrada"
  else
    ok "lambda ${fn} ya no existe"
  fi
done

# ------------------------------------------------------------------
# 4) IAM roles + inline policies
# ------------------------------------------------------------------
log "[4/6] IAM roles"
if [ -n "${LAMBDA_ROLE_ARN}" ]; then
  ok "roles reutilizados (LAMBDA_ROLE_ARN set) - no se borran"
else
for role in "${ROLE_UPLOAD}" "${ROLE_PROCESS}"; do
  if exists iam get-role --role-name "${role}"; then
    # borra inline policies primero (ignora si no hay)
    awsc iam delete-role-policy --role-name "${role}" --policy-name "${role}-inline" 2>/dev/null || true
    awsc iam delete-role --role-name "${role}"
    ok "rol ${role} borrado"
  else
    ok "rol ${role} ya no existe"
  fi
done
fi

# ------------------------------------------------------------------
# 5) S3 bucket (vaciar + borrar)
# ------------------------------------------------------------------
log "[5/6] S3 bucket"
if exists s3api head-bucket --bucket "${BUCKET_NAME}"; then
  # borrado recursivo	versionado o no
  awsc s3 rm "s3://${BUCKET_NAME}" --recursive >/dev/null 2>&1 || warn "algunos objetos no borraron"
  awsc s3api delete-bucket --bucket "${BUCKET_NAME}"
  ok "bucket ${BUCKET_NAME} borrado"
else
  ok "bucket ya no existe"
fi

# ------------------------------------------------------------------
# 6) DynamoDB table
# ------------------------------------------------------------------
log "[6/6] DynamoDB table"
if exists dynamodb describe-table --table-name "${TABLE_NAME}"; then
  awsc dynamodb delete-table --table-name "${TABLE_NAME}"
  awsc dynamodb wait table-not-exists --table-name "${TABLE_NAME}"
  ok "tabla ${TABLE_NAME} borrada"
else
  ok "tabla ya no existe"
fi

# Limpieza del estado
rm -f "${STATE_FILE}"
rm -rf "${TMP_DIR}"
echo
ok "DESTROY COMPLETO"