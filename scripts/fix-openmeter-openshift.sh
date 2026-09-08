#!/usr/bin/env bash
#
# Re-apply OpenShift-specific OpenMeter fixes after Helm upgrade or API CrashLoopBackOff.
# Safe to run any time — idempotent.
#
# Fixes:
#   1. postgres url ?sslmode=disable (chart merge drops this on helm upgrade)
#   2. openmeter-api listens on 8080 instead of privileged port 80
#   3. Route openmeter.<cluster-domain> → openmeter-api (if missing)
#
# Usage:
#   ./scripts/fix-openmeter-openshift.sh
#   ./scripts/fix-openmeter-openshift.sh --no-restart   # patch only
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/openmeter-openshift.sh
source "$SCRIPT_DIR/lib/openmeter-openshift.sh"

RESTART=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restart) RESTART=false; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! oc whoami &>/dev/null; then
  echo "ERROR: oc login required" >&2
  exit 1
fi

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)}"

openmeter_apply_openshift_fixes "$RESTART"
openmeter_expose_route "$CLUSTER_DOMAIN"
openmeter_verify_api_ready
