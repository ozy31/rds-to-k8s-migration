#!/usr/bin/env bash
# After the soak period: stop the reverse replication (this ends the
# rollback option), remove the publications, and take a first full backup
# of orders-db. The legacy instance stays read-only for the application
# until it is snapshotted and deleted.
set -euo pipefail
cd "$(dirname "$0")"
source lib.sh

legacy_sql "DROP SUBSCRIPTION IF EXISTS $REVERSE_SUBSCRIPTION" >/dev/null
target_sql "DROP PUBLICATION IF EXISTS $REVERSE_PUBLICATION"
legacy_sql "DROP PUBLICATION IF EXISTS $PUBLICATION"
log "replication between legacy and orders-db removed"

name="orders-db-after-cutover-$(date -u +%Y%m%d%H%M%S)"
take_backup "$name"
log "backup $name completed"
