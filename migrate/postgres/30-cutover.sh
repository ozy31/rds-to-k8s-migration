#!/usr/bin/env bash
# Cutover legacy -> orders-db with a rollback path kept open.
#
#   1. check every table is in sync and the lag is small
#   2. freeze writes on legacy (revoke + end sessions)
#   3. wait until the target has applied everything legacy committed
#   4. copy sequence values, compare row counts and checksums
#   5. stop forward replication, start reverse replication (orders-db ->
#      legacy) so that rollback loses nothing
#   6. repoint the application's name to orders-db
#
# Downtime for writes is steps 2 to 6. Prints a JSON summary on stdout.
set -euo pipefail
cd "$(dirname "$0")"
source lib.sh

MAX_LAG_BYTES=${MAX_LAG_BYTES:-16777216}

notready=$(target_sql "SELECT count(*) FROM pg_subscription_rel WHERE srsubstate <> 'r'")
[[ "$notready" == 0 ]] || die "$notready tables are still copying; run 20-status.sh"
lag=$(legacy_sql "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)::bigint FROM pg_replication_slots WHERE slot_name = '$SUBSCRIPTION'")
[[ -n "$lag" ]] || die "no replication slot $SUBSCRIPTION on legacy"
(( lag <= MAX_LAG_BYTES )) || die "lag ${lag} bytes is above ${MAX_LAG_BYTES}; wait and retry"

t0=$(now_ms)
log "freezing writes on legacy"
freeze_writes legacy
lsn=$(legacy_sql "SELECT pg_current_wal_lsn()")
wait_slot_caught_up legacy "$SUBSCRIPTION" "$lsn"
t_synced=$(now_ms)
log "target caught up to $lsn"

target_sql "$(sequence_setvals legacy)" >/dev/null
if ! same_data legacy target; then
  log "checksums differ: unfreezing legacy, nothing was switched"
  unfreeze_writes legacy
  exit 1
fi
log "row counts and checksums match"

# Reverse replication. Dropping the forward subscription first prevents a
# loop; origin = none on the reverse one is a second guard.
kubectl -n orders delete subscription from-legacy --wait=true >/dev/null
tables=$(app_tables)
target_sql "DROP PUBLICATION IF EXISTS $REVERSE_PUBLICATION; CREATE PUBLICATION $REVERSE_PUBLICATION FOR TABLE $tables"
migrator_pw=$(kubectl -n orders get secret orders-db-migrator-user -o jsonpath='{.data.password}' | base64 -d)
# RDS cannot be given a custom CA file, so the RDS side verifies encryption
# but not the server name (sslmode=require); see docs/rds-differences.md.
legacy_sql "CREATE SUBSCRIPTION $REVERSE_SUBSCRIPTION
  CONNECTION 'host=orders-db-rw.orders.svc.cluster.local dbname=orders user=migrator password=$migrator_pw sslmode=require'
  PUBLICATION $REVERSE_PUBLICATION WITH (copy_data = false, origin = none)" >/dev/null
log "reverse replication orders-db -> legacy running"

point_app_at orders-db-rw.orders.svc.cluster.local
t1=$(now_ms)
log "application now points at orders-db ($(( t1 - t0 )) ms of frozen writes)"
printf '{"frozen_ms": %d, "catch_up_ms": %d, "lsn": "%s"}\n' $(( t1 - t0 )) $(( t_synced - t0 )) "$lsn"
