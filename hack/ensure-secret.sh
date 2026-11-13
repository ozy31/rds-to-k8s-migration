#!/usr/bin/env bash
# ensure-secret.sh <namespace> <name> <key> [<key> ...]
# Creates a Secret with a random value for every key, unless it exists.
# Nothing generated here is ever written to disk or printed.
set -euo pipefail
ns=$1 name=$2; shift 2
kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$ns" get secret "$name" >/dev/null 2>&1 && exit 0
args=()
for k in "$@"; do args+=("--from-literal=$k=$(openssl rand -hex 16)"); done
kubectl -n "$ns" create secret generic "$name" "${args[@]}" >/dev/null
