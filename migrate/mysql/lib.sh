# Shared helpers for the MySQL migration steps. Statements against legacy
# run as admin (the RDS master user) over verified TLS; RDS-only operations
# go through the mysql.rds_* procedures. Sourced, not executed.
# shellcheck shell=bash
set -euo pipefail

LEGACY_POD=${LEGACY_POD:-legacy-mysql-0}
RELAY_POD=${RELAY_POD:-mysql-relay-0}
TARGET_CLUSTER=${TARGET_CLUSTER:-appointments-db}
TARGET_NS=appointments
SCHEMA=appointments
PRIMARY_SVC=moco-$TARGET_CLUSTER-primary.$TARGET_NS.svc.cluster.local

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

legacy_sql() {
  kubectl -n legacy exec -i "$LEGACY_POD" -- bash -c \
    'MYSQL_PWD=$ADMIN_PASSWORD mysql -h legacy-mysql.legacy.svc.cluster.local -u admin --ssl-mode=VERIFY_IDENTITY --ssl-ca=/tls/ca.crt -NB' <<<"$1"
}

relay_sql() {
  kubectl -n "$TARGET_NS" exec -i "$RELAY_POD" -- bash -c 'MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot -NB' <<<"$1"
}

target_primary() {
  echo "moco-$TARGET_CLUSTER-$(kubectl -n "$TARGET_NS" get mysqlcluster "$TARGET_CLUSTER" -o jsonpath='{.status.currentPrimaryIndex}')"
}

# target_sql: as moco-admin on the current primary, over the local socket.
target_sql() {
  local pw
  pw=$(kubectl -n "$TARGET_NS" get secret "moco-$TARGET_CLUSTER" -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d)
  kubectl -n "$TARGET_NS" exec -i "$(target_primary)" -c mysqld -- env MYSQL_PWD="$pw" mysql -u moco-admin -NB <<<"$1"
}

gtid_executed() { "${1}_sql" "SELECT @@GLOBAL.gtid_executed" | tr -d '\n\\'; }

# wait_gtid <side> <gtid set> [timeout]: until <side> has executed the set.
wait_gtid() {
  local r
  r=$("${1}_sql" "SELECT WAIT_FOR_EXECUTED_GTID_SET('$2', ${3:-60})")
  [[ "$r" == 0 ]] || die "$1 did not reach the GTID set within ${3:-60}s"
}

tables() { legacy_sql "SELECT table_name FROM information_schema.tables WHERE table_schema = '$SCHEMA' AND table_type = 'BASE TABLE' ORDER BY 1"; }

# checksums <side>: "table count checksum" per table. CHECKSUM TABLE is
# comparable because both sides run the same version and row format.
checksums() {
  local t sql=""
  for t in $(tables); do
    sql+="SELECT '$t', (SELECT COUNT(*) FROM $SCHEMA.$t); CHECKSUM TABLE $SCHEMA.$t;"
  done
  "${1}_sql" "$sql" | paste - - | awk '{print $1, $2, $4}'
}

same_data() {
  local a b
  a=$(checksums "$1") && b=$(checksums "$2") || return 1
  [[ -n "$a" ]] || return 1
  if [[ "$a" != "$b" ]]; then diff <(echo "$a") <(echo "$b") >&2 || true; return 1; fi
}

# freeze_writes <side> / unfreeze_writes <side>: app keeps reading; writes
# fail; its open sessions are ended (mysql.rds_kill on RDS).
freeze_writes() {
  "${1}_sql" "REVOKE INSERT, UPDATE, DELETE ON $SCHEMA.* FROM 'app'@'%'" >/dev/null
  local id stmt
  for id in $("${1}_sql" "SELECT id FROM information_schema.processlist WHERE user = 'app'"); do
    if [[ $1 == legacy ]]; then stmt="CALL mysql.rds_kill($id)"; else stmt="KILL $id"; fi
    "${1}_sql" "$stmt" >/dev/null 2>&1 || true
  done
}
unfreeze_writes() {
  "${1}_sql" "GRANT SELECT, INSERT, UPDATE, DELETE ON $SCHEMA.* TO 'app'@'%'" >/dev/null
}

point_app_at() {
  kubectl -n app patch service appointments-db --type=merge -p "{\"spec\":{\"externalName\":\"$1\"}}" >/dev/null
}
