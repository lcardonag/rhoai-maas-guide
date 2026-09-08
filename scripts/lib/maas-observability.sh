#!/usr/bin/env bash
# Shared helpers for Phase 7 gateway telemetry (required by Lago/OpenMeter usage-reporter).
set -euo pipefail

# True when Kuadrant TelemetryPolicy labels gateway metrics with subscription/user/model.
maas_gateway_telemetry_ready() {
  oc get telemetrypolicy maas-telemetry -n openshift-ingress &>/dev/null
}

# Human-readable detail for preflight / verify output.
maas_gateway_telemetry_status() {
  if maas_gateway_telemetry_ready; then
    echo "ready"
  else
    echo "not installed"
  fi
}
