#!/usr/bin/env bash
# Install Lago billing platform via official Helm chart (Phase 11a).
# Namespace: lago. Idempotent (helm upgrade --install).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALUES_TEMPLATE="${GUIDE_DIR}/manifests/11-lago/lago/values-openshift.yaml"
NS="${LAGO_NAMESPACE:-lago}"
RELEASE="${LAGO_HELM_RELEASE:-lago}"

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)}"
if [[ -z "$CLUSTER_DOMAIN" ]]; then
  echo "ERROR: cannot detect cluster domain (oc login required)" >&2
  exit 1
fi

echo "==> Lago platform (Helm)"
echo "    cluster domain: ${CLUSTER_DOMAIN}"
echo "    namespace:      ${NS}"
echo "    release:        ${RELEASE}"

if ! command -v helm &>/dev/null; then
  echo "ERROR: helm not found on PATH" >&2
  exit 1
fi

if ! oc get project "$NS" &>/dev/null; then
  oc new-project "$NS" \
    --display-name="Lago" \
    --description="Lago metering and billing (Phase 11)" >/dev/null
else
  oc project "$NS" >/dev/null
fi

helm repo add lago https://charts.getlago.com 2>/dev/null || true
helm repo update lago

VALUES_RENDERED="$(mktemp)"
export CLUSTER_DOMAIN
envsubst '${CLUSTER_DOMAIN}' < "$VALUES_TEMPLATE" > "$VALUES_RENDERED"

HELM_ARGS=(
  upgrade --install "$RELEASE" lago/lago
  -n "$NS"
  -f "$VALUES_RENDERED"
  --wait
  --timeout 20m
)

if [[ -n "${LAGO_DATABASE_URL:-}" ]]; then
  HELM_ARGS+=(--set "global.databaseUrl=${LAGO_DATABASE_URL}")
fi
if [[ -n "${LAGO_REDIS_URL:-}" ]]; then
  HELM_ARGS+=(--set "global.redisUrl=${LAGO_REDIS_URL}")
fi
if [[ -n "${LAGO_LICENSE:-}" ]]; then
  HELM_ARGS+=(--set "global.license=${LAGO_LICENSE}")
fi

echo "==> helm ${HELM_ARGS[*]}"
helm "${HELM_ARGS[@]}"

rm -f "$VALUES_RENDERED"

# Expose API + UI on OpenShift Routes when chart ingress is disabled.
expose_route() {
  local svc="$1" host="$2"
  if oc get route "$svc" -n "$NS" &>/dev/null; then
    echo "    route ${svc} exists"
    return 0
  fi
  if ! oc get svc "$svc" -n "$NS" &>/dev/null; then
    echo "    WARN: Service ${svc} not found — skip route"
    return 0
  fi
  oc expose svc/"$svc" -n "$NS" --name="$svc" --hostname="$host" 2>/dev/null || \
    oc create route edge "$svc" -n "$NS" --service="$svc" --hostname="$host" || true
  echo "    route https://${host}"
}

expose_route "lago-api" "lago-api.${CLUSTER_DOMAIN}"
expose_route "lago-front" "lago.${CLUSTER_DOMAIN}"

echo "==> Lago routes"
oc get route -n "$NS" 2>/dev/null || true
