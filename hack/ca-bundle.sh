#!/usr/bin/env bash
# CA bundle for the application: legacy CA + the CA of every target cluster
# that exists yet. Run again after a target cluster is created.
set -euo pipefail
bundle=$(kubectl -n legacy get secret legacy-ca -o 'jsonpath={.data.ca\.crt}' | base64 -d)
if kubectl -n orders get secret orders-db-ca >/dev/null 2>&1; then
  bundle+=$'\n'$(kubectl -n orders get secret orders-db-ca -o 'jsonpath={.data.ca\.crt}' | base64 -d)
fi
kubectl -n app create configmap db-ca-bundle --from-literal=bundle.crt="$bundle" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
