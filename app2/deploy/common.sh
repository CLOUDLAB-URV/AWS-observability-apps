#!/usr/bin/env bash
# common.sh — variables y helpers compartidos entre deploy.sh y destroy.sh de app2.
# Se carga con `source common.sh` (no se ejecuta directamente).
set -euo pipefail

# ------------------------------------------------------------------
# Configuracion (overrides via entorno)
# ------------------------------------------------------------------
PREFIX="${PREFIX:-aws-obs-app2}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-default}"

# Helper rápido para conseguir el ID de cuenta de forma defensiva antes de declarar variables dependientes
awsc() {
  aws --profile "${PROFILE}" --region "${REGION}" "$@"
}
exists() {
  awsc "$@" >/dev/null 2>&1
}

ACCT_ID=$(awsc sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "608731545470")

MEETINGS_BUCKET="${MEETINGS_BUCKET:-${PREFIX}-meetings-${ACCT_ID}}"
TRANSCRIPTS_BUCKET="${TRANSCRIPTS_BUCKET:-${PREFIX}-transcripts-${ACCT_ID}}"
TABLE_NAME="${TABLE_NAME:-${PREFIX}-summary}"

# Nombres derivados
FN_START="${PREFIX}-start-transcribe"
FN_SUMMARIZE="${PREFIX}-summarize"
ROLE_START="${PREFIX}-start-role"
ROLE_SUMMARIZE="${PREFIX}-summarize-role"

# Si se indica un rol Lambda ya existente, se reutiliza para las 2 funciones.
# Lo auto-detectamos de Vocareum (LabRole) si no se pasa por entorno para que no falle.
LAMBDA_ROLE_ARN="${LAMBDA_ROLE_ARN:-}"
if [ -z "${LAMBDA_ROLE_ARN}" ] && [ "${ACCT_ID}" != "demo" ]; then
  if awsc iam get-role --role-name "LabRole" >/dev/null 2>&1; then
    LAMBDA_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/LabRole"
  fi
fi

# Fichero de estado para compartir IDs entre deploy y destroy
STATE_FILE="${STATE_FILE:-/tmp/.app2-deploy-state}"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)"
TMP_DIR="${TMP_DIR:-/tmp/app2-deploy}"

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
log()  { printf '\033[36m[deploy]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[err]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

awsc() {
  AWS_DEFAULT_REGION="${REGION}" aws --profile "${PROFILE}" --region "${REGION}" "$@"
}

exists() {
  awsc "$@" >/dev/null 2>&1
}

state_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "${STATE_FILE}")"
  touch "${STATE_FILE}"
  if grep -q "^${key}=" "${STATE_FILE}" 2>/dev/null; then
    sed -i "/^${key}=/d" "${STATE_FILE}"
  fi
  printf '%s=%s\n' "${key}" "${val}" >> "${STATE_FILE}"
}

state_get() {
  local key="$1"
  [ -f "${STATE_FILE}" ] || return 0
  grep "^${key}=" "${STATE_FILE}" 2>/dev/null | head -n1 | cut -d= -f2-
}

export AWS_DEFAULT_REGION="${REGION}"
export AWS_PROFILE="${PROFILE}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1 (instálalo o ponlo en PATH)"
}

sanity_check() {
  for c in aws jq zip; do require_cmd "$c"; done
  awsc sts get-caller-identity >/dev/null 2>&1 \
    || die "No se pudo autenticar contra AWS (perfil=${PROFILE}). Ejecuta 'aws configure'."
  mkdir -p "${TMP_DIR}"
}

account_id() {
  awsc sts get-caller-identity --query 'Account' --output text
}