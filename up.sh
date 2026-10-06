#!/usr/bin/env bash
# Creates the whole lab from scratch: kind cluster, Keycloak, Hostzero operator,
# platform chart and tenant chart. Re-runnable.
set -euo pipefail
cd "$(dirname "$0")"
OPERATOR_VERSION=${OPERATOR_VERSION:-0.13.1}

kind get clusters | grep -qx keycloak-lab || kind create cluster --config kind/cluster.yaml
kubectl config use-context kind-keycloak-lab >/dev/null

kubectl apply -f keycloak/keycloak.yaml
helm upgrade --install keycloak-operator oci://ghcr.io/hostzero-gmbh/charts/keycloak-operator \
  --version "$OPERATOR_VERSION" -n keycloak-operator --create-namespace --wait
kubectl -n keycloak rollout status deploy/keycloak --timeout=300s

helm upgrade --install keycloak-platform charts/keycloak-platform --wait
helm upgrade --install keycloak-tenants charts/keycloak-tenants --wait
kubectl wait clusterkeycloakrealm --all --for=jsonpath='{.status.ready}'=true --timeout=180s
kubectl get clusterkeycloakinstance,clusterkeycloakrealm
echo "Keycloak console: kubectl -n keycloak port-forward svc/keycloak 8080  ->  http://localhost:8080 (admin/admin)"
