#!/usr/bin/env bash
# Loads the relay from legacy and starts GTID replication legacy -> relay.
#
# mysqldump --single-transaction gives a consistent snapshot without the
# global read lock RDS does not allow, and --set-gtid-purged=ON records the
# GTID set it contains, so replication starts exactly after it.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source lib.sh

if [[ $(relay_sql "SELECT COUNT(*) FROM performance_schema.replication_connection_configuration") != 0 ]]; then
  die "the relay already replicates; delete it (kubectl -n $TARGET_NS delete sts,pvc ...) to start over"
fi

# The image's init scripts wrote a few transactions of the relay's own.
# Nothing downstream may depend on them (RDS could not fetch them during a
# rollback), so the relay starts from an empty GTID history.
relay_sql "RESET BINARY LOGS AND GTIDS; SET GLOBAL super_read_only = OFF"

t0=$(now_ms)
kubectl -n "$TARGET_NS" exec "$RELAY_POD" -- bash -c '
  set -o pipefail
  MYSQL_PWD=$LEGACY_ADMIN_PASSWORD mysqldump -h legacy-mysql.legacy.svc.cluster.local -u admin \
    --ssl-mode=VERIFY_IDENTITY --ssl-ca=/legacy-ca/ca.crt \
    --single-transaction --set-gtid-purged=ON --routines --triggers --events \
    --databases appointments |
  MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot'
log "relay loaded in $(( $(now_ms) - t0 )) ms, GTIDs: $(gtid_executed relay)"

relay_sql "SET GLOBAL super_read_only = ON"
kubectl -n "$TARGET_NS" exec "$RELAY_POD" -- bash -c '
  MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot -e "
    CHANGE REPLICATION SOURCE TO
      SOURCE_HOST = '"'"'legacy-mysql.legacy.svc.cluster.local'"'"', SOURCE_PORT = 3306,
      SOURCE_USER = '"'"'repl'"'"', SOURCE_PASSWORD = '"'"'$LEGACY_REPL_PASSWORD'"'"',
      SOURCE_AUTO_POSITION = 1,
      SOURCE_SSL = 1, SOURCE_SSL_CA = '"'"'/legacy-ca/ca.crt'"'"', SOURCE_SSL_VERIFY_SERVER_CERT = 1;
    START REPLICA;"'
sleep 2
state=$(relay_sql "SELECT CONCAT(c.service_state, '/', a.service_state) FROM performance_schema.replication_connection_status c JOIN performance_schema.replication_applier_status a USING (channel_name)")
[[ "$state" == ON/ON ]] || die "relay replication is $state: $(relay_sql "SELECT last_error_message FROM performance_schema.replication_connection_status")"
log "legacy -> relay replication running"
