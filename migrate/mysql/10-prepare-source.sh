#!/usr/bin/env bash
# Preflight checks on the legacy MySQL. Read-only.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source lib.sh

[[ $(legacy_sql "SELECT @@gtid_mode") == ON ]] || die "gtid_mode is not ON (RDS parameter group: gtid-mode, enforce_gtid_consistency)"
[[ $(legacy_sql "SELECT @@binlog_format") == ROW ]] || die "binlog_format is not ROW"
[[ $(legacy_sql "SELECT @@binlog_row_image") == FULL ]] || die "binlog_row_image is not FULL"

# The clone into MOCO copies InnoDB only.
other=$(legacy_sql "SELECT GROUP_CONCAT(table_name) FROM information_schema.tables WHERE table_schema = '$SCHEMA' AND table_type = 'BASE TABLE' AND engine <> 'InnoDB'")
[[ "$other" == NULL ]] || die "non-InnoDB tables: $other"

# Row-based replication of a table without a primary key scans the whole
# table for every changed row on the replica.
nopk=$(legacy_sql "SELECT GROUP_CONCAT(t.table_name) FROM information_schema.tables t
  WHERE t.table_schema = '$SCHEMA' AND t.table_type = 'BASE TABLE' AND NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints c
    WHERE c.table_schema = t.table_schema AND c.table_name = t.table_name AND c.constraint_type = 'PRIMARY KEY')")
[[ "$nopk" == NULL ]] || die "tables without a primary key: $nopk"

# The relay must be able to reconnect after an outage: keep the binlog.
retention=$(legacy_sql "SELECT @@binlog_expire_logs_seconds")
(( retention >= 86400 )) || die "binlog retention ${retention}s < 24h (RDS: CALL mysql.rds_set_configuration('binlog retention hours', 24))"

log "source ready: $(legacy_sql "SELECT ROUND(SUM(data_length + index_length) / 1048576) FROM information_schema.tables WHERE table_schema = '$SCHEMA'") MB in $SCHEMA, GTID mode on"
