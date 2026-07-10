#!/usr/bin/env bash
# common.sh — variables compartidas y helpers para deploy.sh / destroy.sh.
# Se carga con `source common.sh` (no se ejecuta directamente).
set -euo pipefail

# ------------------------------------------------------------------
# Configuracion (overrides via entorno)
# ------------------------------------------------------------------
PREFIX="${PREFIX:-aws-obs-app1}"
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

BUCKET_NAME="${BUCKET_NAME:-${PREFIX}-metrics-${ACCT_ID}}"
TABLE_NAME="${TABLE_NAME:-${PREFIX}-metrics}"
API_NAME="${API_NAME:-${PREFIX}-api}"

# Nombres derivados
FN_UPLOAD="${PREFIX}-upload"
FN_PROCESS="${PREFIX}-process"
ROLE_UPLOAD="${PREFIX}-upload-role"
ROLE_PROCESS="${PREFIX}-process-role"

# Si se indica un rol Lambda ya existente, se reutiliza para las funciones.
# Lo auto-detectamos de Vocareum (LabRole) si no se pasa por entorno para que no falle.
LAMBDA_ROLE_ARN="${LAMBDA_ROLE_ARN:-}"
if [ -z "${LAMBDA_ROLE_ARN}" ] && [ "${ACCT_ID}" != "demo" ]; then
  if awsc iam get-role --role-name "LabRole" >/dev/null 2>&1; then
    LAMBDA_ROLE_ARN="arn:aws:iam::${ACCT_ID}:role/LabRole"
  fi
fi

# Fichero de estado para compartir IDs entre deploy y destroy
STATE_FILE="${STATE_FILE:-/tmp/.app1-deploy-state}"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)"
TMP_DIR="${TMP_DIR:-/tmp/app1-deploy}"

# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------
log()  { printf '\033[36m[deploy]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[err]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Ejecuta aws CLI con el perfil y región configurados.
awsc() {
  AWS_DEFAULT_REGION="${REGION}" aws --profile "${PROFILE}" --region "${REGION}" "$@"
}

# Comprueba si un recurso existe (comando devuelto via $1) sin fallar.
exists() {
  awsc "$@" >/dev/null 2>&1
}

# Guarda un par key=value en el fichero de estado.
state_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "${STATE_FILE}")"
  touch "${STATE_FILE}"
  # borra clave previa y anade la nueva
  if grep -q "^${key}=" "${STATE_FILE}" 2>/dev/null; then
    sed -i "/^${key}=/d" "${STATE_FILE}"
  fi
  printf '%s=%s\n' "${key}" "${val}" >> "${STATE_FILE}"
}

# Lee un valor del fichero de estado (vacio si falta).
state_get() {
  local key="$1"
  [ -f "${STATE_FILE}" ] || return 0
  grep "^${key}=" "${STATE_FILE}" 2>/dev/null | head -n1 | cut -d= -f2-
}

# Exports convenience
export AWS_DEFAULT_REGION="${REGION}"
export AWS_PROFILE="${PROFILE}"

# Sanity checks
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1 (instálalo o ponlo en PATH)"
}

sanity_check() {
  for c in aws jq zip curl; do require_cmd "$c"; done
  awsc sts get-caller-identity >/dev/null 2>&1 \
    || die "No se pudo autenticar contra AWS (perfil=${PROFILE}). Ejecuta 'aws configure'."
  mkdir -p "${TMP_DIR}"
}

account_id() {
  awsc sts get-caller-identity --query 'Account' --output text
}