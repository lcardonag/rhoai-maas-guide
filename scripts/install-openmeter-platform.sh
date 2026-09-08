#!/usr/bin/env bash
# Install OpenMeter OSS via upstream Helm chart (Phase 12a).
# Always runs OpenShift post-Helm fixes (Postgres sslmode + API port 8080).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/openmeter-openshift.sh
source "$SCRIPT_DIR/lib/openmeter-openshift.sh"

VALUES="${GUIDE_DIR}/manifests/12-openmeter/openmeter/values-openshift.yaml"
NS="${OPENMETER_NAMESPACE:-openmeter}"
RELEASE="${OPENMETER_HELM_RELEASE:-openmeter}"
# Official chart is OCI on GHCR (not a GitHub release tarball).
CHART="${OPENMETER_CHART:-oci://ghcr.io/openmeterio/helm-charts/openmeter}"
# Pin a known-good OCI tag (helm fails if --version is omitted on this chart).
VERSION="${OPENMETER_VERSION:-1.0.0-beta.232}"

export OPENMETER_NAMESPACE="$NS"
export OPENMETER_HELM_RELEASE="$RELEASE"

if ! command -v helm &>/dev/null; then
  echo "ERROR: helm not found on PATH" >&2
  exit 1
fi

if ! oc get project "$NS" &>/dev/null; then
  oc new-project "$NS" \
    --display-name="OpenMeter" \
    --description="OpenMeter metering (Phase 12)" >/dev/null
else
  oc project "$NS" >/dev/null
fi

echo "==> helm upgrade --install ${RELEASE} (namespace ${NS})"
HELM_ARGS=(
  upgrade --install "$RELEASE" "$CHART"
  -n "$NS"
  -f "$VALUES"
  --wait
  --timeout 45m
)
if [[ -n "$VERSION" ]]; then
  HELM_ARGS+=(--version "$VERSION")
fi
echo "    chart: ${CHART}  version: ${VERSION}"
if ! helm "${HELM_ARGS[@]}"; then
  echo "WARNING: helm --wait timed out or failed — applying OpenShift fixes anyway"
fi

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)}"
openmeter_apply_openshift_fixes true
openmeter_expose_route "$CLUSTER_DOMAIN"

echo "==> OpenMeter services"
oc get svc -n "$NS" 2>/dev/null | head -20

openmeter_verify_api_ready
