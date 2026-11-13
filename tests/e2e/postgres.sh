#!/usr/bin/env bash
# The whole PostgreSQL migration under continuous writes:
#   copy -> cutover -> writes on orders-db -> rollback -> start over ->
#   cutover -> finalize -> point-in-time restore drill
# Fails if any acknowledged write is missing on the side that ends up
# serving the application, or if write downtime exceeds MAX_GAP_MS.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=/dev/null
source tests/e2e/lib.sh
# shellcheck source=/dev/null
source migrate/postgres/lib.sh
MAX_GAP_MS=${MAX_GAP_MS:-15000}
OUT=${OUT:-out}; mkdir -p "$OUT"
RUN=$(date -u +%H%M%S)

reset() {
  point_app_at legacy-pg.legacy.svc.cluster.local
  unfreeze_writes legacy
  legacy_sql "DROP SUBSCRIPTION IF EXISTS $REVERSE_SUBSCRIPTION" >/dev/null
  kubectl -n orders delete subscription from-legacy --ignore-not-found --wait=true >/dev/null
  kubectl -n orders delete cluster orders-db --ignore-not-found --wait=true >/dev/null
  # Slots left behind by a deleted target would hold WAL on legacy forever.
  legacy_sql "SELECT count(pg_drop_replication_slot(slot_name)) FROM pg_replication_slots WHERE slot_name = '$SUBSCRIPTION' AND NOT active" >/dev/null
}

start_target() { # start_target <attempt>
  migrate/postgres/10-prepare-source.sh
  ATTEMPT="$1-$RUN" migrate/postgres/15-create-target.sh
  wait_until 300 bash -c "[[ \$(cd migrate/postgres && source lib.sh && target_sql \"SELECT count(*) FILTER (WHERE srsubstate <> 'r') || '/' || count(*) FROM pg_subscription_rel\") == 0/3 ]]" \
    || fail "initial copy did not finish"
  pass "orders-db created from the schema, initial copy done"
}

start_writer() {
  kubectl -n app delete pod pg-writer --ignore-not-found --wait=true >/dev/null
  kubectl apply -f app/postgres.yaml -f app/pg-writer.yaml >/dev/null
  kubectl -n app wait pod/pg-writer --for=condition=Ready --timeout=60s >/dev/null
}

check_acked() { # check_acked <side> <label>
  # Acknowledged first, then present: the other order would count writes
  # acknowledged after the snapshot of the table as missing.
  acked pg-writer >"$OUT/acked"
  "${1}_sql" "SELECT seq FROM writes" >"$OUT/present"
  local m n; m=$(missing "$OUT/acked" "$OUT/present"); n=$(wc -l <"$OUT/acked" | tr -d ' ')
  [[ "$m" == 0 ]] || fail "$2: $m of $n acknowledged writes missing on $1"
  pass "$2: all $n acknowledged writes present on $1"
}

reset
hack/target-secrets.sh
start_target 1
start_writer
sleep 20

t=$(now_ms)
cutover=$(migrate/postgres/30-cutover.sh)
sleep 20
gap=$(write_gap_ms pg-writer "$t")
check_acked target "cutover"
(( gap <= MAX_GAP_MS )) || fail "cutover: write gap ${gap} ms"
pass "cutover: longest gap between acknowledged writes ${gap} ms"
target_sql "SELECT 1 FROM orders WHERE id > (SELECT max(id) - 10 FROM orders) LIMIT 1" | grep -q 1 \
  || fail "no new orders on orders-db (sequence not copied?)"

t=$(now_ms)
rollback=$(migrate/postgres/40-rollback.sh)
sleep 15
rgap=$(write_gap_ms pg-writer "$t")
check_acked legacy "rollback"
pass "rollback: longest gap ${rgap} ms"

# A rolled-back target is stale; the retry starts again from an empty one.
reset
start_target 2
sleep 10
t=$(now_ms)
migrate/postgres/30-cutover.sh >/dev/null
sleep 15
check_acked target "second cutover"
migrate/postgres/50-finalize.sh
drill=$(migrate/postgres/60-restore-drill.sh)
pass "restore drill: $drill"

printf '{"cutover": %s, "cutover_client_gap_ms": %d, "rollback": %s, "rollback_client_gap_ms": %d, "acknowledged_writes": %d, "lost": 0, "restore_drill": %s}\n' \
  "$cutover" "$gap" "$rollback" "$rgap" "$(wc -l <"$OUT/acked" | tr -d ' ')" "$drill" | tee "$OUT/postgres.json"
