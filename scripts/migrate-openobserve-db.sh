#!/usr/bin/env bash
set -euo pipefail

# Migrate the OpenObserve metadata DB (incl. OpenFGA tables if they share it) to another
# Postgres instance with pg_dump/pg_restore, then optionally repoint openobserve-credentials.
#
# Prereqs: openobserve.enabled=false pushed and synced (script refuses to dump while pods run),
# target role/database exist and are owned by the app user. Same password is used for both DBs.
# Every command is printed before it runs; risky steps ask for confirmation.

OLD_HOST="${OLD_HOST:-192.168.2.119}"
OLD_PORT="${OLD_PORT:-5432}"
NEW_HOST="${NEW_HOST:-192.168.2.119}"
NEW_PORT="${NEW_PORT:-5435}"
DB_USER="${DB_USER:-openobserve}"
DB_NAME="${DB_NAME:-openobserve}"
PG_IMAGE="${PG_IMAGE:-postgres:18}"
NAMESPACE="${NAMESPACE:-default}"
SECRET_NAME="${SECRET_NAME:-openobserve-credentials}"
WORK_DIR="${WORK_DIR:-$HOME/oo-migrate}"
DUMP_FILE="openobserve.dump"

info() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fatal() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# Print the exact command (shell-quoted) to stderr, then run it. PGPASSWORD is passed by name only.
run() {
  { printf '\n$'; printf ' %q' "$@"; printf '\n'; } >&2
  "$@"
}

confirm() {
  local reply
  read -r -p "$1 [y/N] " reply
  [[ "$reply" == [yY] ]]
}

pg_old() {
  run docker run --rm --network host --user "$(id -u):$(id -g)" -v "$WORK_DIR:/work:Z" -w /work \
    -e PGHOST="$OLD_HOST" -e PGPORT="$OLD_PORT" -e PGUSER="$DB_USER" -e PGDATABASE="$DB_NAME" -e PGPASSWORD \
    "$PG_IMAGE" "$@"
}

pg_new() {
  run docker run --rm --network host --user "$(id -u):$(id -g)" -v "$WORK_DIR:/work:Z" -w /work \
    -e PGHOST="$NEW_HOST" -e PGPORT="$NEW_PORT" -e PGUSER="$DB_USER" -e PGDATABASE="$DB_NAME" -e PGPASSWORD \
    "$PG_IMAGE" "$@"
}

for bin in docker kubectl jq diff; do
  command -v "$bin" >/dev/null || fatal "$bin not found"
done

cat <<EOF
OpenObserve DB migration
  from: $DB_USER@$OLD_HOST:$OLD_PORT/$DB_NAME
  to:   $DB_USER@$NEW_HOST:$NEW_PORT/$DB_NAME
  work: $WORK_DIR (dump + logs, contains sensitive data)
EOF

read -rs -p "Password for $DB_USER (same on both DBs): " PGPASSWORD; echo
[[ -n "$PGPASSWORD" ]] || fatal "empty password"
export PGPASSWORD

mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"
cd "$WORK_DIR"

info "1/6 OpenObserve must be stopped"
# Match by name: the openfga pod lacks the app.kubernetes.io/instance label.
pods="$(run kubectl get pods -n "$NAMESPACE" -o name | grep 'openobserve-' || true)"
[[ -z "$pods" ]] || fatal "OpenObserve pods still running; push openobserve.enabled=false and wait:
$pods"
app="$(run kubectl get application openobserve -n "$NAMESPACE" --ignore-not-found -o name)"
[[ -z "$app" ]] || fatal "Application openobserve still exists in $NAMESPACE; wait for deletion to finish"

info "2/6 Pre-checks"
pg_old psql -v ON_ERROR_STOP=1 -c '\dx'
# pgvector is not used by OpenObserve/OpenFGA; it is excluded from the dump, so refuse if any column relies on it.
vec_sql="select count(*) from pg_attribute a join pg_class c on c.oid = a.attrelid where a.attnum > 0 and not a.attisdropped and c.relkind in ('r','p','m') and a.atttypid in (select objid from pg_depend where classid = 'pg_type'::regclass and deptype = 'e' and refobjid in (select oid from pg_extension where extname = 'vector'))"
vec_cols="$(pg_old psql -Atc "$vec_sql")"
[[ "$vec_cols" == "0" ]] || fatal "$vec_cols column(s) use pgvector types; cannot exclude the vector extension"
fga="$(pg_old psql -Atc "select coalesce(to_regclass('public.tuple')::text,'') || coalesce(to_regclass('public.authorization_model')::text,'')")"
[[ -n "$fga" ]] || warn "OpenFGA tables not found in old DB; OpenFGA may use a separate DB that this script does NOT migrate"
owner="$(pg_new psql -Atc "select pg_get_userbyid(datdba) from pg_database where datname = current_database()")"
[[ "$owner" == "$DB_USER" ]] || fatal "new DB owner is '$owner', expected '$DB_USER'"
tables="$(pg_new psql -Atc "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")"
[[ "$tables" == "0" ]] || fatal "new DB is not empty ($tables tables); refusing to restore"

info "3/6 Dump old DB"
confirm "Run pg_dump?" || fatal "aborted"
pg_old pg_dump -Fc --exclude-extension=vector -f "$DUMP_FILE" || fatal "pg_dump failed"
data_entries="$(pg_old pg_restore -l "$DUMP_FILE" | grep -c 'TABLE DATA' || true)"
[[ "$data_entries" -gt 0 ]] || fatal "dump has no TABLE DATA entries"
echo "dump OK: $data_entries tables with data"

info "4/6 Restore into new DB"
confirm "Run pg_restore?" || fatal "aborted"
if ! pg_new pg_restore --no-owner --no-acl -j4 -d "$DB_NAME" "$DUMP_FILE" 2> >(tee restore.log >&2); then
  warn "pg_restore reported errors (full output in $WORK_DIR/restore.log)."
  warn "Only 'must be owner of extension ...' errors are safe to ignore."
  confirm "Continue anyway?" || fatal "aborted; new DB is partially restored, drop and recreate it before retrying"
fi

info "5/6 Verify exact row counts"
count_sql="select table_schema||'.'||table_name, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text from information_schema.tables where table_type='BASE TABLE' and table_schema not in ('pg_catalog','information_schema') order by 1"
pg_old psql -v ON_ERROR_STOP=1 -Atc "$count_sql" > old_counts.txt
pg_new psql -v ON_ERROR_STOP=1 -Atc "$count_sql" > new_counts.txt
if ! run diff old_counts.txt new_counts.txt; then
  fatal "row counts differ; do NOT switch over"
fi
echo "row counts match ($(wc -l < old_counts.txt) tables)"

info "6/6 Repoint $SECRET_NAME ($OLD_HOST:$OLD_PORT -> $NEW_HOST:$NEW_PORT)"
if confirm "Update DSN/DATASTORE_URI keys in secret $NAMESPACE/$SECRET_NAME?"; then
  # Swap host:port only; user, password and query params (sslmode) are kept as-is.
  filter='.data |= with_entries(if (.key | test("DSN|DATASTORE_URI")) then .value |= (@base64d | split($from) | join($to) | @base64) else . end)'
  from="@$OLD_HOST:$OLD_PORT/" to="@$NEW_HOST:$NEW_PORT/"
  printf '\n$ kubectl get secret %q -n %q -o json | jq --arg from %q --arg to %q %q | kubectl replace -f -\n' \
    "$SECRET_NAME" "$NAMESPACE" "$from" "$to" "$filter" >&2
  kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o json \
    | jq --arg from "$from" --arg to "$to" "$filter" \
    | kubectl replace -f -
  echo "Resulting endpoints (credentials masked):"
  kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o json \
    | jq -r '.data | to_entries[] | select(.key | test("DSN|DATASTORE_URI")) | "  \(.key)  \(.value | @base64d | sub("//[^@]*@"; "//***@"))"'
  warn "Any line still on $OLD_HOST:$OLD_PORT used a different format; fix it by hand."
else
  warn "Secret not changed; update it before re-enabling OpenObserve."
fi

unset PGPASSWORD
cat <<EOF

Done. Next:
  1. Push openobserve.enabled=true and verify dashboards/alerts and old logs.
  2. Keep the old DB until satisfied, then: shred -u $WORK_DIR/$DUMP_FILE
EOF
