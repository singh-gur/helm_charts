#!/usr/bin/env bash
set -euo pipefail

# Idempotent Polaris bootstrap script for Phase 4.
#
# What it does:
# 1) Obtains an internal bootstrap token (or uses POLARIS_BOOTSTRAP_TOKEN).
# 2) Ensures external principal, principal roles, catalog, catalog role/grants, and namespace exist.
# 3) Verifies management/catalog API access with bootstrap token.
# 4) Optionally verifies access using an external Zitadel token.

POLARIS_BASE_URL="${POLARIS_BASE_URL:-https://polaris.gsingh.io}"
POLARIS_API_BASE="${POLARIS_API_BASE:-${POLARIS_BASE_URL%/}/api}"
POLARIS_MANAGEMENT_BASE="${POLARIS_MANAGEMENT_BASE:-${POLARIS_API_BASE}/management/v1}"
POLARIS_CATALOG_BASE="${POLARIS_CATALOG_BASE:-${POLARIS_API_BASE}/catalog/v1}"

POLARIS_BOOTSTRAP_TOKEN="${POLARIS_BOOTSTRAP_TOKEN:-}"
POLARIS_BOOTSTRAP_CLIENT_ID="${POLARIS_BOOTSTRAP_CLIENT_ID:-root}"
POLARIS_BOOTSTRAP_CLIENT_SECRET="${POLARIS_BOOTSTRAP_CLIENT_SECRET:-}"
POLARIS_BOOTSTRAP_SCOPE="${POLARIS_BOOTSTRAP_SCOPE:-}"

POLARIS_TARGET_PRINCIPAL="${POLARIS_TARGET_PRINCIPAL:-}"
POLARIS_PRINCIPAL_ROLES="${POLARIS_PRINCIPAL_ROLES:-service_admin,catalog_admin}"

POLARIS_CATALOG_NAME="${POLARIS_CATALOG_NAME:-iceberg}"
POLARIS_NAMESPACE="${POLARIS_NAMESPACE:-default}"
POLARIS_WAREHOUSE_URI="${POLARIS_WAREHOUSE_URI:-s3://datastore/iceberg}"
POLARIS_ALLOWED_LOCATIONS="${POLARIS_ALLOWED_LOCATIONS:-${POLARIS_WAREHOUSE_URI}}"

POLARIS_STORAGE_TYPE="${POLARIS_STORAGE_TYPE:-S3}"
POLARIS_S3_REGION="${POLARIS_S3_REGION:-us-east-1}"
POLARIS_S3_ENDPOINT="${POLARIS_S3_ENDPOINT:-https://s3v2.gsingh.io}"
POLARIS_S3_PATH_STYLE_ACCESS="${POLARIS_S3_PATH_STYLE_ACCESS:-true}"
POLARIS_S3_STS_UNAVAILABLE="${POLARIS_S3_STS_UNAVAILABLE:-true}"
POLARIS_S3_ROLE_ARN="${POLARIS_S3_ROLE_ARN:-}"
POLARIS_S3_EXTERNAL_ID="${POLARIS_S3_EXTERNAL_ID:-}"

POLARIS_CATALOG_ROLE="${POLARIS_CATALOG_ROLE:-catalog_admin}"
POLARIS_CATALOG_GRANTS="${POLARIS_CATALOG_GRANTS:-CATALOG_MANAGE_ACCESS,CATALOG_MANAGE_CONTENT,CATALOG_MANAGE_METADATA,NAMESPACE_CREATE,TABLE_CREATE,NAMESPACE_LIST,TABLE_LIST,TABLE_READ_DATA,TABLE_WRITE_DATA}"

ZITADEL_TOKEN_ENDPOINT="${ZITADEL_TOKEN_ENDPOINT:-https://auth.gsingh.io/oauth/v2/token}"
ZITADEL_CLIENT_ID="${ZITADEL_CLIENT_ID:-}"
ZITADEL_CLIENT_SECRET="${ZITADEL_CLIENT_SECRET:-}"
ZITADEL_PROJECT_ID="${ZITADEL_PROJECT_ID:-}"
ZITADEL_SCOPE="${ZITADEL_SCOPE:-}"

POLARIS_TLS_INSECURE="${POLARIS_TLS_INSECURE:-false}"

API_STATUS=""
API_BODY_FILE=""
TMP_FILES=()

cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    rm -f "$f"
  done
}
trap cleanup EXIT

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

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

json_bool() {
  case "${1,,}" in
    true|1|yes) printf 'true' ;;
    false|0|no) printf 'false' ;;
    *) fatal "Invalid boolean value: $1" ;;
  esac
}

csv_to_lines() {
  local raw="$1"
  local item
  IFS=',' read -r -a items <<<"$raw"
  for item in "${items[@]}"; do
    item="$(trim "$item")"
    if [[ -n "$item" ]]; then
      printf '%s\n' "$item"
    fi
  done
}

print_api_body() {
  if [[ -n "$API_BODY_FILE" && -s "$API_BODY_FILE" ]]; then
    if jq . "$API_BODY_FILE" >/dev/null 2>&1; then
      jq . "$API_BODY_FILE" >&2 || true
    else
      cat "$API_BODY_FILE" >&2
    fi
  fi
}

request_json() {
  local method="$1"
  local url="$2"
  local token="${3:-}"
  local payload="${4:-}"

  local body_file
  body_file="$(mktemp)"
  TMP_FILES+=("$body_file")

  local args
  args=( -sS -X "$method" "$url" -o "$body_file" -w "%{http_code}" -H "Accept: application/json" )
  if [[ "$POLARIS_TLS_INSECURE" == "true" ]]; then
    args+=( -k )
  fi
  if [[ -n "$token" ]]; then
    args+=( -H "Authorization: Bearer ${token}" )
  fi
  if [[ -n "$payload" ]]; then
    args+=( -H "Content-Type: application/json" --data "$payload" )
  fi

  local status
  if ! status="$(curl "${args[@]}")"; then
    fatal "HTTP request failed: ${method} ${url}"
  fi

  API_STATUS="$status"
  API_BODY_FILE="$body_file"
}

oauth_client_credentials_token() {
  local endpoint="$1"
  local client_id="$2"
  local client_secret="$3"
  local scope="${4:-}"

  local body_file
  body_file="$(mktemp)"
  TMP_FILES+=("$body_file")

  local args
  args=(
    -sS
    -X POST
    "$endpoint"
    -o "$body_file"
    -w "%{http_code}"
    -H "Accept: application/json"
    -H "Content-Type: application/x-www-form-urlencoded"
    --data-urlencode "grant_type=client_credentials"
    --data-urlencode "client_id=${client_id}"
    --data-urlencode "client_secret=${client_secret}"
  )

  if [[ "$POLARIS_TLS_INSECURE" == "true" ]]; then
    args+=( -k )
  fi
  if [[ -n "$scope" ]]; then
    args+=( --data-urlencode "scope=${scope}" )
  fi

  local status
  if ! status="$(curl "${args[@]}")"; then
    fatal "Token request failed: ${endpoint}"
  fi

  if [[ "$status" != "200" ]]; then
    API_BODY_FILE="$body_file"
    API_STATUS="$status"
    warn "Token request returned status ${status}"
    print_api_body
    return 1
  fi

  local token
  token="$(jq -r '.access_token // empty' "$body_file")"
  if [[ -z "$token" ]]; then
    API_BODY_FILE="$body_file"
    API_STATUS="$status"
    warn "Token response did not include access_token"
    print_api_body
    return 1
  fi

  printf '%s' "$token"
}

get_bootstrap_token() {
  if [[ -n "$POLARIS_BOOTSTRAP_TOKEN" ]]; then
    printf '%s' "$POLARIS_BOOTSTRAP_TOKEN"
    return 0
  fi

  [[ -n "$POLARIS_BOOTSTRAP_CLIENT_SECRET" ]] || fatal "Set POLARIS_BOOTSTRAP_CLIENT_SECRET or POLARIS_BOOTSTRAP_TOKEN"
  info "Requesting Polaris bootstrap token from ${POLARIS_CATALOG_BASE}/oauth/tokens"
  oauth_client_credentials_token \
    "${POLARIS_CATALOG_BASE}/oauth/tokens" \
    "$POLARIS_BOOTSTRAP_CLIENT_ID" \
    "$POLARIS_BOOTSTRAP_CLIENT_SECRET" \
    "$POLARIS_BOOTSTRAP_SCOPE"
}

get_external_token() {
  local scope="$ZITADEL_SCOPE"
  if [[ -z "$scope" && -n "$ZITADEL_PROJECT_ID" ]]; then
    scope="openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:${ZITADEL_PROJECT_ID}:aud"
  fi
  if [[ -z "$scope" ]]; then
    scope="openid"
  fi

  oauth_client_credentials_token \
    "$ZITADEL_TOKEN_ENDPOINT" \
    "$ZITADEL_CLIENT_ID" \
    "$ZITADEL_CLIENT_SECRET" \
    "$scope"
}

ensure_principal_exists() {
  local token="$1"
  local principal_encoded
  principal_encoded="$(urlencode "$POLARIS_TARGET_PRINCIPAL")"

  request_json GET "${POLARIS_MANAGEMENT_BASE}/principals/${principal_encoded}" "$token"
  if [[ "$API_STATUS" == "200" ]]; then
    info "Principal exists: ${POLARIS_TARGET_PRINCIPAL}"
    return
  fi
  if [[ "$API_STATUS" != "404" ]]; then
    warn "Failed to query principal ${POLARIS_TARGET_PRINCIPAL} (status ${API_STATUS})"
    print_api_body
    fatal "Cannot continue"
  fi

  local payload
  payload="$(jq -cn --arg name "$POLARIS_TARGET_PRINCIPAL" '{principal:{name:$name},credentialRotationRequired:false}')"
  request_json POST "${POLARIS_MANAGEMENT_BASE}/principals" "$token" "$payload"
  case "$API_STATUS" in
    200|201|409)
      info "Principal created (or already present): ${POLARIS_TARGET_PRINCIPAL}"
      ;;
    *)
      warn "Failed to create principal ${POLARIS_TARGET_PRINCIPAL} (status ${API_STATUS})"
      print_api_body
      fatal "Cannot continue"
      ;;
  esac
}

ensure_principal_role_exists() {
  local token="$1"
  local role="$2"
  local role_encoded
  role_encoded="$(urlencode "$role")"

  request_json GET "${POLARIS_MANAGEMENT_BASE}/principal-roles/${role_encoded}" "$token"
  if [[ "$API_STATUS" == "200" ]]; then
    info "Principal role exists: ${role}"
    return
  fi
  if [[ "$API_STATUS" != "404" ]]; then
    warn "Failed to query principal role ${role} (status ${API_STATUS})"
    print_api_body
    fatal "Cannot continue"
  fi

  local payload
  payload="$(jq -cn --arg name "$role" '{principalRole:{name:$name}}')"
  request_json POST "${POLARIS_MANAGEMENT_BASE}/principal-roles" "$token" "$payload"
  case "$API_STATUS" in
    200|201|409)
      info "Principal role created (or already present): ${role}"
      ;;
    *)
      warn "Failed to create principal role ${role} (status ${API_STATUS})"
      print_api_body
      fatal "Cannot continue"
      ;;
  esac
}

ensure_principal_role_assignment() {
  local token="$1"
  local role="$2"
  local principal_encoded
  principal_encoded="$(urlencode "$POLARIS_TARGET_PRINCIPAL")"

  request_json GET "${POLARIS_MANAGEMENT_BASE}/principals/${principal_encoded}/principal-roles" "$token"
  if [[ "$API_STATUS" == "200" ]]; then
    if jq -e --arg role "$role" '.roles[]? | select(.name == $role)' "$API_BODY_FILE" >/dev/null 2>&1; then
      info "Principal role already assigned: ${POLARIS_TARGET_PRINCIPAL} -> ${role}"
      return
    fi
  fi

  local payload
  payload="$(jq -cn --arg name "$role" '{principalRole:{name:$name}}')"
  request_json PUT "${POLARIS_MANAGEMENT_BASE}/principals/${principal_encoded}/principal-roles" "$token" "$payload"
  case "$API_STATUS" in
    200|201|409)
      info "Assigned principal role: ${POLARIS_TARGET_PRINCIPAL} -> ${role}"
      ;;
    *)
      warn "Failed assigning principal role ${role} to ${POLARIS_TARGET_PRINCIPAL} (status ${API_STATUS})"
      print_api_body
      fatal "Cannot continue"
      ;;
  esac
}

ensure_catalog_exists() {
  local token="$1"
  local catalog_encoded
  catalog_encoded="$(urlencode "$POLARIS_CATALOG_NAME")"

  request_json GET "${POLARIS_MANAGEMENT_BASE}/catalogs/${catalog_encoded}" "$token"
  if [[ "$API_STATUS" == "200" ]]; then
    info "Catalog exists: ${POLARIS_CATALOG_NAME}"
    return
  fi
  if [[ "$API_STATUS" != "404" ]]; then
    warn "Failed to query catalog ${POLARIS_CATALOG_NAME} (status ${API_STATUS})"
    print_api_body
    fatal "Cannot continue"
  fi

  local path_style
  local sts_unavailable
  local allowed_locations_json
  path_style="$(json_bool "$POLARIS_S3_PATH_STYLE_ACCESS")"
  sts_unavailable="$(json_bool "$POLARIS_S3_STS_UNAVAILABLE")"
  allowed_locations_json="$(jq -cn --arg raw "$POLARIS_ALLOWED_LOCATIONS" '$raw | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"

  local payload
  payload="$({
    jq -cn \
      --arg name "$POLARIS_CATALOG_NAME" \
      --arg warehouse "$POLARIS_WAREHOUSE_URI" \
      --arg storageType "$POLARIS_STORAGE_TYPE" \
      --arg region "$POLARIS_S3_REGION" \
      --arg endpoint "$POLARIS_S3_ENDPOINT" \
      --arg roleArn "$POLARIS_S3_ROLE_ARN" \
      --arg externalId "$POLARIS_S3_EXTERNAL_ID" \
      --argjson allowedLocations "$allowed_locations_json" \
      --argjson pathStyle "$path_style" \
      --argjson stsUnavailable "$sts_unavailable" \
      '{
        catalog: {
          type: "INTERNAL",
          name: $name,
          properties: {"default-base-location": $warehouse},
          storageConfigInfo: {
            storageType: $storageType,
            allowedLocations: $allowedLocations
          }
        }
      }
      | if $storageType == "S3" then
          .catalog.storageConfigInfo += {
            region: $region,
            endpoint: $endpoint,
            pathStyleAccess: $pathStyle,
            stsUnavailable: $stsUnavailable
          }
        else . end
      | if $roleArn != "" then .catalog.storageConfigInfo.roleArn = $roleArn else . end
      | if $externalId != "" then .catalog.storageConfigInfo.externalId = $externalId else . end'
  })"

  request_json POST "${POLARIS_MANAGEMENT_BASE}/catalogs" "$token" "$payload"
  case "$API_STATUS" in
    200|201|409)
      info "Catalog created (or already present): ${POLARIS_CATALOG_NAME}"
      ;;
    *)
      warn "Failed to create catalog ${POLARIS_CATALOG_NAME} (status ${API_STATUS})"
      print_api_body
      fatal "Cannot continue"
      ;;
  esac
}

ensure_catalog_role_exists() {
  local token="$1"
  local catalog_encoded
  local role_encoded
  catalog_encoded="$(urlencode "$POLARIS_CATALOG_NAME")"
  role_encoded="$(urlencode "$POLARIS_CATALOG_ROLE")"

  request_json GET "${POLARIS_MANAGEMENT_BASE}/catalogs/${catalog_encoded}/catalog-roles/${role_encoded}" "$token"
  if [[ "$API_STATUS" == "200" ]]; then
    info "Catalog role exists: ${POLARIS_CATALOG_NAME}/${POLARIS_CATALOG_ROLE}"
    return
  fi
  if [[ "$API_STATUS" != "404" ]]; then
    warn "Failed to query catalog role ${POLARIS_CATALOG_ROLE} (status ${API_STATUS})"
    print_api_body
    fatal "Cannot continue"
  fi

  local payload
  payload="$(jq -cn --arg name "$POLARIS_CATALOG_ROLE" '{catalogRole:{name:$name}}')"
  request_json POST "${POLARIS_MANAGEMENT_BASE}/catalogs/${catalog_encoded}/catalog-roles" "$token" "$payload"
  case "$API_STATUS" in
    200|201|409)
      info "Catalog role created (or already present): ${POLARIS_CATALOG_ROLE}"
      ;;
    *)
      warn "Failed to create catalog role ${POLARIS_CATALOG_ROLE} (status ${API_STATUS})"
      print_api_body
      fatal "Cannot continue"
      ;;
  esac
}

ensure_catalog_grant() {
  local token="$1"
  local grant_name="$2"
  local catalog_encoded
  local role_encoded
  catalog_encoded="$(urlencode "$POLARIS_CATALOG_NAME")"
  role_encoded="$(urlencode "$POLARIS_CATALOG_ROLE")"

  request_json GET "${POLARIS_MANAGEMENT_BASE}/catalogs/${catalog_encoded}/catalog-roles/${role_encoded}/grants" "$token"
  if [[ "$API_STATUS" == "200" ]]; then
    if jq -e --arg g "$grant_name" '.. | objects | select(.type? == "catalog" and .privilege? == $g)' "$API_BODY_FILE" >/dev/null 2>&1; then
      info "Catalog grant already present: ${POLARIS_CATALOG_ROLE} -> ${grant_name}"
      return
    fi
  fi

  local payload
  payload="$(jq -cn --arg g "$grant_name" '{grant:{type:"catalog",privilege:$g}}')"
  request_json PUT "${POLARIS_MANAGEMENT_BASE}/catalogs/${catalog_encoded}/catalog-roles/${role_encoded}/grants" "$token" "$payload"
  case "$API_STATUS" in
    200|201|409)
      info "Catalog grant added: ${POLARIS_CATALOG_ROLE} -> ${grant_name}"
      ;;
    *)
      warn "Failed to add catalog grant ${grant_name} (status ${API_STATUS})"
      print_api_body
      fatal "Cannot continue"
      ;;
  esac
}

ensure_catalog_role_assignment_to_principal_role() {
  local token="$1"
  local principal_role="$2"
  local principal_role_encoded
  local catalog_encoded
  principal_role_encoded="$(urlencode "$principal_role")"
  catalog_encoded="$(urlencode "$POLARIS_CATALOG_NAME")"

  local payload
  payload="$(jq -cn --arg name "$POLARIS_CATALOG_ROLE" '{catalogRole:{name:$name}}')"
  request_json PUT "${POLARIS_MANAGEMENT_BASE}/principal-roles/${principal_role_encoded}/catalog-roles/${catalog_encoded}" "$token" "$payload"
  case "$API_STATUS" in
    200|201|409)
      info "Mapped catalog role to principal role: ${principal_role} -> ${POLARIS_CATALOG_NAME}/${POLARIS_CATALOG_ROLE}"
      ;;
    *)
      warn "Failed to map catalog role to principal role ${principal_role} (status ${API_STATUS})"
      print_api_body
      fatal "Cannot continue"
      ;;
  esac
}

ensure_namespace_exists() {
  local token="$1"
  local catalog_encoded
  local namespace_parts_json
  local namespace_path
  catalog_encoded="$(urlencode "$POLARIS_CATALOG_NAME")"
  namespace_parts_json="$(jq -cn --arg ns "$POLARIS_NAMESPACE" '$ns | split(".") | map(select(length > 0))')"
  namespace_path="$(jq -rn --argjson n "$namespace_parts_json" '$n | map(@uri) | join("%1F")')"

  [[ "$namespace_path" != "" ]] || fatal "POLARIS_NAMESPACE is empty"

  request_json HEAD "${POLARIS_CATALOG_BASE}/${catalog_encoded}/namespaces/${namespace_path}" "$token"
  if [[ "$API_STATUS" == "204" ]]; then
    info "Namespace exists: ${POLARIS_CATALOG_NAME}.${POLARIS_NAMESPACE}"
    return
  fi
  if [[ "$API_STATUS" != "404" ]]; then
    warn "Failed to query namespace ${POLARIS_NAMESPACE} (status ${API_STATUS})"
    print_api_body
    fatal "Cannot continue"
  fi

  local payload
  payload="$(jq -cn --argjson ns "$namespace_parts_json" '{namespace:$ns}')"
  request_json POST "${POLARIS_CATALOG_BASE}/${catalog_encoded}/namespaces" "$token" "$payload"
  case "$API_STATUS" in
    200|201|409)
      info "Namespace created (or already present): ${POLARIS_CATALOG_NAME}.${POLARIS_NAMESPACE}"
      ;;
    *)
      warn "Failed to create namespace ${POLARIS_NAMESPACE} (status ${API_STATUS})"
      print_api_body
      fatal "Cannot continue"
      ;;
  esac
}

verify_token_access() {
  local token="$1"
  local label="$2"
  local catalog_encoded
  catalog_encoded="$(urlencode "$POLARIS_CATALOG_NAME")"

  request_json GET "${POLARIS_MANAGEMENT_BASE}/principals" "$token"
  [[ "$API_STATUS" == "200" ]] || {
    warn "${label} token failed principals check (status ${API_STATUS})"
    print_api_body
    fatal "Token verification failed"
  }

  request_json GET "${POLARIS_CATALOG_BASE}/${catalog_encoded}/namespaces" "$token"
  [[ "$API_STATUS" == "200" ]] || {
    warn "${label} token failed namespaces check (status ${API_STATUS})"
    print_api_body
    fatal "Token verification failed"
  }

  info "${label} token verified against management and catalog APIs"
}

main() {
  require_cmd curl
  require_cmd jq

  [[ -n "$POLARIS_TARGET_PRINCIPAL" ]] || fatal "Set POLARIS_TARGET_PRINCIPAL to the external subject (Zitadel sub) to seed"

  info "Using Polaris API base: ${POLARIS_API_BASE}"
  info "Target principal: ${POLARIS_TARGET_PRINCIPAL}"
  info "Catalog/namespace: ${POLARIS_CATALOG_NAME}.${POLARIS_NAMESPACE}"

  local bootstrap_token
  bootstrap_token="$(get_bootstrap_token)"
  [[ -n "$bootstrap_token" ]] || fatal "Bootstrap token is empty"

  ensure_principal_exists "$bootstrap_token"

  while IFS= read -r role; do
    ensure_principal_role_exists "$bootstrap_token" "$role"
    ensure_principal_role_assignment "$bootstrap_token" "$role"
  done < <(csv_to_lines "$POLARIS_PRINCIPAL_ROLES")

  ensure_catalog_exists "$bootstrap_token"
  ensure_catalog_role_exists "$bootstrap_token"

  while IFS= read -r grant_name; do
    ensure_catalog_grant "$bootstrap_token" "$grant_name"
  done < <(csv_to_lines "$POLARIS_CATALOG_GRANTS")

  while IFS= read -r role; do
    ensure_catalog_role_assignment_to_principal_role "$bootstrap_token" "$role"
  done < <(csv_to_lines "$POLARIS_PRINCIPAL_ROLES")

  ensure_namespace_exists "$bootstrap_token"
  verify_token_access "$bootstrap_token" "Bootstrap"

  if [[ -n "$ZITADEL_CLIENT_ID" && -n "$ZITADEL_CLIENT_SECRET" ]]; then
    info "Verifying external OIDC path via Zitadel token endpoint"
    local external_token
    external_token="$(get_external_token)"
    verify_token_access "$external_token" "External"
  else
    warn "Skipping external token verification (set ZITADEL_CLIENT_ID and ZITADEL_CLIENT_SECRET to enable)"
  fi

  info "Polaris initialization completed successfully"
}

main "$@"
