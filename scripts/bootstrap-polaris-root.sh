#!/usr/bin/env bash
set -euo pipefail

# One-time Polaris root bootstrap helper for Phase 4.
#
# This wraps the Polaris admin tool bootstrap command and passes DB connection
# values as pod environment variables.

NAMESPACE="${NAMESPACE:-data-platform}"
JOB_NAME="${JOB_NAME:-polaris-bootstrap}"
IMAGE="${IMAGE:-apache/polaris-admin-tool:1.3.0-incubating}"
POLARIS_REALM="${POLARIS_REALM:-POLARIS}"
BOOTSTRAP_PRINCIPAL="${BOOTSTRAP_PRINCIPAL:-root}"

DB_USER="${POLARIS_DB_USER:-}"
DB_PASSWORD="${POLARIS_DB_PASSWORD:-}"
JDBC_URL="${POLARIS_JDBC_URL:-}"
BOOTSTRAP_PASSWORD="${POLARIS_BOOTSTRAP_PASSWORD:-}"

NON_INTERACTIVE="false"

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fatal() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/bootstrap-polaris-root.sh [options]

Bootstrap Polaris internal root credentials for a new metastore.

Options:
  --namespace <name>            Kubernetes namespace (default: data-platform)
  --job-name <name>             Temporary pod name (default: polaris-bootstrap)
  --image <ref>                 Admin tool image (default: apache/polaris-admin-tool:1.3.0-incubating)
  --realm <name>                Polaris realm (default: POLARIS)
  --principal <name>            Bootstrap principal (default: root)
  --db-user <value>             PostgreSQL user
  --db-password <value>         PostgreSQL password
  --jdbc-url <value>            JDBC URL (example: jdbc:postgresql://host:5432/polaris)
  --bootstrap-password <value>  Initial password for bootstrap principal
  --non-interactive             Fail instead of prompting for missing values
  -h, --help                    Show this help

Environment variables (alternative to flags):
  NAMESPACE, JOB_NAME, IMAGE, POLARIS_REALM, BOOTSTRAP_PRINCIPAL,
  POLARIS_DB_USER, POLARIS_DB_PASSWORD, POLARIS_JDBC_URL, POLARIS_BOOTSTRAP_PASSWORD

Example:
  POLARIS_DB_USER=polaris \
  POLARIS_DB_PASSWORD='***' \
  POLARIS_JDBC_URL='jdbc:postgresql://192.168.2.119:5432/polaris' \
  POLARIS_BOOTSTRAP_PASSWORD='***' \
  ./scripts/bootstrap-polaris-root.sh
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
      --job-name)
        JOB_NAME="$2"
        shift 2
        ;;
      --image)
        IMAGE="$2"
        shift 2
        ;;
      --realm)
        POLARIS_REALM="$2"
        shift 2
        ;;
      --principal)
        BOOTSTRAP_PRINCIPAL="$2"
        shift 2
        ;;
      --db-user)
        DB_USER="$2"
        shift 2
        ;;
      --db-password)
        DB_PASSWORD="$2"
        shift 2
        ;;
      --jdbc-url)
        JDBC_URL="$2"
        shift 2
        ;;
      --bootstrap-password)
        BOOTSTRAP_PASSWORD="$2"
        shift 2
        ;;
      --non-interactive)
        NON_INTERACTIVE="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fatal "Unknown option: $1"
        ;;
    esac
  done
}

prompt_if_missing() {
  local name="$1"
  local secret_mode="${2:-false}"

  case "$name" in
    DB_USER)
      if [[ -z "$DB_USER" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
          fatal "Missing required value: DB_USER"
        fi
        read -rp "PostgreSQL user: " DB_USER
      fi
      ;;
    DB_PASSWORD)
      if [[ -z "$DB_PASSWORD" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
          fatal "Missing required value: DB_PASSWORD"
        fi
        if [[ "$secret_mode" == "true" ]]; then
          read -srp "PostgreSQL password: " DB_PASSWORD
          echo
        fi
      fi
      ;;
    JDBC_URL)
      if [[ -z "$JDBC_URL" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
          fatal "Missing required value: JDBC_URL"
        fi
        read -rp "JDBC URL: " JDBC_URL
      fi
      ;;
    BOOTSTRAP_PASSWORD)
      if [[ -z "$BOOTSTRAP_PASSWORD" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
          fatal "Missing required value: BOOTSTRAP_PASSWORD"
        fi
        if [[ "$secret_mode" == "true" ]]; then
          read -srp "Bootstrap password for ${BOOTSTRAP_PRINCIPAL}: " BOOTSTRAP_PASSWORD
          echo
        fi
      fi
      ;;
  esac
}

validate_inputs() {
  [[ -n "$NAMESPACE" ]] || fatal "NAMESPACE cannot be empty"
  [[ -n "$JOB_NAME" ]] || fatal "JOB_NAME cannot be empty"
  [[ -n "$IMAGE" ]] || fatal "IMAGE cannot be empty"
  [[ -n "$POLARIS_REALM" ]] || fatal "POLARIS_REALM cannot be empty"
  [[ -n "$BOOTSTRAP_PRINCIPAL" ]] || fatal "BOOTSTRAP_PRINCIPAL cannot be empty"
  [[ "$BOOTSTRAP_PRINCIPAL" != *","* ]] || fatal "BOOTSTRAP_PRINCIPAL cannot contain commas"

  prompt_if_missing DB_USER
  prompt_if_missing DB_PASSWORD true
  prompt_if_missing JDBC_URL
  prompt_if_missing BOOTSTRAP_PASSWORD true

  [[ -n "$DB_USER" ]] || fatal "DB_USER cannot be empty"
  [[ -n "$DB_PASSWORD" ]] || fatal "DB_PASSWORD cannot be empty"
  [[ -n "$JDBC_URL" ]] || fatal "JDBC_URL cannot be empty"
  [[ -n "$BOOTSTRAP_PASSWORD" ]] || fatal "BOOTSTRAP_PASSWORD cannot be empty"
  [[ "$BOOTSTRAP_PASSWORD" != *","* ]] || fatal "BOOTSTRAP_PASSWORD cannot contain commas"
}

preflight() {
  require_cmd kubectl

  kubectl cluster-info >/dev/null 2>&1 || fatal "kubectl is not configured or cluster is unreachable"
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || fatal "Namespace not found: $NAMESPACE"
}

run_bootstrap() {
  info "Deleting previous bootstrap pod if present"
  kubectl -n "$NAMESPACE" delete pod "$JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true

  info "Running Polaris bootstrap job in namespace '$NAMESPACE'"
  kubectl run "$JOB_NAME" \
    -n "$NAMESPACE" \
    --image="$IMAGE" \
    --restart=Never \
    --rm \
    -i \
    --env="polaris.persistence.type=relational-jdbc" \
    --env="quarkus.datasource.username=${DB_USER}" \
    --env="quarkus.datasource.password=${DB_PASSWORD}" \
    --env="quarkus.datasource.jdbc.url=${JDBC_URL}" \
    -- \
    bootstrap -r "$POLARIS_REALM" -c "${POLARIS_REALM},${BOOTSTRAP_PRINCIPAL},${BOOTSTRAP_PASSWORD}"
}

main() {
  parse_args "$@"
  validate_inputs
  preflight

  warn "This should be run once per fresh Polaris metastore."
  run_bootstrap

  info "Bootstrap command completed"
  info "Next: run ./scripts/init-polaris-catalog.sh to seed principal/roles/catalog/namespace"
}

main "$@"
