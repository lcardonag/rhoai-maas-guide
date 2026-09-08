#!/usr/bin/env bash
# Detect installed MaaS billing backend (Lago vs OpenMeter) and block cross-install.
set -euo pipefail

maas_billing_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Echoes: lago | openmeter | none | conflict (both platform namespaces present)
maas_billing_backend_detected() {
  local from_cm=""
  if oc get configmap maas-billing-config -n maas-billing &>/dev/null; then
    from_cm="$(oc get configmap maas-billing-config -n maas-billing \
      -o jsonpath='{.data.BILLING_BACKEND}' 2>/dev/null || true)"
    from_cm="$(maas_billing_lower "$from_cm")"
  fi
  if [[ -n "$from_cm" ]]; then
    echo "$from_cm"
    return 0
  fi

  local has_lago=false has_openmeter=false
  oc get ns lago &>/dev/null && has_lago=true
  oc get ns openmeter &>/dev/null && has_openmeter=true

  if $has_lago && $has_openmeter; then
    echo "conflict"
    return 0
  fi
  if $has_lago; then
    echo "lago"
    return 0
  fi
  if $has_openmeter; then
    echo "openmeter"
    return 0
  fi
  echo "none"
}

# Exit 1 when another billing backend is already installed. Same-backend re-runs are allowed.
maas_billing_require_backend() {
  local requested
  requested="$(maas_billing_lower "$1")"
  local detected
  detected="$(maas_billing_backend_detected)"

  case "$requested" in
    lago|openmeter) ;;
    *)
      echo "maas_billing_require_backend: invalid backend '$requested'" >&2
      return 2
      ;;
  esac

  if [[ "$detected" == "none" || "$detected" == "$requested" ]]; then
    return 0
  fi

  maas_billing_conflict_message "$detected" "$requested" >&2
  return 1
}

maas_billing_conflict_message() {
  local installed requested
  installed="$(maas_billing_lower "$1")"
  requested="$(maas_billing_lower "$2")"
  local guide_dir="${GUIDE_DIR:-.}"

  cat <<EOF
ERROR: Cannot install ${requested} billing — ${installed} is already present on this cluster.

Only one billing backend may run at a time (shared namespace maas-billing).

Remove the existing stack, then re-run Phase $(
    if [[ "$requested" == "lago" ]]; then echo 11; else echo 12; fi
  ):

EOF

  if [[ "$installed" == "lago" || "$installed" == "conflict" ]]; then
    cat <<EOF
  # Lago + maas-billing (Phase 11)
  oc delete -k "${guide_dir}/manifests/11-lago/usage-reporter/" --ignore-not-found
  oc delete -k "${guide_dir}/manifests/11-lago/budget-enforcer/" --ignore-not-found
  oc delete -k "${guide_dir}/manifests/11-lago/maas-billing-api/" --ignore-not-found
  oc delete -k "${guide_dir}/manifests/11-lago/base/" --ignore-not-found
  helm uninstall lago -n lago 2>/dev/null || true
  oc delete project lago --ignore-not-found

EOF
  fi

  if [[ "$installed" == "openmeter" || "$installed" == "conflict" ]]; then
    cat <<EOF
  # OpenMeter + maas-billing (Phase 12)
  ./scripts/uninstall-openmeter-billing.sh
  # or manually:
  oc delete -k "${guide_dir}/manifests/12-openmeter/usage-reporter/" --ignore-not-found
  oc delete -k "${guide_dir}/manifests/12-openmeter/budget-enforcer/" --ignore-not-found
  oc delete -k "${guide_dir}/manifests/12-openmeter/maas-billing-api/" --ignore-not-found
  oc delete -k "${guide_dir}/manifests/12-openmeter/base/" --ignore-not-found
  helm uninstall openmeter -n openmeter 2>/dev/null || true
  oc delete project openmeter --ignore-not-found

EOF
  fi

  if [[ "$installed" == "conflict" ]]; then
    echo "  # Both platform namespaces were found — remove maas-billing last if it remains:"
    echo "  oc delete project maas-billing --ignore-not-found"
    echo
  fi

  cat <<EOF
Then install ${requested}:

  ./scripts/setup-maas.sh --from-phase $(
    if [[ "$requested" == "lago" ]]; then echo 11; else echo 12; fi
  ) --with-${requested}-billing
EOF
}
