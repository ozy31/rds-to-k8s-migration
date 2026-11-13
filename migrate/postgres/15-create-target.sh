#!/usr/bin/env bash
# Creates orders-db (schema imported from legacy) and starts the forward
# subscription. ATTEMPT numbers the backup archive: after a rollback the old
# target is deleted and the next attempt archives to a fresh path.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=/dev/null
source lib.sh
ATTEMPT=${ATTEMPT:-1}

kubectl apply -f ../../target/postgres/objectstore.yaml >/dev/null
sed "s/serverName: orders-db-attempt-1/serverName: orders-db-attempt-$ATTEMPT/" ../../target/postgres/cluster.yaml | kubectl apply -f - >/dev/null
kubectl -n orders wait "cluster/$TARGET_CLUSTER" --for=condition=Ready --timeout=10m >/dev/null
log "orders-db ready (backup archive orders-db-attempt-$ATTEMPT)"
../../hack/ca-bundle.sh
kubectl apply -f ../../target/postgres/subscription.yaml >/dev/null
log "subscription $SUBSCRIPTION created; initial copy running (see 20-status.sh)"
