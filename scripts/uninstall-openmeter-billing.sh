#!/usr/bin/env bash
# Remove Phase 12 OpenMeter billing (maas-billing + OpenMeter Helm) so Lago can be installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_DIR="$SCRIPT_DIR/.."
MANIFESTS_DIR="$GUIDE_DIR/manifests"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: uninstall-openmeter-billing.sh [--dry-run]

Removes Phase 12 OpenMeter billing from the cluster:
  - usage-reporter, budget-enforcer, maas-billing-api (12-openmeter manifests)
  - maas-billing base (namespace, tier templates, RBAC)
  - OpenMeter Helm release and openmeter namespace

Then install Lago:

  ./scripts/setup-maas.sh --from-phase 11 --with-lago-billing
EOF
      exit 0
      ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

run() {
  if $DRY_RUN; then
    echo "[DRY RUN] $*"
  else
    "$@"
  fi
}

if ! oc whoami &>/dev/null; then
  err "oc not logged in"
  exit 1
fi

echo "==> Removing OpenMeter billing stack"
for component in usage-reporter budget-enforcer maas-billing-api; do
  if [ -f "$MANIFESTS_DIR/12-openmeter/${component}/kustomization.yaml" ]; then
    run oc delete -k "$MANIFESTS_DIR/12-openmeter/${component}/" --ignore-not-found --wait=false
    ok "Deleted ${component} manifests"
  fi
done

if [ -f "$MANIFESTS_DIR/12-openmeter/base/kustomization.yaml" ]; then
  run oc delete -k "$MANIFESTS_DIR/12-openmeter/base/" --ignore-not-found --wait=false
  ok "Deleted maas-billing base (12-openmeter)"
fi

if oc get ns openmeter &>/dev/null; then
  if helm list -n openmeter 2>/dev/null | grep -q openmeter; then
    run helm uninstall openmeter -n openmeter || warn "helm uninstall openmeter failed"
    ok "Helm release openmeter removed"
  fi
  run oc delete project openmeter --ignore-not-found --wait=false
  ok "Namespace openmeter deleted"
else
  warn "Namespace openmeter not found (already removed?)"
fi

if oc get ns maas-billing &>/dev/null; then
  warn "Namespace maas-billing may still exist if other resources remain"
  warn "  oc get all -n maas-billing"
fi

echo
ok "OpenMeter billing removed. Install Lago:"
echo "  ./scripts/setup-maas.sh --from-phase 11 --with-lago-billing"
