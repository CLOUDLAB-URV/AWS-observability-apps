#!/usr/bin/env bash
# destroy.sh — Borra todos los recursos de app2 en orden inverso al deploy.
# Idempotente: si un recurso ya no existe, lo skippea.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

sanity_check
ACCT="$(account_id)"
log "Destruyendo app2 en cuenta=${ACCT} region=${REGION}"

# Recarga nombres desde estado si existe, sino mantiene los cargados de common.sh / entorno
state() { state_get "$1"; }
st_meetings="$(state MEETINGS_BUCKET)"; [ -n "${st_meetings}" ] && MEETINGS_BUCKET="${st_meetings}"
st_transcripts="$(state TRANSCRIPTS_BUCKET)"; [ -n "${st_transcripts}" ] && TRANSCRIPTS_BUCKET="${st_transcripts}"
st_table="$(state TABLE_NAME)"; [ -n "${st_table}" ] && TABLE_NAME="${st_table}"
st_fn_start="$(state FN_START)"; [ -n "${st_fn_start}" ] && FN_START="${st_fn_start}"
st_fn_sum="$(state FN_SUMMARIZE)"; [ -n "${st_fn_sum}" ] && FN_SUMMARIZE="${st_fn_sum}"
ROLE_START="${PREFIX}-start-role"
ROLE_SUMMARIZE="${PREFIX}-summarize-role"

# ------------------------------------------------------------------
# 1) Quitar notificaciones S3 (antes de borrar buckets/Lambdas)
# ------------------------------------------------------------------
log "[1/6] Quitar notificaciones S3"
for bucket in "${MEETINGS_BUCKET}" "${TRANSCRIPTS_BUCKET}"; do
  if awsc s3api put-bucket-notification-configuration \
    --bucket "${bucket}" \
    --notification-configuration '{}' >/dev/null 2>&1; then
    ok "notificacion vaciada en ${bucket}"
  else
    ok "no se pudo vaciar notificacion en ${bucket} (puede que no exista el bucket)"
  fi
done

# ------------------------------------------------------------------
# 2) Lambdas
# ------------------------------------------------------------------
log "[2/6] Lambdas"
for fn in "${FN_START}" "${FN_SUMMARIZE}"; do
  if awsc lambda delete-function --function-name "${fn}" >/dev/null 2>&1; then
    ok "lambda ${fn} borrada"
  else
    ok "lambda ${fn} ya no existe o no se pudo borrar"
  fi
done

# ------------------------------------------------------------------
# 3) IAM roles + inline policies
# ------------------------------------------------------------------
log "[3/6] IAM roles"
if [ -n "${LAMBDA_ROLE_ARN}" ]; then
  ok "roles reutilizados (LAMBDA_ROLE_ARN set) - no se borran"
else
for role in "${ROLE_START}" "${ROLE_SUMMARIZE}"; do
  awsc iam delete-role-policy --role-name "${role}" --policy-name "${role}-inline" >/dev/null 2>&1 || true
  if awsc iam delete-role --role-name "${role}" >/dev/null 2>&1; then
    ok "rol ${role} borrado"
  else
    ok "rol ${role} ya no existe o no se pudo borrar"
  fi
done
fi

# ------------------------------------------------------------------
# 4) S3 buckets (vaciar y borrar)
# ------------------------------------------------------------------
log "[4/6] S3 buckets"
for bucket in "${MEETINGS_BUCKET}" "${TRANSCRIPTS_BUCKET}"; do
  awsc s3 rm "s3://${bucket}" --recursive >/dev/null 2>&1 || true
  awsc s3api delete-bucket-policy --bucket "${bucket}" >/dev/null 2>&1 || true
  if awsc s3api delete-bucket --bucket "${bucket}" >/dev/null 2>&1; then
    ok "bucket ${bucket} borrado"
  else
    ok "bucket ${bucket} ya no existe o no se pudo borrar"
  fi
done

# ------------------------------------------------------------------
# 5) DynamoDB table
# ------------------------------------------------------------------
log "[5/6] DynamoDB table"
if awsc dynamodb delete-table --table-name "${TABLE_NAME}" >/dev/null 2>&1; then
  awsc dynamodb wait table-not-exists --table-name "${TABLE_NAME}" >/dev/null 2>&1 || true
  ok "tabla ${TABLE_NAME} borrada"
else
  ok "tabla ${TABLE_NAME} ya no existe o no se pudo borrar"
fi

# ------------------------------------------------------------------
# 6) Limpieza estado
# ------------------------------------------------------------------
log "[6/6] Limpieza"
rm -f "${STATE_FILE}"
rm -rf "${TMP_DIR}"
echo
ok "DESTROY COMPLETO"