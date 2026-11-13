#!/usr/bin/env bash
# Preflight checks on the legacy instance, then the publication that the
# target subscribes to. Safe to run again.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source lib.sh

[[ $(legacy_sql "SHOW wal_level") == logical ]] || die "wal_level is not logical (on RDS: rds.logical_replication = 1)"

# Logical replication applies UPDATE and DELETE by replica identity. A table
# without a primary key would replicate inserts and then silently fail on
# the first update, so stop here instead.
nopk=$(legacy_sql "
  SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ')
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind IN ('r', 'p') AND n.nspname = 'public'
    AND c.relreplident = 'd'
    AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary)")
[[ -z "$nopk" ]] || die "tables without a primary key: $nopk (add one, or set REPLICA IDENTITY FULL deliberately)"

# Large objects and unlogged tables are not replicated at all.
lo=$(legacy_sql "SELECT count(*) FROM pg_largeobject_metadata")
[[ "$lo" == 0 ]] || die "$lo large objects: logical replication does not carry them"
unlogged=$(legacy_sql "SELECT string_agg(relname, ', ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND relpersistence = 'u'")
[[ -z "$unlogged" ]] || die "unlogged tables are not replicated: $unlogged"

tables=$(app_tables)
if [[ $(legacy_sql "SELECT count(*) FROM pg_publication WHERE pubname = '$PUBLICATION'") == 0 ]]; then
  legacy_sql "CREATE PUBLICATION $PUBLICATION FOR TABLE $tables"
  log "publication $PUBLICATION created for: $tables"
else
  legacy_sql "ALTER PUBLICATION $PUBLICATION SET TABLE $tables"
  log "publication $PUBLICATION covers: $tables"
fi
log "source ready: $(legacy_sql "SELECT pg_size_pretty(pg_database_size('orders'))") to copy"
