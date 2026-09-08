#!/usr/bin/env bash
# Build maas-billing image on OpenShift (ImageStream + Binary BuildConfig).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NS="${MAAS_BILLING_NAMESPACE:-maas-billing}"
SRC="${MAAS_BILLING_SRC:-$GUIDE_DIR/manifests/11-lago/maas-billing}"
BC="${MAAS_BILLING_BUILDCONFIG:-maas-billing}"

if ! oc get ns "$NS" &>/dev/null; then
  echo "ERROR: namespace $NS missing — run: oc apply -k $GUIDE_DIR/manifests/11-lago/base/" >&2
  exit 1
fi

echo "==> Ensuring ImageStream + BuildConfig in $NS"
oc apply -f "$GUIDE_DIR/manifests/11-lago/maas-billing-api/imagestream.yaml"
oc apply -f "$GUIDE_DIR/manifests/11-lago/maas-billing-api/buildconfig.yaml"

if [[ ! -d "$SRC" ]]; then
  echo "ERROR: source dir not found: $SRC" >&2
  exit 1
fi

echo "==> Starting binary build $NS/$BC from $SRC"
oc start-build "$BC" -n "$NS" --from-dir="$SRC" --wait --follow

echo "==> Image: image-registry.openshift-image-registry.svc:5000/${NS}/maas-billing:latest"
oc get istag maas-billing:latest -n "$NS" -o jsonpath='{.status.tags[0].items[0].created}' 2>/dev/null && echo
