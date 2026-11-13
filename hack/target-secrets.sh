#!/usr/bin/env bash
# Hands the target namespaces what they need from the legacy side: the CA
# that signed the legacy server certificates, and the credentials of the
# replication and application roles. Values go from Secret to Secret and are
# never printed.
set -euo pipefail
cd "$(dirname "$0")/.."

get() { kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" | base64 -d; }
put() { # put <ns> <name> <type> key=value...
  local ns=$1 name=$2 type=$3; shift 3
  local args=(); for kv in "$@"; do args+=("--from-literal=$kv"); done
  kubectl -n "$ns" create secret generic "$name" --type="$type" "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

ca=$(get legacy legacy-ca 'ca\.crt')
for ns in orders appointments app; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  put "$ns" legacy-ca Opaque "ca.crt=$ca"
done

# PostgreSQL: forward replication logs in to legacy as migrator; the
# application keeps its password across the cutover; the reverse
# (rollback) replication logs in to orders-db as migrator.
put orders legacy-pg-migrator Opaque "password=$(get legacy legacy-pg-credentials MIGRATOR_PASSWORD)"
put orders orders-db-app-user kubernetes.io/basic-auth username=app "password=$(get legacy legacy-pg-credentials APP_PASSWORD)"
kubectl -n orders get secret orders-db-migrator-user >/dev/null 2>&1 ||
  put orders orders-db-migrator-user kubernetes.io/basic-auth username=migrator "password=$(openssl rand -hex 16)"

# The application trusts both CAs during the migration: the legacy one and
# the one CNPG generated for orders-db.
put app orders-db-app-user kubernetes.io/basic-auth username=app "password=$(get legacy legacy-pg-credentials APP_PASSWORD)"

# MySQL: the relay loads and replicates from legacy as admin / repl; the
# application keeps its password; MOCO clones the relay with the donor
# accounts created on it.
put appointments legacy-mysql-admin Opaque \
  "ADMIN_PASSWORD=$(get legacy legacy-mysql-credentials ADMIN_PASSWORD)" \
  "REPL_PASSWORD=$(get legacy legacy-mysql-credentials REPL_PASSWORD)"
for ns in appointments app; do
  put "$ns" appointments-app-user kubernetes.io/basic-auth username=app "password=$(get legacy legacy-mysql-credentials APP_PASSWORD)"
done
hack/ensure-secret.sh appointments mysql-relay-credentials ROOT_PASSWORD CLONE_DONOR_PASSWORD CLONE_INIT_PASSWORD ROLLBACK_REPL_PASSWORD
put appointments appointments-db-donor Opaque \
  HOST=mysql-relay.appointments.svc.cluster.local PORT=3306 \
  USER=clone-donor "PASSWORD=$(get appointments mysql-relay-credentials CLONE_DONOR_PASSWORD)" \
  INIT_USER=clone-init "INIT_PASSWORD=$(get appointments mysql-relay-credentials CLONE_INIT_PASSWORD)"
# The MOCO backup job reads only AWS_* variables from its Secret.
put appointments backup-s3-env Opaque \
  "AWS_ACCESS_KEY_ID=$(get appointments backup-s3 AWS_ACCESS_KEY_ID)" \
  "AWS_SECRET_ACCESS_KEY=$(get appointments backup-s3 AWS_SECRET_ACCESS_KEY)"
