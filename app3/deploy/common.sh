#!/usr/bin/env bash
# common.sh - Variables y helpers compartidos para app3
set -euo pipefail

PREFIX="${PREFIX:-aws-obs-app3}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-default}"
DB_INSTANCE="${PREFIX}-db"
DB_USERNAME="${DB_USERNAME:-admin}"
DB_PASSWORD="${DB_PASSWORD:-}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
MIN_SIZE="${MIN_SIZE:-3}"
MAX_SIZE="${MAX_SIZE:-5}"
DESIRED_CAPACITY="${DESIRED_CAPACITY:-3}"

# Nombres derivados
VPC_NAME="${PREFIX}-vpc"
DB_SUBNET_GROUP="${PREFIX}-db-subnet"
DB_INSTANCE_ID="${PREFIX}-db"
ALB_NAME="${PREFIX}-alb"
TG_NAME="${PREFIX}-tg"
LT_NAME="${PREFIX}-lt"
ASG_NAME="${PREFIX}-asg"
SG_ALB="${PREFIX}-sg-alb"
SG_APP="${PREFIX}-sg-app"
SG_DB="${PREFIX}-sg-db"
IAM_ROLE="${PREFIX}-ec2-role"
IAM_PROFILE="${PREFIX}-ec2-profile"
TARGET_GROUP_NAME="${PREFIX}-tg"
LAUNCH_TEMPLATE_NAME="${PREFIX}-lt"
AUTO_SCALING_GROUP="${PREFIX}-asg"

# Estado
STATE_FILE="${STATE_FILE:-/tmp/.app3-deploy-state}"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)"
TMP_DIR="${TMP_DIR:-/tmp/app3-deploy}"

export AWS_DEFAULT_REGION="${REGION}"
export AWS_PROFILE="${PROFILE}"

# Helpers
log()  { printf '\033[36m[deploy]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[err]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

awsc() { AWS_DEFAULT_REGION="${REGION}" aws --profile "${PROFILE}" --region "${REGION}" "$@"; }

exists() { awsc "$@" >/dev/null 2>&1; }

state_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "${STATE_FILE}")"
  touch "${STATE_FILE}"
  sed -i "/^${key}=/d" "${STATE_FILE}" 2>/dev/null || true
  printf '%s=%s\n' "${key}" "${val}" >> "${STATE_FILE}"
}

state_get() {
  local key="$1"
  [ -f "${STATE_FILE}" ] || return 0
  grep "^${key}=" "${STATE_FILE}" 2>/dev/null | head -n1 | cut -d= -f2-
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"
}

sanity_check() {
  for c in aws jq zip; do require_cmd "$c"; done
  awsc sts get-caller-identity >/dev/null 2>&1 || die "No autenticado en AWS (perfil=${PROFILE})"
  mkdir -p "${TMP_DIR}"
}

account_id() { awsc sts get-caller-identity --query 'Account' --output text; }

# Helpers para recursos
get_or_create_subnet() {
  local vpc_id="$1" cidr="$2" az="$3" name="$4"
  local existing
  existing=$(awsc ec2 describe-subnets --filters "Name=vpc-id,Values=$1" "Name=cidr-block,Values=$2" --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
  if [ -n "${existing}" ] && [ "${existing}" != "None" ]; then
    ok "Subnet ${name} ya existe: ${existing}"
    echo "${existing}"
  else
    local id
    id=$(awsc ec2 create-subnet --vpc-id "$1" --cidr-block "$2" --availability-zone "$3" --query 'Subnet.SubnetId' --output text)
    awsc ec2 create-tags --resources "${id}" --tags "Key=Name,Value=${4}"
    ok "Subnet ${name} creada: ${id}"
    echo "${id}"
  fi
}

get_or_create_igw() {
  local vpc_id="$1"
  local existing
  existing=$(awsc ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$1" --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
  if [ -n "${existing}" ] && [ "${existing}" != "None" ]; then
    ok "IGW ya existe: ${existing}"
    echo "${existing}"
  else
    local id
    id=$(awsc ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
    awsc ec2 attach-internet-gateway --internet-gateway-id "${id}" --vpc-id "$1" >/dev/null
    ok "IGW creado: ${id}"
    echo "${id}"
  fi
}

# Helpers para state
state_set() { local k="$1" v="$2"; mkdir -p "$(dirname "${STATE_FILE}")"; touch "${STATE_FILE}"; sed -i "/^${k}=/d" "${STATE_FILE}" 2>/dev/null || true; printf '%s=%s\n' "${k}" "${v}" >> "${STATE_FILE}"; }
state_get() { [ -f "${STATE_FILE}" ] || return 0; grep "^${1}=" "${STATE_FILE}" 2>/dev/null | head -n1 | cut -d= -f2-; }