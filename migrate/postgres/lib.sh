# Shared helpers for the PostgreSQL migration steps. Every statement against
# the legacy instance runs as master (the RDS master user), never as a
# superuser. Sourced, not executed.
# shellcheck shell=bash
set -euo pipefail

LEGACY_POD=${LEGACY_POD:-legacy-pg-0}
TARGET_CLUSTER=${TARGET_CLUSTER:-orders-db}
PUBLICATION=to_k8s
SUBSCRIPTION=from_legacy
REVERSE_PUBLICATION=to_legacy
REVERSE_SUBSCRIPTION=from_k8s

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# legacy_sql <sql>: run as master over TLS, as a remote client would.
legacy_sql() {
  kubectl -n legacy exec -i "$LEGACY_POD" -- bash -c \
    'PGPASSWORD=$MASTER_PASSWORD psql "host=legacy-pg.legacy.svc.cluster.local dbname=orders user=master sslmode=verify-full sslrootcert=/tls/ca.crt" -v ON_ERROR_STOP=1 -qAtX' <<<"$1"
}

target_primary() {
  kubectl -n orders get cluster "$TARGET_CLUSTER" -o jsonpath='{.status.currentPrimary}'
}

# target_sql <sql>: run on the target primary through the operator's local
# socket (the superuser on our own platform; the application never gets it).
target_sql() {
  kubectl -n orders exec -i "$(target_primary)" -c postgres -- psql -d orders -v ON_ERROR_STOP=1 -qAtX <<<"$1"
}

# Tables in the public schema, in the format CREATE PUBLICATION expects.
app_tables() {
  legacy_sql "SELECT string_agg(format('%I.%I', schemaname, tablename), ', ' ORDER BY tablename)
              FROM pg_tables WHERE schemaname = 'public'"
}

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# wait_slot_caught_up <side:legacy|target> <slot> <lsn> [timeout s]
# Waits until the subscriber has confirmed everything up to <lsn>.
wait_slot_caught_up() {
  local side=$1 slot=$2 lsn=$3 timeout=${4:-60} q
  q="SELECT coalesce(confirmed_flush_lsn >= '$lsn', false) FROM pg_replication_slots WHERE slot_name = '$slot'"
  for ((i = 0; i < timeout * 4; i++)); do
    [[ $("${side}_sql" "$q") == t ]] && return 0
    sleep 0.25
  done
  die "slot $slot on $side did not reach $lsn within ${timeout}s"
}

# checksums <side>: one line per table, "table count md5", in a stable order
# and a fixed time zone so both sides render rows identically.
checksums() {
  local side=$1 t sql=""
  for t in $(legacy_sql "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1"); do
    sql+="SELECT '$t', count(*), md5(coalesce(string_agg(x::text, '|' ORDER BY x::text COLLATE \"C\"), '')) FROM public.$t x;"
  done
  "${side}_sql" "SET TimeZone = 'UTC'; SET DateStyle = 'ISO, MDY'; SET extra_float_digits = 1; $sql"
}

# sequence_setvals <side>: SQL that sets every sequence on the other side to
# this side's value. Logical replication does not carry sequences.
sequence_setvals() {
  "${1}_sql" "SELECT format('SELECT setval(%L, %s, true);', format('%I.%I', schemaname, sequencename), last_value)
              FROM pg_sequences WHERE schemaname = 'public' AND last_value IS NOT NULL"
}

# freeze_writes <side>: the application role can still log in and read, but
# every write fails; open sessions are ended so nothing in flight commits
# afterwards.
freeze_writes() {
  "${1}_sql" "REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public FROM app;
              SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE usename = 'app';" >/dev/null
}
unfreeze_writes() {
  "${1}_sql" "GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app" >/dev/null
}

point_app_at() { # point_app_at <host>
  kubectl -n app patch service orders-db --type=merge -p "{\"spec\":{\"externalName\":\"$1\"}}" >/dev/null
}

# same_data <a> <b>: true when both sides return the same, non-empty
# checksums. Captured first, so a failing query cannot look like a match.
same_data() {
  local a b
  a=$(checksums "$1") && b=$(checksums "$2") || return 1
  [[ -n "$a" ]] || return 1
  if [[ "$a" != "$b" ]]; then diff <(echo "$a") <(echo "$b") >&2 || true; return 1; fi
}
