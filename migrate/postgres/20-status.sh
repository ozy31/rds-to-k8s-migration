#!/usr/bin/env bash
# Where the forward replication is: per-table sync state and how far the
# target is behind the legacy instance.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source lib.sh

target_sql "SELECT format('%-12s %s', srrelid::regclass, CASE srsubstate WHEN 'r' THEN 'ready' WHEN 'd' THEN 'copying' WHEN 's' THEN 'synchronized' ELSE srsubstate::text END) FROM pg_subscription_rel ORDER BY 1"
legacy_sql "SELECT format('lag: %s', pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)))
            FROM pg_replication_slots WHERE slot_name = '$SUBSCRIPTION'"
