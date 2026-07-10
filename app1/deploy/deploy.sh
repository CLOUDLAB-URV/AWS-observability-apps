#!/usr/bin/env bash
# deploy.sh — Despliega app1 con AWS CLI imperativo (sin SAM).
# Idempotente: si un recurso ya existe, hace wait y continua.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

sanity_check
ACCT="$(account_id)"
log "Cuenta: ${ACCT}  Region: ${REGION}  Perfil: ${PROFILE}"
log "Bucket: ${BUCKET_NAME}  Tabla: ${TABLE_NAME}  API: ${API_NAME}"
log "Lambdas: ${FN_UPLOAD} / ${FN_PROCESS}"

BUCKET_ARN="arn:aws:s3:::${BUCKET_NAME}"
TABLE_ARN="arn:aws:dynamodb:${REGION}:${ACCT}:table/${TABLE_NAME}"
LOGS_ARN="arn:aws:logs:${REGION}:${ACCT}:*"
TRUST_DOC="${DEPLOY_DIR}/policies/lambda-trust.json"

# ------------------------------------------------------------------
# 1) S3 bucket
# ------------------------------------------------------------------
log "[1/6] S3 bucket"
if exists s3api head-bucket --bucket "${BUCKET_NAME}"; then
  ok "bucket ya existe"
else
  if [ "${REGION}" = "us-east-1" ]; then
    awsc s3api create-bucket --bucket "${BUCKET_NAME}" >/dev/null
  else
    awsc s3api create-bucket --bucket "${BUCKET_NAME}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  fi
  awsc s3api wait bucket-exists --bucket "${BUCKET_NAME}"
  ok "bucket creado"
fi
state_set BUCKET_NAME "${BUCKET_NAME}"

# ------------------------------------------------------------------
# 2) DynamoDB table
# ------------------------------------------------------------------
log "[2/6] DynamoDB table"
if exists dynamodb describe-table --table-name "${TABLE_NAME}"; then
  ok "tabla ya existe"
else
  awsc dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=metric_date,AttributeType=S AttributeName=metric,AttributeType=S \
    --key-schema AttributeName=metric_date,KeyType=HASH AttributeName=metric,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST >/dev/null
  awsc dynamodb wait table-exists --table-name "${TABLE_NAME}"
  ok "tabla creada"
fi
state_set TABLE_NAME "${TABLE_NAME}"
state_set TABLE_ARN "${TABLE_ARN}"

# ------------------------------------------------------------------
# Helper: crear rol + inline policy
# ------------------------------------------------------------------
create_role() {
  local role_name="$1" inline_policy="$2"
  if exists iam get-role --role-name "${role_name}"; then
    ok "rol ${role_name} ya existe"
  else
    awsc iam create-role --role-name "${role_name}" \
      --assume-role-policy-document "file://${TRUST_DOC}" >/dev/null
    ok "rol ${role_name} creado"
  fi
  awsc iam put-role-policy --role-name "${role_name}" \
    --policy-name "${role_name}-inline" \
    --policy-document "${inline_policy}" >/dev/null
  awsc iam get-role --role-name "${role_name}" --query 'Role.Arn' --output text
}

upload_policy() {
  jq -n \
    --arg bucket "${BUCKET_NAME}" \
    --arg logs "${LOGS_ARN}" \
    '{
      Version: "2012-10-17",
      Statement: [
        {Effect: "Allow", Action: ["s3:PutObject"], Resource: ["arn:aws:s3:::\($bucket)/*"]},
        {Effect: "Allow", Action: ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"], Resource: [$logs]}
      ]
    }'
}

process_policy() {
  jq -n \
    --arg bucket "${BUCKET_NAME}" \
    --arg table "${TABLE_ARN}" \
    --arg logs "${LOGS_ARN}" \
    '{
      Version: "2012-10-17",
      Statement: [
        {Effect: "Allow", Action: ["s3:GetObject"], Resource: ["arn:aws:s3:::\($bucket)/*"]},
        {Effect: "Allow", Action: ["dynamodb:UpdateItem","dynamodb:DescribeTable"], Resource: [$table]},
        {Effect: "Allow", Action: ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"], Resource: [$logs]}
      ]
    }'
}



# ------------------------------------------------------------------
# 3) IAM roles + inline policies
# ------------------------------------------------------------------
log "[3/6] IAM roles"
if [ -n "${LAMBDA_ROLE_ARN}" ]; then
  warn "LAMBDA_ROLE_ARN set: reutilizando rol ${LAMBDA_ROLE_ARN} (no se crean roles)"
  ROLE_UPLOAD_ARN="${LAMBDA_ROLE_ARN}"
  ROLE_PROCESS_ARN="${LAMBDA_ROLE_ARN}"
  state_set ROLE_UPLOAD_ARN "${ROLE_UPLOAD_ARN}"
  state_set ROLE_PROCESS_ARN "${ROLE_PROCESS_ARN}"
else
  ROLE_UPLOAD_ARN="$(create_role "${ROLE_UPLOAD}"   "$(upload_policy)")";   state_set ROLE_UPLOAD_ARN "${ROLE_UPLOAD_ARN}"
  ROLE_PROCESS_ARN="$(create_role "${ROLE_PROCESS}" "$(process_policy)")";  state_set ROLE_PROCESS_ARN "${ROLE_PROCESS_ARN}"
  ok "roles listos"
fi

# ------------------------------------------------------------------
# Helper: zip + crear/actualizar lambda
# ------------------------------------------------------------------
zip_lambda() {
  local src_dir="$1" name="$2"
  local zip="${TMP_DIR}/${name}.zip"
  ( cd "${src_dir}" && zip -qr "${zip}" handler.py )
  echo "${zip}"
}

_wait_lambda_ready() {
  local fn_name="$1"
  for i in $(seq 1 30); do
    local st
    st="$(awsc lambda get-function --function-name "${fn_name}" \
      --query 'Configuration.LastUpdateStatus' --output text 2>/dev/null || true)"
    case "${st}" in
      Successful|Failed|None) return 0 ;;
    esac
    sleep 3
  done
  warn "timeout esperando ${fn_name} (LastUpdateStatus=${st:-?})"
}

create_lambda() {
  local fn_name="$1" role_arn="$2" src_dir="$3" env_vars="$4"
  local zip; zip="$(zip_lambda "${src_dir}" "${fn_name}")"

  if exists lambda get-function --function-name "${fn_name}"; then
    ok "lambda ${fn_name} ya existe; actualizando codigo + env"
    awsc lambda update-function-code --function-name "${fn_name}" \
      --zip-file "fileb://${zip}" --publish >/dev/null
    _wait_lambda_ready "${fn_name}"
    awsc lambda update-function-configuration --function-name "${fn_name}" \
      --environment "Variables=${env_vars}" >/dev/null
    _wait_lambda_ready "${fn_name}"
  else
    # IAM eventual consistency: reintentar hasta 30s
    local created=0
    for i in $(seq 1 15); do
      if awsc lambda create-function \
        --function-name "${fn_name}" \
        --runtime python3.12 \
        --handler handler.lambda_handler \
        --role "${role_arn}" \
        --zip-file "fileb://${zip}" \
        --timeout 30 \
        --memory-size 256 \
        --environment "Variables=${env_vars}" >/dev/null 2>&1; then
        created=1; break
      fi
      warn "esperando consistencia IAM... (${i}/15)"
      sleep 2
    done
    [ "${created}" -eq 1 ] || die "no se pudo crear lambda ${fn_name}"
    ok "lambda ${fn_name} creada"
  fi
  awsc lambda wait function-active --function-name "${fn_name}" >/dev/null
  awsc lambda get-function --function-name "${fn_name}" \
    --query 'Configuration.FunctionArn' --output text
}

# ------------------------------------------------------------------
# 4) Lambdas
# ------------------------------------------------------------------
log "[3/6] Lambdas"
UPLOAD_ENV="{BUCKET_NAME=${BUCKET_NAME}}"
PROCESS_ENV="{TABLE_NAME=${TABLE_NAME}}"

UPLOAD_ARN="$(create_lambda "${FN_UPLOAD}"  "${ROLE_UPLOAD_ARN}"  "${APP_DIR}/src/upload"   "${UPLOAD_ENV}")"
PROCESS_ARN="$(create_lambda "${FN_PROCESS}" "${ROLE_PROCESS_ARN}" "${APP_DIR}/src/process" "${PROCESS_ENV}")"

state_set FN_UPLOAD "${FN_UPLOAD}";  state_set UPLOAD_ARN "${UPLOAD_ARN}"
state_set FN_PROCESS "${FN_PROCESS}"; state_set PROCESS_ARN "${PROCESS_ARN}"
ok "lambdas activas"

# ------------------------------------------------------------------
# 5) Trigger S3 -> process
# ------------------------------------------------------------------
log "[4/6] Trigger S3 -> process"
if awsc lambda get-policy --function-name "${FN_PROCESS}" 2>/dev/null \
   | jq -r '.Policy' 2>/dev/null \
   | jq -e --arg sid "s3-trigger" '.Statement[]? | select(.Sid==$sid)' >/dev/null 2>&1; then
  ok "permiso S3-trigger ya existe"
else
  awsc lambda add-permission \
    --function-name "${FN_PROCESS}" \
    --statement-id s3-trigger \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn "${BUCKET_ARN}" \
    --source-account "${ACCT}" >/dev/null
  ok "permiso S3-trigger anadido"
fi

notification=$(jq -n --arg fn "${PROCESS_ARN}" --arg bucket "${BUCKET_NAME}" \
  '{
    LambdaFunctionConfigurations: [
      {
        Id: "s3-to-process",
        LambdaFunctionArn: $fn,
        Events: ["s3:ObjectCreated:*"],
        Filter: {Key: {FilterRules: [{Name: "prefix", Value: "uploads/"}]}}
      }
    ]
  }')
notif_file="${TMP_DIR}/s3-notification.json"
printf '%s' "${notification}" >"${notif_file}"
awsc s3api put-bucket-notification-configuration \
  --bucket "${BUCKET_NAME}" \
  --notification-configuration "file://${notif_file}" >/dev/null
ok "notificacion S3 configurada"

# ------------------------------------------------------------------
# 6) API Gateway: crear API + root resource
# ------------------------------------------------------------------
log "[5/6] API Gateway"
if awsc apigateway get-rest-apis --query 'items[?name==`'"${API_NAME}"'`].id' --output text 2>/dev/null | grep -q .; then
  API_ID="$(awsc apigateway get-rest-apis --query 'items[?name==`'"${API_NAME}"'`].id' --output text)"
  ok "api ${API_NAME} ya existe (id=${API_ID})"
else
  API_ID="$(awsc apigateway create-rest-api --name "${API_NAME}" \
    --endpoint-configuration types=REGIONAL \
    --query 'id' --output text)"
  ok "api creada (id=${API_ID})"
fi
state_set API_ID "${API_ID}"
state_set API_NAME "${API_NAME}"

ROOT_ID="$(awsc apigateway get-resources --rest-api-id "${API_ID}" --query 'items[?path==`/`].id' --output text)"

# ------------------------------------------------------------------
# Helper: crear recurso + metodo + integracion AWS_PROXY + permission
# ------------------------------------------------------------------
create_endpoint() {
  local path="$1" method="$2" fn_name="$3" fn_arn="$4" req_params="$5"
  local parent_id="${ROOT_ID}"
  # path puede ser "/upload" o "/upload/{proxy+}"
  local resource_id
  resource_id="$(awsc apigateway get-resources --rest-api-id "${API_ID}" \
    --query "items[?path==\`${path}\`].id" --output text 2>/dev/null || true)"
  if [ -z "${resource_id}" ]; then
    resource_id="$(awsc apigateway create-resource \
      --rest-api-id "${API_ID}" \
      --parent-id "${parent_id}" \
      --path-part "${path#/}" --query 'id' --output text)"
    ok "recurso ${path} creado (id=${resource_id})"
  else
    ok "recurso ${path} ya existe"
  fi

  # Metodo
  if ! awsc apigateway get-method --rest-api-id "${API_ID}" --resource-id "${resource_id}" \
       --http-method "${method}" >/dev/null 2>&1; then
    awsc apigateway put-method \
      --rest-api-id "${API_ID}" \
      --resource-id "${resource_id}" \
      --http-method "${method}" \
      --authorization-type NONE \
      ${req_params:+--request-parameters ${req_params}} >/dev/null
    ok "metodo ${method} ${path} creado"
  fi

  # Integracion AWS_PROXY
  if ! awsc apigateway get-integration --rest-api-id "${API_ID}" --resource-id "${resource_id}" \
       --http-method "${method}" >/dev/null 2>&1; then
    awsc apigateway put-integration \
      --rest-api-id "${API_ID}" \
      --resource-id "${resource_id}" \
      --http-method "${method}" \
      --type AWS_PROXY \
      --integration-http-method POST \
      --uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${fn_arn}/invocations" >/dev/null
    ok "integracion AWS_PROXY ${method} ${path} -> ${fn_name}"
  fi

  # Permiso para que APIGW invoque la lambda
  local sid="apigw-${method}-${path#/}"
  sid="${sid//\//-}"   # sanear
  if awsc lambda get-policy --function-name "${fn_name}" 2>/dev/null \
     | jq -r '.Policy' 2>/dev/null \
     | jq -e --arg sid "${sid}" '.Statement[]? | select(.Sid==$sid)' >/dev/null 2>&1; then
    ok "permiso ${sid} ya existe en ${fn_name}"
  else
    awsc lambda add-permission \
      --function-name "${fn_name}" \
      --statement-id "${sid}" \
      --action lambda:InvokeFunction \
      --principal apigateway.amazonaws.com \
      --source-arn "arn:aws:execute-api:${REGION}:${ACCT}:${API_ID}/*/${method}${path}" >/dev/null
    ok "permiso ${sid} anadido a ${fn_name}"
  fi

  echo "${resource_id}"
}

# POST /upload (sin query params)
UPL_RES_ID="$(create_endpoint "/upload" "POST" "${FN_UPLOAD}" "${UPLOAD_ARN}" "")"
state_set UPL_RES_ID "${UPL_RES_ID}"

# ------------------------------------------------------------------
# 6) Deployment + stage Prod
# ------------------------------------------------------------------
log "[6/6] Deployment + stage Prod"
if awsc apigateway get-stage --rest-api-id "${API_ID}" --stage-name Prod >/dev/null 2>&1; then
  # El stage ya existe: crea un nuevo deployment y enlázalo al stage
  DEPLOY_ID="$(awsc apigateway create-deployment --rest-api-id "${API_ID}" --query 'id' --output text)"
  awsc apigateway update-stage --rest-api-id "${API_ID}" --stage-name Prod \
    --patch-operations op=replace,path=/deploymentId,value="${DEPLOY_ID}" >/dev/null
  ok "stage Prod actualizado con deployment ${DEPLOY_ID}"
else
  # Stage no existe: create-deployment con --stage-name crea deployment + stage en una sola llamada
  DEPLOY_ID="$(awsc apigateway create-deployment --rest-api-id "${API_ID}" \
    --stage-name Prod --description "deploy app1" --query 'id' --output text)"
  ok "stage Prod creado con deployment ${DEPLOY_ID}"
fi
state_set DEPLOY_ID "${DEPLOY_ID}"

API_BASE="https://${API_ID}.execute-api.${REGION}.amazonaws.com/Prod"
UPLOAD_ENDPOINT="${API_BASE}/upload"
state_set API_BASE "${API_BASE}"
state_set UPLOAD_ENDPOINT "${UPLOAD_ENDPOINT}"

echo
ok "DEPLOY COMPLETO"
echo "  Upload:    POST ${UPLOAD_ENDPOINT}        (Content-Type: text/csv)"
echo "  Estado:    ${STATE_FILE}"

echo
warn "Aviso: la notificacion S3 puede tardar hasta ~1 min en activarse."
warn "       Si un upload no dispara la lambda process, espera 60s y reintenta."