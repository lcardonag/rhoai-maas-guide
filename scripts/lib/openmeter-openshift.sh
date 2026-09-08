#!/usr/bin/env bash
# OpenShift post-Helm fixes for OpenMeter (embedded Postgres SSL + non-privileged API port).
# Source from install-openmeter-platform.sh / fix-openmeter-openshift.sh — do not execute directly.
set -euo pipefail

OPENMETER_NS="${OPENMETER_NAMESPACE:-openmeter}"
OPENMETER_RELEASE="${OPENMETER_HELM_RELEASE:-openmeter}"
OPENMETER_API_PORT="${OPENMETER_API_PORT:-8080}"

# Chart merge overwrites config.postgres.url without sslmode=disable on every helm upgrade.
fix_openmeter_postgres_ssl() {
  echo "==> OpenMeter: postgres url sslmode=disable (embedded Bitnami Postgres has no TLS)"
  if ! oc get configmap "$OPENMETER_RELEASE" -n "$OPENMETER_NS" &>/dev/null; then
    echo "    WARN: ConfigMap/${OPENMETER_RELEASE} not found in ${OPENMETER_NS}"
    return 0
  fi
  oc get configmap "$OPENMETER_RELEASE" -n "$OPENMETER_NS" -o json | python3 -c "
import json, re, sys
cm = json.load(sys.stdin)
text = cm['data']['config.yaml']
old = 'postgres://application:application@openmeter-postgres:5432/application'
if '?sslmode=' not in text and old in text:
    text = text.replace(old, old + '?sslmode=disable', 1)
    cm['data']['config.yaml'] = text
json.dump(cm, sys.stdout)
" | oc apply -f -
}

# Chart hardcodes --address 0.0.0.0:80; non-root OpenShift pods cannot bind port 80.
fix_openmeter_openshift_ports() {
  echo "==> OpenMeter: move openmeter-api to port ${OPENMETER_API_PORT} (non-privileged)"
  if ! oc get deployment/openmeter-api -n "$OPENMETER_NS" &>/dev/null; then
    echo "    WARN: deployment/openmeter-api not found"
    return 0
  fi
  local current_port
  current_port="$(oc get deployment/openmeter-api -n "$OPENMETER_NS" \
    -o jsonpath='{.spec.template.spec.containers[0].ports[0].containerPort}' 2>/dev/null || true)"
  if [[ "$current_port" == "$OPENMETER_API_PORT" ]]; then
    echo "    openmeter-api already on port ${OPENMETER_API_PORT}"
  else
    oc patch deployment/openmeter-api -n "$OPENMETER_NS" --type=json -p="[
      {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[\"--address\",\"0.0.0.0:${OPENMETER_API_PORT}\",\"--telemetry-address\",\"0.0.0.0:10000\",\"--config\",\"/etc/openmeter/config.yaml\"]},
      {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/ports/0/containerPort\",\"value\":${OPENMETER_API_PORT}}
    ]"
  fi
  if oc get svc openmeter-api -n "$OPENMETER_NS" &>/dev/null; then
    oc patch svc openmeter-api -n "$OPENMETER_NS" --type=json -p="[
      {\"op\":\"replace\",\"path\":\"/spec/ports/0/targetPort\",\"value\":${OPENMETER_API_PORT}}
    ]" 2>/dev/null || true
  fi
}

openmeter_expose_route() {
  local cluster_domain="${1:-}"
  local svc="openmeter-api"
  local host="openmeter.${cluster_domain}"

  [[ -n "$cluster_domain" ]] || return 0
  if ! oc get svc "$svc" -n "$OPENMETER_NS" &>/dev/null; then
    echo "    WARN: Service ${svc} not found — skip route"
    return 0
  fi

  # Edge TLS termination is required: a plain exposed route serves HTTP only and
  # https:// returns 503 from the OpenShift router while the API listens on HTTP:8080.
  oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${svc}
  namespace: ${OPENMETER_NS}
  labels:
    app.kubernetes.io/part-of: openmeter
spec:
  host: ${host}
  to:
    kind: Service
    name: ${svc}
  port:
    targetPort: http
  tls:
    termination: edge
EOF
  echo "    route https://${host} (edge TLS)"
}

# Re-apply OpenShift fixes and roll workloads that read config.yaml or talk to Postgres.
openmeter_apply_openshift_fixes() {
  local restart="${1:-true}"
  fix_openmeter_postgres_ssl
  fix_openmeter_openshift_ports

  if [[ "$restart" != true ]]; then
    return 0
  fi

  local dep
  for dep in openmeter-api openmeter-sink-worker openmeter-balance-worker \
             openmeter-billing-worker openmeter-notification-service; do
    if oc get deployment/"$dep" -n "$OPENMETER_NS" &>/dev/null; then
      oc rollout restart "deployment/${dep}" -n "$OPENMETER_NS" >/dev/null
    fi
  done

  if oc get deployment/openmeter-api -n "$OPENMETER_NS" &>/dev/null; then
    oc rollout status deployment/openmeter-api -n "$OPENMETER_NS" --timeout=10m
  fi
}

openmeter_verify_api_ready() {
  local ready
  ready="$(oc get deployment/openmeter-api -n "$OPENMETER_NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")"
  if [[ "${ready:-0}" -ge 1 ]]; then
    echo "[OK] openmeter-api ready (${ready} replica(s))"
    return 0
  fi
  echo "[FAIL] openmeter-api not ready — recent logs:" >&2
  oc logs deployment/openmeter-api -n "$OPENMETER_NS" --tail=15 2>&1 || true
  return 1
}
