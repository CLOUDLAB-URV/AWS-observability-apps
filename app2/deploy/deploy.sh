#!/usr/bin/env bash
# deploy.sh — Despliega app2 (transcripcion + resumen de reuniones) con AWS CLI imperativo.
# Idempotente: si un recurso ya existe, hace wait y continua.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

sanity_check
ACCT="$(account_id)"
log "Cuenta: ${ACCT}  Region: ${REGION}  Perfil: ${PROFILE}"
log "Buckets: ${MEETINGS_BUCKET} (input) / ${TRANSCRIPTS_BUCKET} (output Transcribe)"
log "Tabla: ${TABLE_NAME}  Lambdas: ${FN_START} / ${FN_SUMMARIZE}"
log "Resumen: Amazon Comprehend (con fallback extractivo Python puro)"

MEETINGS_ARN="arn:aws:s3:::${MEETINGS_BUCKET}"
TRANSCRIPTS_ARN="arn:aws:s3:::${TRANSCRIPTS_BUCKET}"
TABLE_ARN="arn:aws:dynamodb:${REGION}:${ACCT}:table/${TABLE_NAME}"
LOGS_ARN="arn:aws:logs:${REGION}:${ACCT}:*"
TRUST_DOC="${DEPLOY_DIR}/policies/lambda-trust.json"

# ------------------------------------------------------------------
# 1) S3 bucket 'meetings' (input) + bucket policy allow Transcribe GetObject
# ------------------------------------------------------------------
log "[1/8] S3 bucket meetings (input)"
if exists s3api head-bucket --bucket "${MEETINGS_BUCKET}"; then
  ok "bucket ya existe"
else
  if [ "${REGION}" = "us-east-1" ]; then
    awsc s3api create-bucket --bucket "${MEETINGS_BUCKET}" >/dev/null
  else
    awsc s3api create-bucket --bucket "${MEETINGS_BUCKET}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  fi
  awsc s3api wait bucket-exists --bucket "${MEETINGS_BUCKET}"
  ok "bucket creado"
fi
# Bucket policy: permite a Amazon Transcribe leer objetos de este bucket
read_policy=$(jq -n --arg bucket "${MEETINGS_BUCKET}" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"transcribe.amazonaws.com"},Action:["s3:GetObject"],Resource:["arn:aws:s3:::\($bucket)/*"]}]}')
awsc s3api put-bucket-policy --bucket "${MEETINGS_BUCKET}" --policy "${read_policy}" >/dev/null
ok "bucket policy (Transcribe read) configurada"
state_set MEETINGS_BUCKET "${MEETINGS_BUCKET}"

# ------------------------------------------------------------------
# 2) S3 bucket 'transcripts' (output Transcribe) + bucket policy allow Transcribe PutObject
# ------------------------------------------------------------------
log "[2/8] S3 bucket transcripts (Transcribe output)"
if exists s3api head-bucket --bucket "${TRANSCRIPTS_BUCKET}"; then
  ok "bucket ya existe"
else
  if [ "${REGION}" = "us-east-1" ]; then
    awsc s3api create-bucket --bucket "${TRANSCRIPTS_BUCKET}" >/dev/null
  else
    awsc s3api create-bucket --bucket "${TRANSCRIPTS_BUCKET}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  fi
  awsc s3api wait bucket-exists --bucket "${TRANSCRIPTS_BUCKET}"
  ok "bucket creado"
fi
# Bucket policy: permite a Amazon Transcribe escribir objetos en este bucket
write_policy=$(jq -n --arg bucket "${TRANSCRIPTS_BUCKET}" \
  '{Version:"2012-10-17",Statement:[{Effect:"Allow",Principal:{Service:"transcribe.amazonaws.com"},Action:["s3:PutObject"],Resource:["arn:aws:s3:::\($bucket)/*"]}]}')
awsc s3api put-bucket-policy --bucket "${TRANSCRIPTS_BUCKET}" --policy "${write_policy}" >/dev/null
ok "bucket policy (Transcribe write) configurada"
state_set TRANSCRIPTS_BUCKET "${TRANSCRIPTS_BUCKET}"

# ------------------------------------------------------------------
# 3) DynamoDB table (PK = meeting_id)
# ------------------------------------------------------------------
log "[3/8] DynamoDB table"
if exists dynamodb describe-table --table-name "${TABLE_NAME}"; then
  ok "tabla ya existe"
else
  awsc dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=meeting_id,AttributeType=S \
    --key-schema AttributeName=meeting_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  awsc dynamodb wait table-exists --table-name "${TABLE_NAME}"
  ok "tabla creada"
fi
state_set TABLE_NAME "${TABLE_NAME}"
state_set TABLE_ARN "${TABLE_ARN}"

# ------------------------------------------------------------------
# Helpers: roles + lambdas
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

start_policy() {
  jq -n \
    --arg meetings "${MEETINGS_BUCKET}" \
    --arg table "${TABLE_ARN}" \
    --arg logs "${LOGS_ARN}" \
    '{
      Version:"2012-10-17",
      Statement:[
        {Effect:"Allow",Action:["transcribe:StartTranscriptionJob","transcribe:GetTranscriptionJob"],Resource:["*"]},
        {Effect:"Allow",Action:["dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:DescribeTable"],Resource:[$table]},
        {Effect:"Allow",Action:["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],Resource:[$logs]}
      ]
    }'
}

summarize_policy() {
  jq -n \
    --arg transcripts "${TRANSCRIPTS_BUCKET}" \
    --arg table "${TABLE_ARN}" \
    --arg logs "${LOGS_ARN}" \
    '{
      Version:"2012-10-17",
      Statement:[
        {Effect:"Allow",Action:["s3:GetObject"],Resource:["arn:aws:s3:::\($transcripts)/*"]},
        {Effect:"Allow",Action:["comprehend:DetectKeyPhrases","comprehend:DetectEntities","comprehend:DetectDominantLanguage","comprehend:DetectSentiment"],Resource:["*"]},
        {Effect:"Allow",Action:["dynamodb:UpdateItem","dynamodb:DescribeTable"],Resource:[$table]},
        {Effect:"Allow",Action:["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],Resource:[$logs]}
      ]
    }'
}

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
    local created=0
    for i in $(seq 1 15); do
      if awsc lambda create-function \
        --function-name "${fn_name}" \
        --runtime python3.12 \
        --handler handler.lambda_handler \
        --role "${role_arn}" \
        --zip-file "fileb://${zip}" \
        --timeout 60 \
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
# 4) IAM roles (skip si LAMBDA_ROLE_ARN)
# ------------------------------------------------------------------
log "[4/8] IAM roles"
if [ -n "${LAMBDA_ROLE_ARN}" ]; then
  warn "LAMBDA_ROLE_ARN set: reutilizando rol ${LAMBDA_ROLE_ARN} (no se crean roles)"
  ROLE_START_ARN="${LAMBDA_ROLE_ARN}"
  ROLE_SUMMARIZE_ARN="${LAMBDA_ROLE_ARN}"
  state_set ROLE_START_ARN "${ROLE_START_ARN}"
  state_set ROLE_SUMMARIZE_ARN "${ROLE_SUMMARIZE_ARN}"
else
  ROLE_START_ARN="$(create_role "${ROLE_START}"   "$(start_policy)")";    state_set ROLE_START_ARN "${ROLE_START_ARN}"
  ROLE_SUMMARIZE_ARN="$(create_role "${ROLE_SUMMARIZE}" "$(summarize_policy)")"; state_set ROLE_SUMMARIZE_ARN "${ROLE_SUMMARIZE_ARN}"
  ok "roles listos"
fi

# ------------------------------------------------------------------
# 5) Lambdas
# ------------------------------------------------------------------
log "[5/8] Lambdas"
START_ENV="{TRANSCRIPTS_BUCKET=${TRANSCRIPTS_BUCKET},TABLE_NAME=${TABLE_NAME}}"
SUMMARIZE_ENV="{TRANSCRIPTS_BUCKET=${TRANSCRIPTS_BUCKET},TABLE_NAME=${TABLE_NAME}}"

START_ARN="$(create_lambda "${FN_START}"    "${ROLE_START_ARN}"    "${APP_DIR}/src/start_transcribe" "${START_ENV}")"
SUMMARIZE_ARN="$(create_lambda "${FN_SUMMARIZE}" "${ROLE_SUMMARIZE_ARN}" "${APP_DIR}/src/summarize"      "${SUMMARIZE_ENV}")"

state_set FN_START "${FN_START}";          state_set START_ARN "${START_ARN}"
state_set FN_SUMMARIZE "${FN_SUMMARIZE}";  state_set SUMMARIZE_ARN "${SUMMARIZE_ARN}"
ok "lambdas activas"

# ------------------------------------------------------------------
# Helper: notificacion S3 -> Lambda
# ------------------------------------------------------------------
configure_s3_trigger() {
  local bucket="$1" fn_name="$2" fn_arn="$3" sid="$4" prefix="$5"
  # Permiso para S3 invoque la lambda
  if awsc lambda get-policy --function-name "${fn_name}" 2>/dev/null \
     | jq -r '.Policy' 2>/dev/null \
     | jq -e --arg sid "${sid}" '.Statement[]? | select(.Sid==$sid)' >/dev/null 2>&1; then
    ok "permiso ${sid} ya existe en ${fn_name}"
  else
    awsc lambda add-permission \
      --function-name "${fn_name}" \
      --statement-id "${sid}" \
      --action lambda:InvokeFunction \
      --principal s3.amazonaws.com \
      --source-arn "arn:aws:s3:::${bucket}" \
      --source-account "${ACCT}" >/dev/null
    ok "permiso ${sid} anadido a ${fn_name}"
  fi
  # Notificacion del bucket
  local notification
  notification=$(jq -n --arg fn "${fn_arn}" --arg prefix "${prefix}" \
    '{
      LambdaFunctionConfigurations: [
        {
          Id: "s3-trigger",
          LambdaFunctionArn: $fn,
          Events: ["s3:ObjectCreated:*"],
          Filter: {Key: {FilterRules: [{Name: "prefix", Value: $prefix}]}}
        }
      ]
    }')
  local notif_file="${TMP_DIR}/notif-${bucket}.json"
  printf '%s' "${notification}" >"${notif_file}"
  awsc s3api put-bucket-notification-configuration \
    --bucket "${bucket}" \
    --notification-configuration "file://${notif_file}" >/dev/null
  ok "notificacion S3 -> ${fn_name} configurada (prefix=${prefix})"
}

# ------------------------------------------------------------------
# 6) Notificacion S3-1 -> start_transcribe
# ------------------------------------------------------------------
log "[6/8] Trigger S3 meetings -> start_transcribe"
configure_s3_trigger "${MEETINGS_BUCKET}" "${FN_START}" "${START_ARN}" "s3-trigger-start" "meetings/"

# ------------------------------------------------------------------
# 7) Notificacion S3-2 -> summarize
# ------------------------------------------------------------------
log "[7/8] Trigger S3 transcripts -> summarize"
configure_s3_trigger "${TRANSCRIPTS_BUCKET}" "${FN_SUMMARIZE}" "${SUMMARIZE_ARN}" "s3-trigger-summarize" ""

# ------------------------------------------------------------------
# 8) Resumen
# ------------------------------------------------------------------
log "[8/8] Deploy completo"
echo
ok "APP2 DESPLEGADA"
echo "  Input  bucket:  s3://${MEETINGS_BUCKET}    (sube aqui el audio: meetings/<fichero>)"
echo "  Output bucket:  s3://${TRANSCRIPTS_BUCKET}  (Transcribe escribe aqui)"
echo "  DynamoDB table: ${TABLE_NAME}  (PK meeting_id)"
echo "  Estado:         ${STATE_FILE}"
echo
echo "Probar:"
echo "  aws s3 cp app2/events/sample.wav s3://${MEETINGS_BUCKET}/meetings/"
echo "  # esperar 1-3 min y consultar:"
echo "  aws dynamodb scan --table-name ${TABLE_NAME} --region ${REGION}"