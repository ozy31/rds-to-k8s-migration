#!/usr/bin/env bash
# Point-in-time restore drill: proves the backups restore to an exact,
# known state, without stopping the application.
#
# Inside one transaction the application tables are locked in SHARE mode
# (writes wait, reads continue), their checksums are taken and a named
# restore point is written. A throwaway cluster is then recovered from the
# object store up to that restore point and must have the same checksums.
set -euo pipefail
cd "$(dirname "$0")"
source lib.sh

RESTORE=${RESTORE:-orders-db-drill}
point="drill-$(date -u +%Y%m%d%H%M%S)"
tables=$(app_tables)

# A named restore point needs an explicit base backup taken before it.
backup_id=$(latest_backup_id)
if [[ -z "$backup_id" ]]; then
  take_backup "orders-db-drill-base-$(date -u +%Y%m%d%H%M%S)"
  backup_id=$(latest_backup_id)
fi

expected=$(target_sql "BEGIN; LOCK TABLE $tables IN SHARE MODE; $(checksum_sql) SELECT 'restore_point', pg_create_restore_point('$point'), ''; COMMIT;" | grep -v '^restore_point')
target_sql "SELECT pg_switch_wal()" >/dev/null
log "restore point $point written; writes were held only while checksumming"

t0=$(now_ms)
kubectl -n orders delete cluster "$RESTORE" --ignore-not-found --wait=true >/dev/null
kubectl apply -f - >/dev/null <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $RESTORE
  namespace: orders
spec:
  instances: 1
  imageName: $(kubectl -n orders get cluster "$TARGET_CLUSTER" -o jsonpath='{.spec.imageName}')
  storage:
    size: 2Gi
  bootstrap:
    recovery:
      source: origin
      database: orders
      owner: orders_owner
      recoveryTarget:
        backupID: "$backup_id"
        targetName: "$point"
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: orders-backups
          serverName: $(kubectl -n orders get cluster "$TARGET_CLUSTER" -o jsonpath='{.spec.plugins[0].parameters.serverName}')
YAML
kubectl -n orders wait "cluster/$RESTORE" --for=condition=Ready --timeout=10m >/dev/null
t1=$(now_ms)

actual=$(kubectl -n orders exec -i "$RESTORE-1" -c postgres -- psql -d orders -qAtX <<<"$(checksum_sql)")
if [[ "$actual" != "$expected" ]]; then
  diff <(echo "$expected") <(echo "$actual") >&2 || true
  die "restored data does not match the restore point"
fi
log "restored $RESTORE to $point in $(( t1 - t0 )) ms; checksums match"
[[ "${KEEP:-0}" == 1 ]] || kubectl -n orders delete cluster "$RESTORE" --wait=false >/dev/null
printf '{"restore_point": "%s", "restore_ms": %d}\n' "$point" $(( t1 - t0 ))
