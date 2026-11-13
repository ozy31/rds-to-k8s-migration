#!/usr/bin/env bash
# Platform layer for the target side: cert-manager, the CloudNativePG operator
# with the Barman Cloud plugin, the MOCO MySQL operator, and a local S3 for
# backups. Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=versions.env
source versions.env

helm_install() {
  local release=$1 chart=$2 version=$3 namespace=$4 values=$5
  helm upgrade --install "$release" "$chart" --version "$version" \
    --namespace "$namespace" --create-namespace --values "$values" \
    --wait --timeout 5m >/dev/null
  echo "installed $release $version"
}

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo add cnpg https://cloudnative-pg.github.io/charts --force-update >/dev/null
helm repo add moco https://cybozu-go.github.io/moco/ --force-update >/dev/null

helm_install cert-manager jetstack/cert-manager "$CERT_MANAGER_CHART_VERSION" cert-manager platform/values/cert-manager.yaml
helm_install cnpg cnpg/cloudnative-pg "$CNPG_CHART_VERSION" cnpg-system platform/values/cloudnative-pg.yaml
# The plugin must run in the operator's namespace (mTLS via cert-manager).
helm_install barman-cloud cnpg/plugin-barman-cloud "$BARMAN_CLOUD_CHART_VERSION" cnpg-system platform/values/plugin-barman-cloud.yaml
helm_install moco moco/moco "$MOCO_CHART_VERSION" moco-system platform/values/moco.yaml

kubectl -n cnpg-system rollout status deployment --timeout=3m >/dev/null
kubectl -n moco-system rollout status deployment --timeout=3m >/dev/null
platform/object-store/install.sh
echo "platform ready"
