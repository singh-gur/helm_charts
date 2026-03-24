#!/usr/bin/env bash
set -euo pipefail

# Register existing Iceberg tables in Polaris using metadata locations.
#
# Supports two input methods:
# 1) --register '<namespace>/<table>=<metadata-location>' (repeatable)
# 2) --input <csv-file> with rows:
#      namespace,table,metadataLocation
#    or:
#      table,metadataLocation   (uses default namespace)

POLARIS_BASE_URL="${POLARIS_BASE_URL:-https://polaris.gsingh.io}"
POLARIS_API_BASE="${POLARIS_API_BASE:-${POLARIS_BASE_URL%/}/api}"
POLARIS_CATALOG="${POLARIS_CATALOG:-iceberg}"
POLARIS_DEFAULT_NAMESPACE="${POLARIS_DEFAULT_NAMESPACE:-default}"
POLARIS_BEARER_TOKEN="${POLARIS_BEARER_TOKEN:-}"
POLARIS_TLS_INSECURE="${POLARIS_TLS_INSECURE:-false}"

ZITADEL_TOKEN_ENDPOINT="${ZITADEL_TOKEN_ENDPOINT:-https://auth.gsingh.io/oauth/v2/token}"
ZITADEL_CLIENT_ID="${ZITADEL_CLIENT_ID:-}"
ZITADEL_CLIENT_SECRET="${ZITADEL_CLIENT_SECRET:-}"
ZITADEL_PROJECT_ID="${ZITADEL_PROJECT_ID:-}"
ZITADEL_SCOPE="${ZITADEL_SCOPE:-}"

INPUT_FILE=""
ENSURE_NAMESPACE="true"
DRY_RUN="false"

declare -a ENTRY_NAMESPACES=()
declare -a ENTRY_TABLES=()
declare -a ENTRY_METADATA=()
declare -a TMP_FILES=()

API_STATUS=""
API_BODY_FILE=""

cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    rm -f "$f"
  done
}
trap cleanup EXIT

info() {
  printf '[INFO] %s\n' "$*" >&2
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
Usage:
  scripts/migrate-iceberg-to-polaris.sh [options] --register '<ns>/<table>=<metadata-location>' [--register ...]
  scripts/migrate-iceberg-to-polaris.sh [options] --input ./tables.csv

Options:
  --register <entry>        Register one table entry (repeatable)
                            Entry formats:
                              <namespace>/<table>=<metadata-location>
                              <table>=<metadata-location>  (uses default namespace)
  --input <csv-file>        CSV with rows: namespace,table,metadataLocation
                            or: table,metadataLocation
  --catalog <name>          Polaris catalog name (default: iceberg)
  --default-namespace <ns>  Namespace used when not specified (default: default)
  --token <bearer-token>    Use an existing Polaris/Zitadel bearer token
  --no-ensure-namespace     Do not auto-create missing namespaces
  --dry-run                 Print actions only, no API calls
  --insecure                Use curl -k for TLS (not recommended)
  -h, --help                Show this help

Token behavior:
  - If --token (or POLARIS_BEARER_TOKEN) is provided, it is used directly.
  - Otherwise, the script requests a token from ZITADEL_TOKEN_ENDPOINT using
    ZITADEL_CLIENT_ID and ZITADEL_CLIENT_SECRET.
  - If ZITADEL_SCOPE is empty and ZITADEL_PROJECT_ID is set, scope defaults to:
      openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:<PROJECT_ID>:aud

Examples:
  scripts/migrate-iceberg-to-polaris.sh \
    --register 'default/orders=s3://datastore/iceberg/default/orders/metadata/00012.metadata.json' \
    --register 'default/customers=s3://datastore/iceberg/default/customers/metadata/00008.metadata.json'

  scripts/migrate-iceberg-to-polaris.sh --input ./tables.csv
EOF
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

namespace_to_path() {
  jq -rn --arg ns "$1" '$ns | split(".") | map(select(length > 0) | @uri) | join("%1F")'
}

json_array_from_namespace() {
  jq -cn --arg ns "$1" '$ns | split(".") | map(select(length > 0))'
}

request_json() {
  local method="$1"
  local url="$2"
  local token="$3"
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

print_api_body() {
  if [[ -n "$API_BODY_FILE" && -s "$API_BODY_FILE" ]]; then
    if jq . "$API_BODY_FILE" >/dev/null 2>&1; then
      jq . "$API_BODY_FILE" >&2 || true
    else
      cat "$API_BODY_FILE" >&2
    fi
  fi
}

get_token() {
  if [[ -n "$POLARIS_BEARER_TOKEN" ]]; then
    printf '%s' "$POLARIS_BEARER_TOKEN"
    return 0
  fi

  [[ -n "$ZITADEL_CLIENT_ID" ]] || fatal "Missing ZITADEL_CLIENT_ID (or provide --token)"
  [[ -n "$ZITADEL_CLIENT_SECRET" ]] || fatal "Missing ZITADEL_CLIENT_SECRET (or provide --token)"

  local scope="$ZITADEL_SCOPE"
  if [[ -z "$scope" && -n "$ZITADEL_PROJECT_ID" ]]; then
    scope="openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:${ZITADEL_PROJECT_ID}:aud"
  fi
  if [[ -z "$scope" ]]; then
    scope="openid"
  fi

  local body_file
  body_file="$(mktemp)"
  TMP_FILES+=("$body_file")

  local args
  args=(
    -sS
    -X POST
    "$ZITADEL_TOKEN_ENDPOINT"
    -o "$body_file"
    -w "%{http_code}"
    -H "Accept: application/json"
    -H "Content-Type: application/x-www-form-urlencoded"
    --data-urlencode "grant_type=client_credentials"
    --data-urlencode "client_id=${ZITADEL_CLIENT_ID}"
    --data-urlencode "client_secret=${ZITADEL_CLIENT_SECRET}"
    --data-urlencode "scope=${scope}"
  )
  if [[ "$POLARIS_TLS_INSECURE" == "true" ]]; then
    args+=( -k )
  fi

  local status
  if ! status="$(curl "${args[@]}")"; then
    fatal "Token request failed: ${ZITADEL_TOKEN_ENDPOINT}"
  fi
  if [[ "$status" != "200" ]]; then
    API_BODY_FILE="$body_file"
    API_STATUS="$status"
    warn "Token request failed with status ${status}"
    print_api_body
    fatal "Cannot continue without token"
  fi

  local token
  token="$(jq -r '.access_token // empty' "$body_file")"
  [[ -n "$token" ]] || fatal "Token endpoint returned empty access_token"
  printf '%s' "$token"
}

add_entry() {
  local namespace="$1"
  local table="$2"
  local metadata_location="$3"

  namespace="$(trim "$namespace")"
  table="$(trim "$table")"
  metadata_location="$(trim "$metadata_location")"

  [[ -n "$namespace" ]] || namespace="$POLARIS_DEFAULT_NAMESPACE"
  [[ -n "$namespace" ]] || fatal "Namespace cannot be empty"
  [[ -n "$table" ]] || fatal "Table cannot be empty"
  [[ -n "$metadata_location" ]] || fatal "metadata-location cannot be empty"

  ENTRY_NAMESPACES+=("$namespace")
  ENTRY_TABLES+=("$table")
  ENTRY_METADATA+=("$metadata_location")
}

parse_register_entry() {
  local entry="$1"
  local lhs
  local metadata_location
  local namespace
  local table

  if [[ "$entry" != *=* ]]; then
    fatal "Invalid --register entry (missing '='): $entry"
  fi

  lhs="${entry%%=*}"
  metadata_location="${entry#*=}"

  if [[ "$lhs" == */* ]]; then
    namespace="${lhs%/*}"
    table="${lhs##*/}"
  else
    namespace="$POLARIS_DEFAULT_NAMESPACE"
    table="$lhs"
  fi

  add_entry "$namespace" "$table" "$metadata_location"
}

parse_input_file() {
  local file="$1"
  [[ -f "$file" ]] || fatal "Input file not found: $file"

  local line
  local namespace
  local table
  local metadata_location
  local line_num=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_num=$((line_num + 1))
    line="$(trim "$line")"

    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    IFS=',' read -r namespace table metadata_location <<<"$line"
    namespace="$(trim "${namespace:-}")"
    table="$(trim "${table:-}")"
    metadata_location="$(trim "${metadata_location:-}")"

    # Support 2-column form: table,metadataLocation
    if [[ -n "$namespace" && -n "$table" && -z "$metadata_location" ]]; then
      if [[ "${namespace,,}" == "table" && "${table,,}" == "metadatalocation" ]]; then
        continue
      fi
      metadata_location="$table"
      table="$namespace"
      namespace="$POLARIS_DEFAULT_NAMESPACE"
    fi

    # Skip optional 3-column header
    if [[ "${namespace,,}" == "namespace" && "${table,,}" == "table" && "${metadata_location,,}" == "metadatalocation" ]]; then
      continue
    fi

    if [[ -z "$table" || -z "$metadata_location" ]]; then
      fatal "Invalid CSV row at line $line_num (expected namespace,table,metadataLocation or table,metadataLocation)"
    fi

    add_entry "$namespace" "$table" "$metadata_location"
  done <"$file"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --register)
        parse_register_entry "$2"
        shift 2
        ;;
      --input)
        INPUT_FILE="$2"
        shift 2
        ;;
      --catalog)
        POLARIS_CATALOG="$2"
        shift 2
        ;;
      --default-namespace)
        POLARIS_DEFAULT_NAMESPACE="$2"
        shift 2
        ;;
      --token)
        POLARIS_BEARER_TOKEN="$2"
        shift 2
        ;;
      --no-ensure-namespace)
        ENSURE_NAMESPACE="false"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --insecure)
        POLARIS_TLS_INSECURE="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fatal "Unknown argument: $1"
        ;;
    esac
  done
}

ensure_namespace_exists() {
  local token="$1"
  local catalog="$2"
  local namespace="$3"

  local catalog_encoded
  local namespace_path
  local namespace_array
  catalog_encoded="$(urlencode "$catalog")"
  namespace_path="$(namespace_to_path "$namespace")"
  namespace_array="$(json_array_from_namespace "$namespace")"

  request_json HEAD "${POLARIS_API_BASE}/catalog/v1/${catalog_encoded}/namespaces/${namespace_path}" "$token"
  case "$API_STATUS" in
    204)
      info "Namespace exists: ${catalog}.${namespace}"
      return 0
      ;;
    404)
      ;;
    *)
      warn "Unable to query namespace ${catalog}.${namespace} (status ${API_STATUS})"
      print_api_body
      return 1
      ;;
  esac

  if [[ "$ENSURE_NAMESPACE" != "true" ]]; then
    warn "Namespace missing and --no-ensure-namespace is set: ${catalog}.${namespace}"
    return 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[dry-run] Would create namespace ${catalog}.${namespace}"
    return 0
  fi

  local payload
  payload="$(jq -cn --argjson ns "$namespace_array" '{namespace:$ns}')"
  request_json POST "${POLARIS_API_BASE}/catalog/v1/${catalog_encoded}/namespaces" "$token" "$payload"
  case "$API_STATUS" in
    200|201|409)
      info "Namespace created (or already exists): ${catalog}.${namespace}"
      return 0
      ;;
    *)
      warn "Failed to create namespace ${catalog}.${namespace} (status ${API_STATUS})"
      print_api_body
      return 1
      ;;
  esac
}

register_table() {
  local token="$1"
  local catalog="$2"
  local namespace="$3"
  local table="$4"
  local metadata_location="$5"

  local catalog_encoded
  local namespace_path
  catalog_encoded="$(urlencode "$catalog")"
  namespace_path="$(namespace_to_path "$namespace")"

  local payload
  payload="$(jq -cn --arg name "$table" --arg ml "$metadata_location" '{name:$name, "metadata-location":$ml}')"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[dry-run] Would register ${catalog}.${namespace}.${table} -> ${metadata_location}"
    return 0
  fi

  request_json POST "${POLARIS_API_BASE}/catalog/v1/${catalog_encoded}/namespaces/${namespace_path}/register" "$token" "$payload"

  case "$API_STATUS" in
    200)
      info "Registered table: ${catalog}.${namespace}.${table}"
      return 0
      ;;
    409)
      info "Table already registered: ${catalog}.${namespace}.${table}"
      return 0
      ;;
    404)
      warn "Namespace or catalog not found while registering ${catalog}.${namespace}.${table}"
      print_api_body
      return 2
      ;;
    *)
      warn "Failed to register table ${catalog}.${namespace}.${table} (status ${API_STATUS})"
      print_api_body
      return 1
      ;;
  esac
}

main() {
  require_cmd curl
  require_cmd jq

  parse_args "$@"

  if [[ -n "$INPUT_FILE" ]]; then
    parse_input_file "$INPUT_FILE"
  fi

  local total
  total="${#ENTRY_TABLES[@]}"
  [[ "$total" -gt 0 ]] || fatal "No table entries provided. Use --register and/or --input."

  local token
  token="$(get_token)"

  info "Polaris API base: ${POLARIS_API_BASE}"
  info "Catalog: ${POLARIS_CATALOG}"
  info "Entries to process: ${total}"

  local i
  local ok=0
  local failed=0

  for ((i = 0; i < total; i++)); do
    local ns
    local table
    local metadata_location
    ns="${ENTRY_NAMESPACES[$i]}"
    table="${ENTRY_TABLES[$i]}"
    metadata_location="${ENTRY_METADATA[$i]}"

    if [[ "$metadata_location" != *"metadata"* || "$metadata_location" != *.metadata.json ]]; then
      warn "metadata-location does not look like a metadata JSON path: ${metadata_location}"
    fi

    if ! ensure_namespace_exists "$token" "$POLARIS_CATALOG" "$ns"; then
      failed=$((failed + 1))
      continue
    fi

    if register_table "$token" "$POLARIS_CATALOG" "$ns" "$table" "$metadata_location"; then
      ok=$((ok + 1))
      continue
    fi

    # One retry after ensuring namespace when register returned 404.
    if [[ "$API_STATUS" == "404" && "$ENSURE_NAMESPACE" == "true" ]]; then
      if ensure_namespace_exists "$token" "$POLARIS_CATALOG" "$ns" \
        && register_table "$token" "$POLARIS_CATALOG" "$ns" "$table" "$metadata_location"; then
        ok=$((ok + 1))
      else
        failed=$((failed + 1))
      fi
    else
      failed=$((failed + 1))
    fi
  done

  info "Completed migration: success=${ok}, failed=${failed}, total=${total}"
  if [[ "$failed" -gt 0 ]]; then
    fatal "Some table registrations failed"
  fi
}

main "$@"
