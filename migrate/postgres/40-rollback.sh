#!/usr/bin/env bash
# Rollback orders-db -> legacy after a cutover, through the reverse
# replication that 30-cutover.sh started. Mirrors the cutover: freeze the
# target, wait for legacy to apply everything, copy sequences, compare,
# unfreeze legacy, repoint the application.
set -euo pipefail
cd "$(dirname "$0")"
source lib.sh

[[ $(legacy_sql "SELECT count(*) FROM pg_subscription WHERE subname = '$REVERSE_SUBSCRIPTION'") == 1 ]] \
  || die "no reverse subscription on legacy; rollback is only possible before 50-finalize.sh"

t0=$(now_ms)
log "freezing writes on orders-db"
freeze_writes target
lsn=$(target_sql "SELECT pg_current_wal_lsn()")
wait_slot_caught_up target "$REVERSE_SUBSCRIPTION" "$lsn"
log "legacy caught up to $lsn"

legacy_sql "$(sequence_setvals target)" >/dev/null
same_data target legacy || die "checksums differ; orders-db stays frozen, investigate before writing anywhere"
log "row counts and checksums match"

legacy_sql "DROP SUBSCRIPTION $REVERSE_SUBSCRIPTION" >/dev/null
target_sql "DROP PUBLICATION IF EXISTS $REVERSE_PUBLICATION"
unfreeze_writes legacy
point_app_at legacy-pg.legacy.svc.cluster.local
t1=$(now_ms)
log "application points at legacy again ($(( t1 - t0 )) ms of frozen writes)"
printf '{"frozen_ms": %d}\n' $(( t1 - t0 ))
