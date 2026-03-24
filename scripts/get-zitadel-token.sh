#!/usr/bin/env bash
set -euo pipefail

# Get a Zitadel access token using client credentials.
# Prints the access token to stdout by default.

TOKEN_ENDPOINT="${ZITADEL_TOKEN_ENDPOINT:-https://auth.gsingh.io/oauth/v2/token}"
CLIENT_ID="${ZITADEL_CLIENT_ID:-}"
CLIENT_SECRET="${ZITADEL_CLIENT_SECRET:-}"
PROJECT_ID="${ZITADEL_PROJECT_ID:-}"
SCOPE="${ZITADEL_SCOPE:-}"
INSECURE="false"
OUTPUT="token" # token|json
SHOW_CLAIMS="false"

info() {
  printf '[INFO] %s\n' "$*" >&2
}

fatal() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  scripts/get-zitadel-token.sh [options]

Options:
  --client-id <id>          Zitadel OAuth client id
  --client-secret <secret>  Zitadel OAuth client secret
  --project-id <id>         Zitadel project id (used to build default scope)
  --scope <scope>           Explicit scope override
  --token-endpoint <url>    OAuth token endpoint (default: https://auth.gsingh.io/oauth/v2/token)
  --output <token|json>     Output token only (default) or full JSON response
  --show-claims             Decode and print JWT claims to stderr
  --insecure                Use curl -k for TLS
  -h, --help                Show this help

Environment variable equivalents:
  ZITADEL_CLIENT_ID, ZITADEL_CLIENT_SECRET, ZITADEL_PROJECT_ID,
  ZITADEL_SCOPE, ZITADEL_TOKEN_ENDPOINT

Default scope behavior:
  - If --scope is set, it is used as-is.
  - Else if --project-id is set, scope becomes:
      openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:<PROJECT_ID>:aud
  - Else fallback scope is: openid

Examples:
  scripts/get-zitadel-token.sh \
    --client-id trino-polaris-client \
    --client-secret '***' \
    --project-id 364792216679351793

  scripts/get-zitadel-token.sh --output json --show-claims
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "Required command not found: $1"
}

decode_claims() {
  local token="$1"
  local payload
  payload="$(printf '%s' "$token" | cut -d'.' -f2)"
  [[ -n "$payload" ]] || {
    info "Unable to decode claims: invalid JWT format"
    return 0
  }
  payload="${payload//-/+}"
  payload="${payload//_/\/}"
  local mod
  mod=$(( ${#payload} % 4 ))
  if (( mod > 0 )); then
    payload+="$(printf '%*s' "$((4-mod))" '' | tr ' ' '=')"
  fi

  info "Decoded JWT claims:"
  printf '%s' "$payload" | base64 -d 2>/dev/null | jq . >&2 || info "Unable to decode claims payload"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --client-id)
        CLIENT_ID="$2"
        shift 2
        ;;
      --client-secret)
        CLIENT_SECRET="$2"
        shift 2
        ;;
      --project-id)
        PROJECT_ID="$2"
        shift 2
        ;;
      --scope)
        SCOPE="$2"
        shift 2
        ;;
      --token-endpoint)
        TOKEN_ENDPOINT="$2"
        shift 2
        ;;
      --output)
        OUTPUT="$2"
        shift 2
        ;;
      --show-claims)
        SHOW_CLAIMS="true"
        shift
        ;;
      --insecure)
        INSECURE="true"
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

main() {
  require_cmd curl
  require_cmd jq

  parse_args "$@"

  [[ "$OUTPUT" == "token" || "$OUTPUT" == "json" ]] || fatal "--output must be 'token' or 'json'"
  [[ -n "$CLIENT_ID" ]] || fatal "Missing client id (set --client-id or ZITADEL_CLIENT_ID)"
  [[ -n "$CLIENT_SECRET" ]] || fatal "Missing client secret (set --client-secret or ZITADEL_CLIENT_SECRET)"

  if [[ -z "$SCOPE" ]]; then
    if [[ -n "$PROJECT_ID" ]]; then
      SCOPE="openid urn:zitadel:iam:org:projects:roles urn:zitadel:iam:org:project:id:${PROJECT_ID}:aud"
    else
      SCOPE="openid"
    fi
  fi

  local response_file
  response_file="$(mktemp)"
  trap 'rm -f "$response_file"' EXIT

  local args
  args=(
    -sS
    -X POST
    "$TOKEN_ENDPOINT"
    -o "$response_file"
    -w "%{http_code}"
    -H "Accept: application/json"
    -H "Content-Type: application/x-www-form-urlencoded"
    --data-urlencode "grant_type=client_credentials"
    --data-urlencode "client_id=${CLIENT_ID}"
    --data-urlencode "client_secret=${CLIENT_SECRET}"
    --data-urlencode "scope=${SCOPE}"
  )
  if [[ "$INSECURE" == "true" ]]; then
    args+=( -k )
  fi

  local status
  status="$(curl "${args[@]}")" || fatal "Token request failed"
  if [[ "$status" != "200" ]]; then
    jq . "$response_file" >&2 2>/dev/null || cat "$response_file" >&2
    fatal "Token request failed with HTTP ${status}"
  fi

  if [[ "$OUTPUT" == "json" ]]; then
    jq . "$response_file"
  else
    local token
    token="$(jq -r '.access_token // empty' "$response_file")"
    [[ -n "$token" ]] || fatal "Token endpoint returned empty access_token"
    printf '%s\n' "$token"
    if [[ "$SHOW_CLAIMS" == "true" ]]; then
      decode_claims "$token"
    fi
  fi
}

main "$@"
