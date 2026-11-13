#!/usr/bin/env bash
# Local S3 (SeaweedFS) with one key per database namespace. Keys are generated
# here and only ever stored in the cluster.
set -euo pipefail
cd "$(dirname "$0")"

for ns in object-store orders appointments; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

if ! kubectl -n object-store get secret seaweedfs-s3-config >/dev/null 2>&1; then
  identities=""
  for ns in orders appointments; do
    key=$(openssl rand -hex 10); secret=$(openssl rand -hex 20)
    identities+=$(printf '{"name":"%s","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Read","Write","List","Tagging"]},' "$ns" "$key" "$secret")
    kubectl -n "$ns" create secret generic backup-s3 \
      --from-literal=ACCESS_KEY_ID="$key" --from-literal=ACCESS_SECRET_KEY="$secret" \
      --from-literal=AWS_ACCESS_KEY_ID="$key" --from-literal=AWS_SECRET_ACCESS_KEY="$secret" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  kubectl -n object-store create secret generic seaweedfs-s3-config \
    --from-literal=s3.json="{\"identities\":[${identities%,}]}" >/dev/null
fi

kubectl apply -f seaweedfs.yaml >/dev/null
kubectl -n object-store rollout status deployment/seaweedfs --timeout=3m >/dev/null
