#!/usr/bin/env bash
#
# setup-maas.sh - End-to-end MaaS (Models as a Service) deployment on RHOAI
#
# Orchestrates the full MaaS lifecycle from a bare OpenShift cluster:
#   Phase 0: Preflight  - detect cluster state, decide which phases to run
#   Phase 1: Operators  - install required operator subscriptions
#   Phase 2: Platform config  - Kuadrant, UWM, GatewayClass, Gateway
#   Phase 3: MaaS platform  - PostgreSQL secrets/deployment, Authorino TLS
#   Phase 4: RHOAI config   - DataScienceCluster, DSCInitialization, Dashboard
#   Phase 5: Deploy model  - auto-detect GPU, apply model Kustomize
#   Phase 6: Verify  - run 6-phase E2E verification
#   Phase 7: Observability (optional)  - Tempo + OpenTelemetry + COO + Gateway telemetry
#   Phase 8: External models (optional) - deploy ExternalModel (e.g. OpenAI, Gemini)
#   Phase 9: LiteMaaS + LiteLLM (optional) - sibling repo litemaas-rhoai
#   Phase 10: Compact MaaS (optional) - thin UI/BFF, no LiteLLM (sibling compact-maas)
#   Phase 11: Lago billing (optional) - budget entities, usage-reporter, budget-enforcer
#   Phase 12: OpenMeter billing (optional) - same enforcement model, Apache metering
#
# Each phase is idempotent  - re-running skips what's already done.
#
# Usage:
#   ./scripts/setup-maas.sh [OPTIONS]
#
# Options:
#   --model <name>       Model: simulator, granite-tiny-gpu, gpt-oss-20b, auto (default: auto)
#   --from-phase <N>     Start from phase N (default: 0)
#   --skip-models        Skip Phase 5 (model deployment)
#   --skip-verify        Skip Phase 6 (verification)
#   --with-observability Also run Phase 7 (Tempo + OpenTelemetry + COO + telemetry)
#   --with-external-models Also run Phase 8 (ExternalModel deployment)
#   --with-litemaas      Also run Phase 9 (LiteMaaS + LiteLLM GUI PoC)
#   --with-compact-maas  Also run Phase 10 (Compact MaaS, no LiteLLM)
#   --with-maas-console  Deprecated alias for --with-compact-maas
#   --with-lago-billing  Also run Phase 11 (Lago + MaaS billing scaffold)
#   --skip-lago-platform Skip Helm install of Lago (use external Lago; still applies maas-billing base)
#   --with-openmeter-billing Also run Phase 12 (OpenMeter + MaaS billing scaffold)
#   --skip-openmeter-platform Skip OpenMeter Helm install (external; still applies maas-billing base)
#   --external-model-api-key <key>  API key for external provider (or EXTERNAL_MODEL_API_KEY env var)
#   --dry-run            Preview without applying
#   -h, --help           Show this help message
#
# Sibling repos (override with env):
#   LITEMAAS_RHOAI_DIR   default: ../litemaas-rhoai next to this guide
#   COMPACT_MAAS_DIR     default: ../compact-maas, then ../rhoai-maas-console
#   MAAS_CONSOLE_DIR     Deprecated alias for COMPACT_MAAS_DIR
#   MAAS_API_KEY         optional: wire LiteLLM backends after LiteMaaS install
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUIDE_DIR="$SCRIPT_DIR/.."
MANIFESTS_DIR="$GUIDE_DIR/manifests"
NAMESPACE=redhat-ods-applications
# shellcheck source=lib/maas-observability.sh
source "$SCRIPT_DIR/lib/maas-observability.sh"
# shellcheck source=lib/maas-billing.sh
source "$SCRIPT_DIR/lib/maas-billing.sh"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_phase() { echo -e "\n${BOLD}${BLUE}════════════════════════════════════════════${NC}"; echo -e "${BOLD}${BLUE}  Phase $1: $2${NC}"; echo -e "${BOLD}${BLUE}════════════════════════════════════════════${NC}"; }

MODEL="auto"
FROM_PHASE=0
SKIP_MODELS=false
SKIP_VERIFY=false
WITH_OBSERVABILITY=false
WITH_EXTERNAL_MODELS=false
WITH_LITEMAAS=false
WITH_COMPACT_MAAS=false
WITH_LAGO_BILLING=false
SKIP_LAGO_PLATFORM=false
WITH_OPENMETER_BILLING=false
SKIP_OPENMETER_PLATFORM=false
EXTERNAL_MODEL_PROVIDER="${EXTERNAL_MODEL_PROVIDER:-openai}"
EXTERNAL_MODEL_API_KEY="${EXTERNAL_MODEL_API_KEY:-}"
DRY_RUN=false

# Sibling GUI repos (absolute paths resolved after GUIDE_DIR is set)
LITEMAAS_RHOAI_DIR="${LITEMAAS_RHOAI_DIR:-}"
COMPACT_MAAS_DIR="${COMPACT_MAAS_DIR:-${MAAS_CONSOLE_DIR:-}}"
MAAS_API_KEY="${MAAS_API_KEY:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --model) MODEL="$2"; shift 2 ;;
        --from-phase) FROM_PHASE="$2"; shift 2 ;;
        --skip-models) SKIP_MODELS=true; shift ;;
        --skip-verify) SKIP_VERIFY=true; shift ;;
        --with-observability) WITH_OBSERVABILITY=true; shift ;;
        --with-external-models) WITH_EXTERNAL_MODELS=true; shift ;;
        --with-litemaas) WITH_LITEMAAS=true; shift ;;
        --with-compact-maas|--with-maas-console) WITH_COMPACT_MAAS=true; shift ;;
        --with-lago-billing) WITH_LAGO_BILLING=true; shift ;;
        --skip-lago-platform) SKIP_LAGO_PLATFORM=true; shift ;;
        --with-openmeter-billing) WITH_OPENMETER_BILLING=true; shift ;;
        --skip-openmeter-platform) SKIP_OPENMETER_PLATFORM=true; shift ;;
        --external-model-provider) EXTERNAL_MODEL_PROVIDER="$2"; shift 2 ;;
        --external-model-api-key) EXTERNAL_MODEL_API_KEY="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: setup-maas.sh [OPTIONS]

End-to-end MaaS deployment on RHOAI 3.4. Runs all phases from operator
installation through model deployment and verification. Each phase is
idempotent  - re-running skips what's already done.

Options:
  --model <name>       Model: simulator, granite-tiny-gpu, gpt-oss-20b, auto (default: auto)
  --from-phase <N>     Start from phase N (0-12, default: 0)
  --skip-models        Skip Phase 5 (model deployment)
  --skip-verify        Skip Phase 6 (verification)
  --with-observability Also run Phase 7 (Tempo + OpenTelemetry + COO + Gateway telemetry)
  --with-external-models Also run Phase 8 (ExternalModel deployment + test)
  --with-litemaas      Also run Phase 9 (LiteMaaS + LiteLLM PoC GUI)
  --with-compact-maas  Also run Phase 10 (Compact MaaS — native UX, no LiteLLM)
  --with-maas-console  Deprecated alias for --with-compact-maas
  --with-lago-billing  Also run Phase 11 (Lago billing scaffold + auto Phase 7 if needed)
  --skip-lago-platform Skip Lago Helm install (external Lago; maas-billing base still applied)
  --with-openmeter-billing Also run Phase 12 (OpenMeter billing scaffold + auto Phase 7 if needed)
  --skip-openmeter-platform Skip OpenMeter Helm install (external; maas-billing base still applied)
  --external-model-provider <p>   Provider: openai (default), gemini, bedrock (or set EXTERNAL_MODEL_PROVIDER)
  --external-model-api-key <key>  API key for external provider (or set EXTERNAL_MODEL_API_KEY)
  --dry-run            Preview without applying
  -h, --help           Show this help message

Environment:
  LITEMAAS_RHOAI_DIR   Path to litemaas-rhoai checkout (default: ../litemaas-rhoai)
  COMPACT_MAAS_DIR     Path to compact-maas checkout (default: ../compact-maas, then ../rhoai-maas-console)
  MAAS_CONSOLE_DIR     Deprecated alias for COMPACT_MAAS_DIR
  MAAS_API_KEY         Optional MaaS gateway API key to wire LiteLLM backends after Phase 9

Phases:
  0  Preflight          Detect cluster state, decide which phases to run
  1  Operators          Install required operator subscriptions (RHOAI, RHCL, etc.)
  2  Platform config    Kuadrant, UWM, GatewayClass, Gateway
  3  RHOAI config       DSC with modelsAsService: Managed, Dashboard flags
  4  MaaS platform      PostgreSQL secrets/deployment, Authorino TLS
  5  Deploy model       Auto-detect GPU, apply model Kustomize manifests
  6  Verify             6-phase E2E verification (API, auth, rate limits)
  7  Observability      Tempo + OpenTelemetry + COO + Gateway telemetry (only with --with-observability)
  8  External models    ExternalModel + governance (only with --with-external-models)
  9  LiteMaaS           LiteMaaS + LiteLLM GUI PoC (only with --with-litemaas)
 10  Compact MaaS       Thin native MaaS UI/BFF (only with --with-compact-maas)
 11  Lago billing       Lago platform + maas-billing RBAC/templates (only with --with-lago-billing)
 12  OpenMeter billing  OpenMeter platform + maas-billing (only with --with-openmeter-billing)

Pick ONE billing backend per cluster (Lago or OpenMeter, not both).

Auto-detection (--model auto):
  No GPU             -> simulator (CPU-only, ~30s startup)
  GPU VRAM >= 40 GiB -> gpt-oss-20b (L40S, A100, H100)
  GPU VRAM <  40 GiB -> granite-tiny-gpu (T4, L4, A10)
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Resolve sibling GUI directories (absolute)
if [ -z "$LITEMAAS_RHOAI_DIR" ]; then
    LITEMAAS_RHOAI_DIR="$(cd "$GUIDE_DIR/../litemaas-rhoai" 2>/dev/null && pwd || echo "$GUIDE_DIR/../litemaas-rhoai")"
fi
if [ -z "$COMPACT_MAAS_DIR" ]; then
    if [ -d "$GUIDE_DIR/../compact-maas" ]; then
        COMPACT_MAAS_DIR="$(cd "$GUIDE_DIR/../compact-maas" && pwd)"
    elif [ -d "$GUIDE_DIR/../rhoai-maas-console" ]; then
        COMPACT_MAAS_DIR="$(cd "$GUIDE_DIR/../rhoai-maas-console" && pwd)"
    else
        COMPACT_MAAS_DIR="$GUIDE_DIR/../compact-maas"
    fi
fi
# Normalize to absolute when path exists
[ -d "$LITEMAAS_RHOAI_DIR" ] && LITEMAAS_RHOAI_DIR="$(cd "$LITEMAAS_RHOAI_DIR" && pwd)"
[ -d "$COMPACT_MAAS_DIR" ] && COMPACT_MAAS_DIR="$(cd "$COMPACT_MAAS_DIR" && pwd)"

require_sibling_repo() {
    local label="$1" dir="$2" script_rel="$3" env_name="$4" clone_hint="$5"
    if [ ! -x "$dir/$script_rel" ] && [ ! -f "$dir/$script_rel" ]; then
        log_error "$label checkout not found or missing $script_rel"
        log_error "  Expected: $dir/$script_rel"
        log_error "  Clone $clone_hint next to this guide, or set $env_name to the repo path."
        return 1
    fi
    return 0
}

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

should_run() { [ "$FROM_PHASE" -le "$1" ]; }

wait_for() {
    local desc="$1"; shift
    local timeout="${1:-120}"; shift
    log_info "Waiting for $desc (timeout: ${timeout}s)..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would wait for: $desc"
        return 0
    fi
    if ! "$@" --timeout="${timeout}s" 2>/dev/null; then
        log_warn "$desc did not complete within ${timeout}s"
        return 1
    fi
    log_info "$desc: done"
}

# OpenShift AI's openshift-ai-inference Gateway references default-gateway-tls, but
# cert-manager-based ingress uses a differently named secret (e.g. cert-manager-ingress-cert).
ensure_default_gateway_tls() {
    local ingress_ns="openshift-ingress"
    local target_secret="default-gateway-tls"
    local source_secret="${CERT_NAME:-router-certs-default}"

    [ "$source_secret" = "$target_secret" ] && return 0

    if ! oc get secret "$source_secret" -n "$ingress_ns" &>/dev/null; then
        log_warn "Ingress TLS secret ${source_secret} not found; skipping ${target_secret} sync"
        return 0
    fi

    if oc get secret "$target_secret" -n "$ingress_ns" &>/dev/null; then
        log_info "Secret ${target_secret} already exists in ${ingress_ns}, skipping"
        return 0
    fi

    log_step "Creating ${target_secret} from ${source_secret} (OpenShift AI inference gateway TLS)..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would create secret ${target_secret} from ${source_secret}"
        return 0
    fi

    local cert_file key_file
    cert_file=$(mktemp)
    key_file=$(mktemp)
    oc get secret "$source_secret" -n "$ingress_ns" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$cert_file"
    oc get secret "$source_secret" -n "$ingress_ns" -o jsonpath='{.data.tls\.key}' | base64 -d > "$key_file"
    oc create secret tls "$target_secret" \
        --cert="$cert_file" --key="$key_file" \
        -n "$ingress_ns" --dry-run=client -o yaml | oc apply -f -
    rm -f "$cert_file" "$key_file"

    log_info "Secret ${target_secret} created"

    if oc get gateway openshift-ai-inference -n "$ingress_ns" &>/dev/null; then
        if wait_for "openshift-ai-inference Gateway HTTPS listener" 60 \
            oc wait gateway/openshift-ai-inference -n "$ingress_ns" \
            --for=jsonpath='{.status.listeners[?(@.name=="https")].conditions[?(@.type=="Programmed")].status}'=True; then
            log_info "openshift-ai-inference Gateway HTTPS listener: Programmed"
        else
            log_warn "openshift-ai-inference Gateway HTTPS listener not yet Programmed"
        fi
    fi
}

# RHOAI 3.5+ Gateways (data-science-gateway, openshift-ai-inference) default to 1Gi and
# OOMKill when Kuadrant Wasm loads. maas-default-gateway uses maas-gateway-options instead.
ensure_rhoai_gateway_proxy_memory() {
    local ingress_ns="openshift-ingress"
    local rhoai_cm="openshift-ai-inference-gateway-options"
    local ds_cm="data-science-gateway-config"
    local deployment_patch='spec:
  template:
    spec:
      containers:
      - name: istio-proxy
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: "2"
            memory: 2Gi
'

    log_step "Ensuring RHOAI gateway proxy memory limits (2Gi)..."

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would apply ${rhoai_cm} and patch RHOAI gateway ConfigMaps"
        return 0
    fi

    run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/rhoai-gateway-resources.yaml"

    if oc get gateway openshift-ai-inference -n "$ingress_ns" &>/dev/null; then
        local params_ref
        params_ref=$(oc get gateway openshift-ai-inference -n "$ingress_ns" \
            -o jsonpath='{.spec.infrastructure.parametersRef.name}' 2>/dev/null || echo "")
        if [ "$params_ref" != "$rhoai_cm" ]; then
            run_cmd oc patch gateway openshift-ai-inference -n "$ingress_ns" --type=merge -p "{
              \"spec\": {\"infrastructure\": {\"parametersRef\": {
                \"group\": \"\", \"kind\": \"ConfigMap\", \"name\": \"${rhoai_cm}\"
              }}}
            }"
        fi
    fi

    if oc get configmap "$ds_cm" -n "$ingress_ns" &>/dev/null; then
        local ds_mem has_deploy
        ds_mem=$(oc get deployment data-science-gateway-data-science-gateway-class -n "$ingress_ns" \
            -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || echo "")
        has_deploy=$(oc get configmap "$ds_cm" -n "$ingress_ns" \
            -o jsonpath='{.data.deployment}' 2>/dev/null || echo "")
        if [ -z "$has_deploy" ] || [ "$ds_mem" != "2Gi" ]; then
            run_cmd oc patch configmap "$ds_cm" -n "$ingress_ns" --type=merge -p "$(python3 -c "
import json, sys
print(json.dumps({'data': {'deployment': sys.stdin.read()}}))
" <<< "$deployment_patch")"
        fi
    fi

    for gw in data-science-gateway openshift-ai-inference; do
        local reason restarts
        reason=$(oc get pods -n "$ingress_ns" -l "gateway.networking.k8s.io/gateway-name=${gw}" \
            -o jsonpath='{.items[0].status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || echo "")
        restarts=$(oc get pods -n "$ingress_ns" -l "gateway.networking.k8s.io/gateway-name=${gw}" \
            -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
        if [ "$reason" = "OOMKilled" ] || [ "${restarts:-0}" -ge 3 ]; then
            log_warn "Restarting ${gw} gateway pod after OOM/restarts (${restarts})"
            oc delete pod -n "$ingress_ns" -l "gateway.networking.k8s.io/gateway-name=${gw}" --wait=false 2>/dev/null || true
        fi
    done

    log_info "RHOAI gateway proxy memory limits applied"
}

# =============================================================================
# Phase 0: Preflight
# =============================================================================
log_phase 0 "Preflight"

if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster. Run: oc login <cluster>"
    exit 1
fi
log_info "Cluster: $(oc whoami --show-server)"
log_info "User:    $(oc whoami)"

# Detect cluster domain (needed by multiple phases)
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
if [ -z "$CLUSTER_DOMAIN" ]; then
    log_error "Cannot detect cluster domain. Is this an OpenShift cluster?"
    exit 1
fi
log_info "Cluster domain: ${CLUSTER_DOMAIN}"

# Detect TLS certificate name
CERT_NAME=$(oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || echo "")
[ -z "$CERT_NAME" ] && CERT_NAME="router-certs-default"
log_info "TLS certificate: ${CERT_NAME}"

# State detection
HAS_RHOAI_CSV=false
HAS_RHCL_CSV=false
HAS_KUADRANT=false
HAS_UWM=false
HAS_GATEWAY_CLASS=false
HAS_GATEWAY=false
HAS_DSC=false
HAS_DSCI=false
HAS_MAAS_MANAGED=false
HAS_POSTGRES=false
HAS_MAAS_API=false
HAS_TENANT=false
HAS_MODELS=false
HAS_METALLB=false
HAS_GATEWAY_TELEMETRY=false

# Detect cloud vs non-cloud platform (affects Gateway LB provisioning)
PLATFORM_TYPE=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null || echo "Unknown")
IS_CLOUD_PLATFORM=false
case "$PLATFORM_TYPE" in
    AWS|GCP|Azure) IS_CLOUD_PLATFORM=true ;;
esac
log_info "Platform type: ${PLATFORM_TYPE} (cloud LB: ${IS_CLOUD_PLATFORM})"

# Note: avoid grep -q in pipelines  - with pipefail, grep -q causes SIGPIPE (exit 141)
RHOAI_CSVS=$(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null || true)
echo "$RHOAI_CSVS" | grep rhods >/dev/null 2>&1 && HAS_RHOAI_CSV=true
RHCL_CSVS=$(oc get csv -n openshift-operators --no-headers 2>/dev/null || true)
echo "$RHCL_CSVS" | grep rhcl >/dev/null 2>&1 && HAS_RHCL_CSV=true
oc get kuadrant kuadrant -n kuadrant-system &>/dev/null && HAS_KUADRANT=true
UWM_CFG=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
echo "$UWM_CFG" | grep enableUserWorkload >/dev/null 2>&1 && HAS_UWM=true
oc get gatewayclass openshift-default &>/dev/null && HAS_GATEWAY_CLASS=true
oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null && HAS_GATEWAY=true
oc get datasciencecluster default-dsc &>/dev/null && HAS_DSC=true
oc get dsci default-dsci &>/dev/null && HAS_DSCI=true
if [ "$HAS_DSC" = true ]; then
    MAAS_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}' 2>/dev/null || echo "")
    [ -z "$MAAS_STATE" ] && MAAS_STATE=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.kserve.modelsAsService.managementState}' 2>/dev/null || echo "")
    [ "$MAAS_STATE" = "Managed" ] && HAS_MAAS_MANAGED=true
fi
oc get deployment postgres -n "$NAMESPACE" &>/dev/null && HAS_POSTGRES=true
oc get deployment maas-api -n "$NAMESPACE" &>/dev/null && HAS_MAAS_API=true
oc get deployment maas-api -n redhat-ai-gateway-infra &>/dev/null && HAS_MAAS_API=true
oc get deployment maas-controller -n "$NAMESPACE" &>/dev/null && HAS_MAAS_API=true
oc get tenant -n models-as-a-service &>/dev/null && HAS_TENANT=true
MODEL_COUNT=$(oc get llminferenceservice -A --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
[ "$MODEL_COUNT" -gt 0 ] 2>/dev/null && HAS_MODELS=true
METALLB_CSVS=$(oc get csv -n metallb-system --no-headers 2>/dev/null || true)
echo "$METALLB_CSVS" | grep "metallb-operator" >/dev/null 2>&1 && HAS_METALLB=true
if maas_gateway_telemetry_ready; then HAS_GATEWAY_TELEMETRY=true; else HAS_GATEWAY_TELEMETRY=false; fi

echo ""
log_info "Detected state:"
log_info "  RHOAI operator:     $([ "$HAS_RHOAI_CSV" = true ] && echo "installed" || echo "not found")"
log_info "  RHCL operator:      $([ "$HAS_RHCL_CSV" = true ] && echo "installed" || echo "not found")"
log_info "  Kuadrant CR:        $([ "$HAS_KUADRANT" = true ] && echo "ready" || echo "not found")"
log_info "  User Workload Mon:  $([ "$HAS_UWM" = true ] && echo "enabled" || echo "not enabled")"
log_info "  GatewayClass:       $([ "$HAS_GATEWAY_CLASS" = true ] && echo "exists" || echo "not found")"
log_info "  Gateway:            $([ "$HAS_GATEWAY" = true ] && echo "exists" || echo "not found")"
log_info "  DataScienceCluster: $([ "$HAS_DSC" = true ] && echo "exists" || echo "not found")"
log_info "  DSCInitialization:  $([ "$HAS_DSCI" = true ] && echo "exists" || echo "not found")"
log_info "  modelsAsService:    $([ "$HAS_MAAS_MANAGED" = true ] && echo "Managed" || echo "not managed")"
log_info "  PostgreSQL:         $([ "$HAS_POSTGRES" = true ] && echo "running" || echo "not deployed")"
log_info "  maas-api:           $([ "$HAS_MAAS_API" = true ] && echo "running" || echo "not deployed")"
log_info "  Tenant CR:          $([ "$HAS_TENANT" = true ] && echo "ready" || echo "not found")"
log_info "  MetalLB operator:   $([ "$HAS_METALLB" = true ] && echo "installed" || echo "not found")"
log_info "  Models deployed:    $([ "$HAS_MODELS" = true ] && echo "yes" || echo "no")"
log_info "  Gateway telemetry:  $([ "$HAS_GATEWAY_TELEMETRY" = true ] && echo "ready (Phase 7)" || echo "not installed")"

# Determine which phases will run
PHASES_TO_RUN=""
should_run 1 && PHASES_TO_RUN="$PHASES_TO_RUN 1"
should_run 2 && PHASES_TO_RUN="$PHASES_TO_RUN 2"
should_run 3 && PHASES_TO_RUN="$PHASES_TO_RUN 3"
should_run 4 && PHASES_TO_RUN="$PHASES_TO_RUN 4"
should_run 5 && [ "$SKIP_MODELS" = false ] && PHASES_TO_RUN="$PHASES_TO_RUN 5"
should_run 6 && [ "$SKIP_VERIFY" = false ] && PHASES_TO_RUN="$PHASES_TO_RUN 6"
should_run 7 && [ "$WITH_OBSERVABILITY" = true ] && PHASES_TO_RUN="$PHASES_TO_RUN 7"
should_run 8 && [ "$WITH_EXTERNAL_MODELS" = true ] && PHASES_TO_RUN="$PHASES_TO_RUN 8"
should_run 9 && [ "$WITH_LITEMAAS" = true ] && PHASES_TO_RUN="$PHASES_TO_RUN 9"
should_run 10 && [ "$WITH_COMPACT_MAAS" = true ] && PHASES_TO_RUN="$PHASES_TO_RUN 10"
should_run 11 && [ "$WITH_LAGO_BILLING" = true ] && PHASES_TO_RUN="$PHASES_TO_RUN 11"
should_run 12 && [ "$WITH_OPENMETER_BILLING" = true ] && PHASES_TO_RUN="$PHASES_TO_RUN 12"

if [ "$WITH_LAGO_BILLING" = true ] && [ "$WITH_OPENMETER_BILLING" = true ]; then
    log_error "Choose one billing backend: --with-lago-billing OR --with-openmeter-billing (not both)"
    exit 1
fi

# Billing usage-reporter needs gateway telemetry labels — ensure Phase 7 runs when billing is requested.
if { [ "$WITH_LAGO_BILLING" = true ] || [ "$WITH_OPENMETER_BILLING" = true ]; } && [ "$HAS_GATEWAY_TELEMETRY" = false ]; then
    if [ "$WITH_OBSERVABILITY" = false ]; then
        log_info "Phase 11 requires gateway telemetry — will install Phase 7 observability first"
    fi
    WITH_OBSERVABILITY=true
fi
echo ""
log_info "Phases to run:${PHASES_TO_RUN:- (none)}"

# =============================================================================
# Phase 1: Operators
# =============================================================================
if should_run 1; then
    log_phase 1 "Operators"

    if [ "$HAS_RHOAI_CSV" = true ] && [ "$HAS_RHCL_CSV" = true ]; then
        log_info "Required operators already installed, skipping"
    else
        if oc get operatorgroup redhat-ods-operator -n redhat-ods-operator &>/dev/null && \
           oc get operatorgroup redhat-ods-operator-og -n redhat-ods-operator &>/dev/null; then
            log_error "Duplicate OperatorGroups in redhat-ods-operator (redhat-ods-operator + redhat-ods-operator-og)."
            log_error "This breaks the RHOAI CSV. Fix before continuing:"
            log_error "  oc delete operatorgroup redhat-ods-operator -n redhat-ods-operator"
            log_error "  oc delete csv rhods-operator.3.5.0 -n redhat-ods-operator  # if phase is Failed"
            log_error "Then re-run: ./scripts/setup-maas.sh --from-phase 1"
            exit 1
        fi

        HAS_RHOAI_SUB=false
        oc get subscription rhods-operator -n redhat-ods-operator &>/dev/null && HAS_RHOAI_SUB=true

        log_info "Applying operator subscriptions..."
        for op_dir in cert-manager connectivity-link leader-worker-set; do
            run_cmd oc apply -k "$MANIFESTS_DIR/01-prerequisites/operators/$op_dir/"
        done
        if [ "$HAS_RHOAI_SUB" = true ]; then
            log_info "RHOAI subscription already exists — skipping rhoai-operator manifests (avoids duplicate OperatorGroup)"
        else
            run_cmd oc apply -k "$MANIFESTS_DIR/01-prerequisites/operators/rhoai-operator/"
        fi
        log_info "Operator subscriptions applied"

        log_info "Waiting for operator CSVs (this may take 5-10 minutes)..."
        if [ "$DRY_RUN" = false ]; then
            for ns_label in \
                "redhat-ods-operator operators.coreos.com/rhods-operator.redhat-ods-operator" \
                "cert-manager-operator operators.coreos.com/openshift-cert-manager-operator.cert-manager-operator" \
                "openshift-lws-operator operators.coreos.com/leader-worker-set.openshift-lws-operator"
            do
                ns="${ns_label%% *}"
                label="${ns_label#* }"
                log_info "  Waiting for CSV in $ns..."
                oc wait csv -n "$ns" -l "$label=" \
                    --for=jsonpath='{.status.phase}'=Succeeded --timeout=900s 2>/dev/null || \
                    { log_error "  CSV in $ns did not reach Succeeded within 900s — aborting (re-run with --from-phase 1 after manual check)"; exit 1; }
            done

            log_info "  Waiting for RHCL CSV in openshift-operators (Manual approval)..."
            RHCL_APPROVED=false
            RHCL_TIMEOUT=900
            RHCL_ELAPSED=0
            while [ $RHCL_ELAPSED -lt $RHCL_TIMEOUT ]; do
                if [ "$RHCL_APPROVED" = false ]; then
                    PLAN_NAME=$(oc get subscription rhcl-operator -n openshift-operators \
                        -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
                    if [ -n "$PLAN_NAME" ]; then
                        APPROVED=$(oc get installplan "$PLAN_NAME" -n openshift-operators \
                            -o jsonpath='{.spec.approved}' 2>/dev/null || echo "true")
                        if [ "$APPROVED" != "true" ]; then
                            oc patch installplan "$PLAN_NAME" -n openshift-operators \
                                --type=merge -p '{"spec":{"approved":true}}' 2>/dev/null || true
                            log_info "  Install plan $PLAN_NAME approved"
                        fi
                        RHCL_APPROVED=true
                    fi
                fi
                RHCL_PHASE=$(oc get csv -n openshift-operators -l 'operators.coreos.com/rhcl-operator.openshift-operators=' \
                    --no-headers -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
                if [ "$RHCL_PHASE" = "Succeeded" ]; then
                    log_info "  RHCL CSV: Succeeded"
                    break
                fi
                sleep 5
                RHCL_ELAPSED=$((RHCL_ELAPSED + 5))
                [ $((RHCL_ELAPSED % 60)) -eq 0 ] && log_info "    Still waiting for RHCL... (${RHCL_ELAPSED}s)"
            done
            if [ "$RHCL_PHASE" != "Succeeded" ]; then
                log_error "  CSV in openshift-operators did not reach Succeeded within ${RHCL_TIMEOUT}s — aborting (re-run with --from-phase 1 after manual check)"
                exit 1
            fi
        else
            log_info "[DRY RUN] Would approve RHCL install plan"
        fi
        log_info "All operator CSVs ready"
    fi
fi

# =============================================================================
# Phase 2: Platform Configuration
# =============================================================================
if should_run 2; then
    log_phase 2 "Platform Configuration"

    # Step 1: Kuadrant + Authorino TLS (per RHOAI 3.4 docs section 1.4)
    if [ "$HAS_KUADRANT" = true ]; then
        log_info "Kuadrant already configured, skipping"
    else
        log_step "Creating kuadrant-system namespace and service annotation..."
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/kuadrant/namespace.yaml"
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/kuadrant/service-annotation.yaml"

        log_step "Creating Kuadrant CR..."
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/kuadrant/kuadrant.yaml"

        if [ "$DRY_RUN" = false ]; then
            if ! oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=60s 2>/dev/null; then
                KUADRANT_MSG=$(oc get kuadrant kuadrant -n kuadrant-system \
                    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
                if echo "$KUADRANT_MSG" | grep -i "MissingDependency" >/dev/null 2>&1; then
                    log_warn "Kuadrant reports MissingDependency (Istio race)  - restarting operator pod..."
                    oc delete pod -n openshift-operators \
                        $(oc get pods -n openshift-operators --no-headers 2>/dev/null | grep kuadrant-operator | awk '{print $1}' | head -1) 2>/dev/null || \
                        oc delete pod -n openshift-operators -l control-plane=controller-manager,app=kuadrant 2>/dev/null || true
                    log_info "Operator pod restarted, waiting for Kuadrant Ready..."
                fi
                oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s 2>/dev/null || \
                    { log_error "Kuadrant did not become Ready  - check: oc get kuadrant kuadrant -n kuadrant-system -o yaml"; exit 1; }
            fi
            log_info "Kuadrant: Ready"
        else
            log_info "[DRY RUN] Would wait for Kuadrant Ready"
        fi

        log_step "Patching Authorino CR to enable TLS listener (docs section 1.4, step 2)..."
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] oc patch authorino authorino -n kuadrant-system --type=merge (enable TLS + certSecretRef)"
        else
            oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
              "spec": {
                "listener": {
                  "tls": {
                    "enabled": true,
                    "certSecretRef": {
                      "name": "authorino-server-cert"
                    }
                  }
                }
              }
            }'
            log_info "Authorino TLS listener enabled with certSecretRef: authorino-server-cert"
        fi

        log_step "Configuring Authorino TLS env vars (docs section 1.4, step 3)..."
        run_cmd oc -n kuadrant-system set env deployment/authorino \
            SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
            REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
        log_info "Authorino SSL env vars set"

        if [ "$DRY_RUN" = false ]; then
            oc get secret authorino-server-cert -n kuadrant-system &>/dev/null && \
                log_info "Authorino TLS cert generated" || \
                log_warn "Authorino TLS cert not yet available"
        fi
    fi

    # Step 2: User Workload Monitoring
    if [ "$HAS_UWM" = true ]; then
        log_info "User Workload Monitoring already enabled, skipping"
    else
        log_step "Enabling User Workload Monitoring (REQUIRED for MaaS)..."
        run_cmd oc apply -k "$MANIFESTS_DIR/02-platform-config/uwm/"
        log_info "UWM configured  - prometheus-user-workload pods will start shortly"
    fi

    # Step 3: GatewayClass
    if [ "$HAS_GATEWAY_CLASS" = true ]; then
        log_info "GatewayClass openshift-default already exists, skipping"
    else
        log_step "Creating GatewayClass..."
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/gatewayclass.yaml"
        wait_for "GatewayClass accepted (openshift-ingress installs OSSM)" 300 \
            oc wait gatewayclass openshift-default \
            --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True
    fi

    # Step 4: Gateway
    if [ "$HAS_GATEWAY" = true ]; then
        log_info "Gateway maas-default-gateway already exists, skipping"
    else
        log_step "Rendering and applying Gateway..."
        GATEWAY_TEMPLATE="$MANIFESTS_DIR/02-platform-config/gateway.yaml.tmpl"
        if [ ! -f "$GATEWAY_TEMPLATE" ]; then
            log_error "Gateway template not found: $GATEWAY_TEMPLATE"
            exit 1
        fi
        log_info "Rendering with CLUSTER_DOMAIN=${CLUSTER_DOMAIN}, CERT_NAME=${CERT_NAME}"
        export CLUSTER_DOMAIN CERT_NAME
        # Apply gateway resource ConfigMap first (sets 2Gi memory limit via parametersRef)
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/gateway-resources.yaml"
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] envsubst < gateway.yaml.tmpl | oc apply -f -"
        else
            envsubst '${CLUSTER_DOMAIN} ${CERT_NAME}' < "$GATEWAY_TEMPLATE" | oc apply -f -
        fi
        if [ "$DRY_RUN" = false ]; then
            if ! oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=120s 2>/dev/null; then
                GW_REASON=$(oc get gateway maas-default-gateway -n openshift-ingress \
                    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].reason}' 2>/dev/null || echo "")
                if [ "$GW_REASON" = "AddressNotAssigned" ]; then
                    log_warn "Gateway LoadBalancer address pending (no cloud LB provisioner)"

                    # Non-cloud clusters need MetalLB to provision LB IPs
                    if [ "$IS_CLOUD_PLATFORM" = false ]; then
                        log_step "Non-cloud platform detected  - installing MetalLB..."

                        if [ "$HAS_METALLB" = false ]; then
                            log_info "Installing MetalLB operator..."
                            oc apply -k "$MANIFESTS_DIR/01-prerequisites/metallb/"
                            log_info "Waiting for MetalLB CSV..."
                            METALLB_TIMEOUT=120
                            METALLB_ELAPSED=0
                            while [ $METALLB_ELAPSED -lt $METALLB_TIMEOUT ]; do
                                METALLB_CSV_STATUS=$(oc get csv -n metallb-system --no-headers 2>/dev/null | grep metallb-operator | awk '{print $NF}' || echo "")
                                if [ "$METALLB_CSV_STATUS" = "Succeeded" ]; then
                                    break
                                fi
                                sleep 10
                                METALLB_ELAPSED=$((METALLB_ELAPSED + 10))
                            done
                            if [ "$METALLB_CSV_STATUS" != "Succeeded" ]; then
                                log_warn "MetalLB CSV did not reach Succeeded within ${METALLB_TIMEOUT}s (status: ${METALLB_CSV_STATUS:-unknown})"
                            else
                                log_info "MetalLB operator: Succeeded"
                            fi
                        fi

                        # Create MetalLB CR if needed
                        if ! oc get metallb metallb -n metallb-system &>/dev/null; then
                            log_info "Creating MetalLB CR..."
                            oc apply -f "$MANIFESTS_DIR/01-prerequisites/metallb/metallb.yaml"
                            oc wait --for=jsonpath='{.status.conditions[?(@.type=="Available")].status}'=True \
                                metallb/metallb -n metallb-system --timeout=120s 2>/dev/null || \
                                log_warn "MetalLB CR did not become Available"
                        fi

                        # Create IPAddressPool + L2Advertisement if needed
                        if ! oc get ipaddresspool maas-pool -n metallb-system &>/dev/null; then
                            NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")
                            if [ -n "$NODE_IP" ]; then
                                METALLB_IP=$(echo "$NODE_IP" | awk -F. '{printf "%s.%s.%s.%d", $1, $2, $3, $4+1}')
                                METALLB_IP_RANGE="${METALLB_IP}-${METALLB_IP}"
                                log_info "Creating MetalLB IPAddressPool: ${METALLB_IP_RANGE} (node IP: ${NODE_IP})"
                                export METALLB_IP_RANGE
                                envsubst '${METALLB_IP_RANGE}' < "$MANIFESTS_DIR/03-maas-platform/openshift-gateway-setup/metallb-config.yaml" | oc apply -f -
                            else
                                log_warn "Cannot detect node IP for MetalLB pool"
                            fi
                        fi

                        # Wait for Gateway to pick up the MetalLB address
                        log_info "Waiting for Gateway to become Programmed with MetalLB address..."
                        if oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=60s 2>/dev/null; then
                            log_info "Gateway: Programmed (MetalLB)"
                        else
                            log_warn "Gateway still not Programmed after MetalLB setup"
                        fi
                    fi

                    # Create passthrough Route as fallback (works for both MetalLB and non-MetalLB)
                    log_info "Creating passthrough Route as fallback..."
                    ROUTE_TMPL="$MANIFESTS_DIR/03-maas-platform/openshift-gateway-setup/route.yaml.tmpl"
                    if [ -f "$ROUTE_TMPL" ]; then
                        export CLUSTER_DOMAIN
                        envsubst '${CLUSTER_DOMAIN}' < "$ROUTE_TMPL" | oc apply -f -
                        log_info "Route maas-default-gateway-https created  - traffic routed via OpenShift ingress"
                    else
                        log_warn "Route template not found: $ROUTE_TMPL"
                    fi
                else
                    log_warn "Gateway not Programmed (reason: ${GW_REASON:-unknown})"
                fi
            else
                log_info "Gateway: Programmed"
            fi
        else
            log_info "[DRY RUN] Would wait for Gateway Programmed"
        fi
    fi

    # Step 5: Annotate Gateway for Authorino TLS bootstrap (docs section 1.4, step 4)
    EXISTING_ANNOTATION=$(oc get gateway maas-default-gateway -n openshift-ingress \
        -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/authorino-tls-bootstrap}' 2>/dev/null || echo "")
    if [ "$EXISTING_ANNOTATION" != "true" ]; then
        log_step "Annotating Gateway for Authorino TLS bootstrap (docs section 1.4, step 4)..."
        run_cmd oc annotate gateway maas-default-gateway -n openshift-ingress \
            security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
        log_info "Gateway authorino-tls-bootstrap annotation applied"
    fi

    # Label redhat-ods-applications for Gateway route binding (best practice: least privilege)
    oc label namespace redhat-ods-applications maas.opendatahub.io/gateway-access=true --overwrite 2>/dev/null || true

    ensure_default_gateway_tls
    ensure_rhoai_gateway_proxy_memory
fi

# =============================================================================
# Phase 3: MaaS Platform (PostgreSQL + secrets before DSC enables modelsAsService)
# =============================================================================
if should_run 3; then
    log_phase 3 "MaaS Platform"

    # Step 1: PostgreSQL secrets
    log_step "PostgreSQL secrets"
    if oc get secret postgres-creds -n "$NAMESPACE" &>/dev/null 2>&1; then
        log_info "postgres-creds already exists, skipping"
    else
        POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
        run_cmd oc create secret generic postgres-creds \
            -n "$NAMESPACE" \
            --from-literal=POSTGRES_USER=maas \
            --from-literal=POSTGRES_DB=maas \
            --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
        run_cmd oc create secret generic maas-db-config \
            -n "$NAMESPACE" \
            --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres.${NAMESPACE}.svc:5432/maas?sslmode=disable"
        log_info "PostgreSQL secrets created"
    fi

    # Step 2: PostgreSQL deployment
    log_step "PostgreSQL deployment"
    if [ "$HAS_POSTGRES" = true ]; then
        log_info "PostgreSQL already deployed, skipping"
    else
        run_cmd oc apply -k "$MANIFESTS_DIR/03-maas-platform/"
        wait_for "PostgreSQL available" 120 \
            oc wait --for=condition=Available deployment/postgres -n "$NAMESPACE"
    fi

    # Step 3: Ensure Gateway + TLS exists (may have been created in Phase 2)
    if ! oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null 2>&1; then
        log_step "Rendering and applying Gateway (not created in Phase 2)..."
        export CLUSTER_DOMAIN CERT_NAME
        run_cmd oc apply -f "$MANIFESTS_DIR/02-platform-config/gateway-resources.yaml"
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] envsubst < gateway.yaml.tmpl | oc apply -f -"
        else
            envsubst '${CLUSTER_DOMAIN} ${CERT_NAME}' < "$MANIFESTS_DIR/02-platform-config/gateway.yaml.tmpl" | oc apply -f -
        fi
    fi
    # Ensure Authorino TLS is configured (may have been done in Phase 2)
    AUTHORINO_TLS=$(oc get authorino authorino -n kuadrant-system \
        -o jsonpath='{.spec.listener.tls.enabled}' 2>/dev/null || echo "")
    if [ "$AUTHORINO_TLS" != "true" ]; then
        log_step "Patching Authorino CR for TLS (docs section 1.4, step 2)..."
        run_cmd oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
          "spec": {"listener": {"tls": {"enabled": true, "certSecretRef": {"name": "authorino-server-cert"}}}}
        }'
    fi
    EXISTING_ENVS=$(oc get deployment authorino -n kuadrant-system \
        -o jsonpath='{.spec.template.spec.containers[0].env[*].name}' 2>/dev/null || echo "")
    if ! echo "$EXISTING_ENVS" | grep SSL_CERT_FILE >/dev/null 2>&1; then
        log_step "Configuring Authorino TLS env vars (docs section 1.4, step 3)..."
        run_cmd oc -n kuadrant-system set env deployment/authorino \
            SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
            REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
    fi
    EXISTING_ANNOTATION=$(oc get gateway maas-default-gateway -n openshift-ingress \
        -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/authorino-tls-bootstrap}' 2>/dev/null || echo "")
    if [ "$EXISTING_ANNOTATION" != "true" ]; then
        log_step "Annotating Gateway for TLS bootstrap (docs section 1.4, step 4)..."
        run_cmd oc annotate gateway maas-default-gateway -n openshift-ingress \
            security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
    fi
fi

# =============================================================================
# Phase 4: RHOAI Configuration (DSC enables modelsAsService after DB exists)
# =============================================================================
if should_run 4; then
    log_phase 4 "RHOAI Configuration"

    if [ "$HAS_MAAS_MANAGED" = true ]; then
        log_info "DSC already has modelsAsService: Managed, skipping"
    else
        if [ "$HAS_DSCI" = true ]; then
            log_info "DSCInitialization default-dsci already exists, skipping"
        else
            log_step "Applying DSCInitialization..."
            run_cmd oc apply -f "$MANIFESTS_DIR/04-rhoai-config/dscinitialization.yaml"
        fi

        if [ "$HAS_DSC" = true ]; then
            RHOAI_VER=$(oc get csv -n redhat-ods-operator -l 'operators.coreos.com/rhods-operator.redhat-ods-operator=' \
                -o jsonpath='{.items[0].spec.version}' 2>/dev/null || echo "0.0.0")
            if printf '%s\n%s' "$RHOAI_VER" "3.5.0" | sort -V | head -1 | grep -q '^3\.5\.0$' && [ "$RHOAI_VER" != "0.0.0" ]; then
                log_step "Patching existing DataScienceCluster to enable MaaS via aigateway (RHOAI ${RHOAI_VER})..."
                run_cmd oc patch datasciencecluster default-dsc --type=merge -p '{
                  "spec": {
                    "components": {
                      "aigateway": {
                        "managementState": "Managed",
                        "modelsAsAService": {
                          "managementState": "Managed"
                        }
                      }
                    }
                  }
                }'
            else
                log_step "Patching existing DataScienceCluster to enable modelsAsService (RHOAI ${RHOAI_VER})..."
                run_cmd oc patch datasciencecluster default-dsc --type=merge -p '{
                  "spec": {
                    "components": {
                      "kserve": {
                        "modelsAsService": {
                          "managementState": "Managed"
                        }
                      }
                    }
                  }
                }'
            fi
        else
            log_step "Applying DataScienceCluster..."
            run_cmd oc apply -f "$MANIFESTS_DIR/04-rhoai-config/datasciencecluster.yaml"
        fi
        log_info "DSC/DSCI configured for MaaS"

        if [ "$DRY_RUN" = false ]; then
            log_info "Waiting for KserveReady condition (up to 5 minutes)..."
            oc wait --for=jsonpath='{.status.conditions[?(@.type=="KserveReady")].status}'=True \
                datasciencecluster/default-dsc --timeout=300s 2>/dev/null || \
                log_warn "KserveReady did not become True within 300s"

            log_info "Waiting for ModelControllerReady condition..."
            oc wait --for=jsonpath='{.status.conditions[?(@.type=="ModelControllerReady")].status}'=True \
                datasciencecluster/default-dsc --timeout=300s 2>/dev/null || \
                log_warn "ModelControllerReady did not become True within 300s"

            if oc get crd maasmodelrefs.maas.opendatahub.io &>/dev/null; then
                log_info "MaaS CRDs registered"
            else
                log_warn "MaaS CRDs not yet registered  - operator may still be reconciling"
            fi
        fi

        log_step "Applying OdhDashboardConfig..."
        RHOAI_VER_DASH=$(oc get csv -n redhat-ods-operator -l 'operators.coreos.com/rhods-operator.redhat-ods-operator=' \
            -o jsonpath='{.items[0].spec.version}' 2>/dev/null || echo "0.0.0")
        if printf '%s\n%s' "$RHOAI_VER_DASH" "3.5.0" | sort -V | head -1 | grep -q '^3\.5\.0$' && [ "$RHOAI_VER_DASH" != "0.0.0" ]; then
            log_info "RHOAI ${RHOAI_VER_DASH}: patching dashboard flags only (deprecated keys omitted for 3.5+)"
            run_cmd oc patch odhdashboardconfig odh-dashboard-config -n "$NAMESPACE" --type=merge -p '{
              "spec": {
                "dashboardConfig": {
                  "modelAsService": true,
                  "genAiStudio": true
                }
              }
            }'
        else
            run_cmd oc apply -f "$MANIFESTS_DIR/04-rhoai-config/odh-dashboard-config.yaml"
        fi
        if [ "$DRY_RUN" = false ]; then
            for _attempt in 1 2 3; do
                sleep 10
                MAAS_FLAG=$(oc get odhdashboardconfig odh-dashboard-config -n "$NAMESPACE" \
                    -o jsonpath='{.spec.dashboardConfig.modelAsService}' 2>/dev/null || echo "")
                if [ "$MAAS_FLAG" = "true" ]; then break; fi
                log_warn "Dashboard config flags overridden by operator — re-applying (attempt $_attempt)..."
                if printf '%s\n%s' "$RHOAI_VER_DASH" "3.5.0" | sort -V | head -1 | grep -q '^3\.5\.0$' && [ "$RHOAI_VER_DASH" != "0.0.0" ]; then
                    oc patch odhdashboardconfig odh-dashboard-config -n "$NAMESPACE" --type=merge -p '{"spec":{"dashboardConfig":{"modelAsService":true}}}' 2>/dev/null || true
                else
                    oc apply -f "$MANIFESTS_DIR/04-rhoai-config/odh-dashboard-config.yaml" 2>/dev/null || true
                fi
            done
        fi
        log_info "Dashboard config applied"
    fi

    # Wait for maas-api (3.4: redhat-ods-applications; 3.5+: redhat-ai-gateway-infra)
    log_step "Waiting for MaaS API deployment"
    if [ "$HAS_MAAS_API" = true ]; then
        log_info "MaaS API/controller already running"
    elif [ "$DRY_RUN" = false ]; then
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            MAAS_DEPLOY=""
            for candidate in "redhat-ai-gateway-infra/maas-api" "$NAMESPACE/maas-api" "$NAMESPACE/maas-controller"; do
                dep_ns="${candidate%%/*}"
                dep_name="${candidate##*/}"
                if oc get deployment "$dep_name" -n "$dep_ns" &>/dev/null; then
                    MAAS_DEPLOY="$candidate"
                    break
                fi
            done
            if [ -n "$MAAS_DEPLOY" ]; then
                dep_ns="${MAAS_DEPLOY%%/*}"
                dep_name="${MAAS_DEPLOY##*/}"
                log_info "MaaS deployment found: ${dep_name} (${dep_ns})"
                oc rollout status deployment/"$dep_name" -n "$dep_ns" --timeout=180s 2>/dev/null || \
                    log_warn "MaaS deployment rollout did not complete within 180s"
                break
            fi
            sleep 10
            ELAPSED=$((ELAPSED + 10))
            if [ $((ELAPSED % 60)) -eq 0 ]; then
                log_info "Still waiting for MaaS API... (${ELAPSED}s)"
            fi
        done
        [ $ELAPSED -ge $TIMEOUT ] && log_warn "MaaS API not found after ${TIMEOUT}s  - operator may still be reconciling"
    fi

    # Verify Tenant CR
    if [ "$DRY_RUN" = false ]; then
        TENANT_READY=$(oc get tenant default-tenant -n models-as-a-service \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$TENANT_READY" = "True" ]; then
            log_info "Tenant CR: Ready"
        else
            log_warn "Tenant CR not Ready yet (status: ${TENANT_READY:-not found})"
        fi
    fi

    # Health check
    if [ "$DRY_RUN" = false ]; then
        HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' \
            "https://maas.${CLUSTER_DOMAIN}/maas-api/health" 2>/dev/null || echo "000")
        if [ "$HTTP_CODE" = "200" ]; then
            log_info "Health endpoint: HTTP 200"
        elif [ "$HTTP_CODE" = "401" ]; then
            log_info "Health endpoint: HTTP 401 (auth working, health may need token)"
        else
            log_warn "Health endpoint: HTTP ${HTTP_CODE} (may need DNS propagation)"
        fi
    fi

    ensure_default_gateway_tls
    ensure_rhoai_gateway_proxy_memory
fi

# =============================================================================
# Phase 5: Deploy Model
# =============================================================================
if should_run 5 && [ "$SKIP_MODELS" = false ]; then
    log_phase 5 "Deploy Model"

    if [ "$HAS_MODELS" = true ]; then
        log_info "LLMInferenceService(s) already deployed (skipping guide model manifests):"
        oc get llminferenceservice -A --no-headers 2>/dev/null | while read -r line; do
            log_info "  $line"
        done
        log_info "Phase 5 only deploys bundled models (simulator, granite-tiny-gpu, gpt-oss-20b)."
        log_info "For custom models: deploy with Publish as MaaS after platform is ready, or see manifests/05-maas-models/README.md"
        log_info "To force a guide model, delete existing LLMInferenceServices first"
    else
        # Auto-detect model
        if [ "$MODEL" = "auto" ]; then
            log_step "Auto-detecting GPU capabilities..."
            GPU_MEMORY=$(oc get nodes -o jsonpath='{.items[*].metadata.labels.nvidia\.com/gpu\.memory}' 2>/dev/null \
                | tr ' ' '\n' | sort -rn | head -1)
            if [ -z "$GPU_MEMORY" ]; then
                MODEL="simulator"
                log_info "No GPU nodes detected -> simulator"
            elif [ "$GPU_MEMORY" -ge 40960 ] 2>/dev/null; then
                MODEL="gpt-oss-20b"
                log_info "GPU VRAM: ${GPU_MEMORY} MiB (>= 40960) -> gpt-oss-20b"
            else
                MODEL="granite-tiny-gpu"
                log_info "GPU VRAM: ${GPU_MEMORY} MiB (< 40960) -> granite-tiny-gpu"
            fi
        fi

        VALID_MODELS="simulator granite-tiny-gpu gpt-oss-20b"
        if ! echo "$VALID_MODELS" | grep -qw "$MODEL"; then
            log_error "Unknown model: $MODEL (valid: $VALID_MODELS)"
            exit 1
        fi

        MODEL_DIR="$MANIFESTS_DIR/05-maas-models/$MODEL"
        if [ ! -d "$MODEL_DIR" ]; then
            log_error "Model directory not found: $MODEL_DIR"
            exit 1
        fi

        log_step "Deploying model: $MODEL"
        if ! oc get namespace llm &>/dev/null; then
            run_cmd oc create namespace llm
        fi
        oc label namespace llm opendatahub.io/generated-namespace=true --overwrite 2>/dev/null || true
        oc label namespace llm maas.opendatahub.io/gateway-access=true --overwrite 2>/dev/null || true
        oc label namespace llm opendatahub.io/dashboard=true --overwrite 2>/dev/null || true
        run_cmd oc apply -k "$MODEL_DIR/"
        log_info "Model manifests applied"

        if [ "$DRY_RUN" = false ]; then
            # Wait for pods
            log_info "Waiting for model pods (up to 10 minutes for GPU models)..."
            TIMEOUT=600
            ELAPSED=0
            XET_PATCHED=false
            while [ $ELAPSED -lt $TIMEOUT ]; do
                POD_COUNT=$(oc get pods -n llm --no-headers 2>/dev/null | wc -l | tr -d ' ')
                if [ "$POD_COUNT" -gt 0 ]; then
                    NOT_READY=$(oc get pods -n llm --no-headers 2>/dev/null \
                        | { grep -v "Running\|Completed" || true; } | wc -l | tr -d ' ')
                    if [ "$NOT_READY" -eq 0 ]; then
                        log_info "All model pods Running"
                        break
                    fi
                    # HuggingFace Xet workaround: if pods stuck in Init for >120s, disable Xet
                    if [ "$XET_PATCHED" = false ] && [ $ELAPSED -ge 120 ]; then
                        INIT_STUCK=$(oc get pods -n llm --no-headers 2>/dev/null | { grep "Init:" || true; } | wc -l | tr -d ' ')
                        if [ "$INIT_STUCK" -gt 0 ]; then
                            log_warn "Pod stuck in Init - applying HF_HUB_DISABLE_XET=1 workaround"
                            for deploy in $(oc get deployment -n llm --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
                                oc patch deployment "$deploy" -n llm --type=json \
                                    -p '[{"op":"add","path":"/spec/template/spec/initContainers/0/env/-","value":{"name":"HF_HUB_DISABLE_XET","value":"1"}}]' 2>/dev/null || true
                            done
                            XET_PATCHED=true
                        fi
                    fi
                fi
                sleep 10
                ELAPSED=$((ELAPSED + 10))
                [ $((ELAPSED % 60)) -eq 0 ] && log_info "  Still waiting... (${ELAPSED}s)"
            done
            [ $ELAPSED -ge $TIMEOUT ] && log_warn "Pods not all Running after ${TIMEOUT}s"

            # Wait for MaaSModelRef
            log_info "Waiting for MaaSModelRef phase=Ready..."
            TIMEOUT=300
            ELAPSED=0
            while [ $ELAPSED -lt $TIMEOUT ]; do
                PHASE=$(oc get maasmodelref -n llm -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
                [ "$PHASE" = "Ready" ] && break
                sleep 10
                ELAPSED=$((ELAPSED + 10))
            done
            if [ "${PHASE:-}" = "Ready" ]; then
                log_info "MaaSModelRef: Ready"
            else
                log_warn "MaaSModelRef not Ready after ${TIMEOUT}s (phase: ${PHASE:-unknown})"
            fi
        fi
    fi
fi

# =============================================================================
# Phase 6: Verify
# =============================================================================
if should_run 6 && [ "$SKIP_VERIFY" = false ]; then
    log_phase 6 "Verify"

    VERIFY_SCRIPT="$MANIFESTS_DIR/06-verification/verify.sh"
    if [ ! -x "$VERIFY_SCRIPT" ]; then
        log_error "Verification script not found or not executable: $VERIFY_SCRIPT"
    elif [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would run: $VERIFY_SCRIPT"
    else
        log_info "Running E2E verification..."
        "$VERIFY_SCRIPT" || log_warn "Verification had failures  - check output above"
    fi
fi

# =============================================================================
# Phase 7: Observability (Optional)
# =============================================================================
if should_run 7 && [ "$WITH_OBSERVABILITY" = true ]; then
    log_phase 7 "Observability"

    # Tempo Operator
    log_step "Installing Tempo Operator..."
    run_cmd oc apply -k "$MANIFESTS_DIR/07-observability/tempo/"
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for Tempo CSV..."
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            TEMPO_PHASE=$(oc get csv -n openshift-tempo-operator --no-headers 2>/dev/null \
                | grep tempo-operator | awk '{print $NF}' || echo "")
            [ "$TEMPO_PHASE" = "Succeeded" ] && break
            sleep 10
            ELAPSED=$((ELAPSED + 10))
        done
        if [ "${TEMPO_PHASE:-}" = "Succeeded" ]; then
            log_info "Tempo CSV: Succeeded"
        else
            log_warn "Tempo CSV not Succeeded after ${TIMEOUT}s"
        fi
    fi

    # Red Hat build of OpenTelemetry Operator
    log_step "Installing Red Hat build of OpenTelemetry Operator..."
    run_cmd oc apply -k "$MANIFESTS_DIR/07-observability/opentelemetry/"
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for OpenTelemetry CSV..."
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            OTEL_PHASE=$(oc get csv -n openshift-opentelemetry-operator --no-headers 2>/dev/null \
                | grep opentelemetry-operator | awk '{print $NF}' || echo "")
            [ "$OTEL_PHASE" = "Succeeded" ] && break
            sleep 10
            ELAPSED=$((ELAPSED + 10))
        done
        if [ "${OTEL_PHASE:-}" = "Succeeded" ]; then
            log_info "OpenTelemetry CSV: Succeeded"
        else
            log_warn "OpenTelemetry CSV not Succeeded after ${TIMEOUT}s"
        fi
    fi

    # COO
    log_step "Installing Cluster Observability Operator..."
    run_cmd oc apply -k "$MANIFESTS_DIR/07-observability/coo/"

    log_info "Approving COO install plan (pinned to v1.4.0, Manual approval)..."
    if [ "$DRY_RUN" = false ]; then
        for attempt in $(seq 1 60); do
            PLAN_NAME=$(oc get subscription cluster-observability-operator \
                -n openshift-cluster-observability-operator \
                -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null || true)
            if [ -n "$PLAN_NAME" ]; then
                APPROVED=$(oc get installplan "$PLAN_NAME" \
                    -n openshift-cluster-observability-operator \
                    -o jsonpath='{.spec.approved}' 2>/dev/null || echo "true")
                if [ "$APPROVED" != "true" ]; then
                    oc patch installplan "$PLAN_NAME" \
                        -n openshift-cluster-observability-operator \
                        --type=merge -p '{"spec":{"approved":true}}' 2>/dev/null || true
                    log_info "  COO install plan $PLAN_NAME approved"
                fi
                break
            fi
            sleep 2
        done
    else
        log_info "[DRY RUN] Would approve COO install plan"
    fi

    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for COO CSV..."
        TIMEOUT=300
        ELAPSED=0
        while [ $ELAPSED -lt $TIMEOUT ]; do
            COO_PHASE=$(oc get csv -n openshift-cluster-observability-operator --no-headers 2>/dev/null \
                | grep cluster-observability | awk '{print $NF}' || echo "")
            [ "$COO_PHASE" = "Succeeded" ] && break
            sleep 10
            ELAPSED=$((ELAPSED + 10))
        done
        if [ "${COO_PHASE:-}" = "Succeeded" ]; then
            log_info "COO CSV: Succeeded"
        else
            log_warn "COO CSV not Succeeded after ${TIMEOUT}s"
        fi
    fi

    # DSCI monitoring config
    log_step "Enabling DSCI monitoring (metrics + traces)..."
    run_cmd oc patch dsci default-dsci --type=merge -p '{
      "spec": {
        "monitoring": {
          "namespace": "redhat-ods-monitoring",
          "metrics": {
            "replicas": 1,
            "storage": {
              "size": "5Gi",
              "retention": "90d"
            }
          },
          "traces": {
            "sampleRatio": "0.1",
            "storage": {
              "backend": "pv",
              "retention": "2160h"
            }
          }
        }
      }
    }'
    if [ "$DRY_RUN" = false ]; then
        log_info "Waiting for DSCI to reconcile..."
        oc wait --for=jsonpath='{.status.phase}'=Ready dsci/default-dsci --timeout=300s 2>/dev/null || \
            log_warn "DSCI did not reach Ready within 300s (monitoring cascade may still be provisioning)"
    fi
    log_info "DSCI monitoring configured"

    # Telemetry
    log_step "Applying Gateway telemetry..."
    run_cmd oc apply -k "$MANIFESTS_DIR/07-observability/telemetry/"
    log_info "Gateway telemetry applied"
fi

# =============================================================================
# Phase 8: External Models (Optional)
# =============================================================================
if should_run 8 && [ "$WITH_EXTERNAL_MODELS" = true ]; then
    log_phase 8 "External Models (provider: ${EXTERNAL_MODEL_PROVIDER})"

    if [ -z "$EXTERNAL_MODEL_API_KEY" ]; then
        log_warn "No external model API key provided (use --external-model-api-key or EXTERNAL_MODEL_API_KEY env var)"
        log_warn "Skipping Phase 8"
    else
        EXTMODEL_NS="external-models"

        case "$EXTERNAL_MODEL_PROVIDER" in
            openai)
                EXTMODEL_NAME="gpt-4o-mini"
                EXTMODEL_SECRET="openai-api-key"
                EXTMODEL_SUBSCRIPTION="openai-free"
                EXTMODEL_TARGET_MODEL="gpt-4o-mini"
                ;;
            gemini)
                EXTMODEL_NAME="gemini-2-5-flash"
                EXTMODEL_SECRET="gemini-api-key"
                EXTMODEL_SUBSCRIPTION="gemini-free"
                EXTMODEL_TARGET_MODEL="gemini-2.5-flash"
                ;;
            bedrock)
                EXTMODEL_NAME="aws-gpt-oss-20b"
                EXTMODEL_SECRET="bedrock-api-key"
                EXTMODEL_SUBSCRIPTION="bedrock-free"
                EXTMODEL_TARGET_MODEL="openai.gpt-oss-20b"
                ;;
            *)
                log_warn "Unknown provider '${EXTERNAL_MODEL_PROVIDER}' (supported: openai, gemini, bedrock)"
                log_warn "Skipping Phase 8"
                EXTERNAL_MODEL_API_KEY=""
                ;;
        esac

        if [ -n "$EXTERNAL_MODEL_API_KEY" ]; then
            PROVIDER_DIR="$MANIFESTS_DIR/08-external-models/${EXTERNAL_MODEL_PROVIDER}"

            if [ ! -d "$PROVIDER_DIR" ]; then
                log_warn "Manifest directory not found: $PROVIDER_DIR"
                log_warn "Skipping Phase 8"
            else
                # Create namespace
                log_step "Creating external-models namespace..."
                if oc get namespace "$EXTMODEL_NS" &>/dev/null; then
                    log_info "Namespace $EXTMODEL_NS already exists"
                else
                    run_cmd oc apply -f "${PROVIDER_DIR}/namespace.yaml"
                fi

                log_step "Creating provider credential Secret..."
                if [ "$DRY_RUN" = true ]; then
                    log_info "[DRY RUN] Would create Secret ${EXTMODEL_SECRET} in $EXTMODEL_NS"
                else
                    oc create secret generic "$EXTMODEL_SECRET" \
                        --from-literal=api-key="$EXTERNAL_MODEL_API_KEY" \
                        -n "$EXTMODEL_NS" \
                        --dry-run=client -o yaml | oc apply -f - 2>/dev/null
                    oc label secret "$EXTMODEL_SECRET" -n "$EXTMODEL_NS" \
                        inference.networking.k8s.io/bbr-managed=true --overwrite 2>/dev/null
                    log_info "Secret ${EXTMODEL_SECRET} created/updated (bbr-managed label applied)"
                fi

                log_step "Applying ExternalModel CR..."
                run_cmd oc apply -k "${PROVIDER_DIR}/model/"

                log_step "Applying MaaS governance (MaaSModelRef, AuthPolicy, Subscription)..."
                run_cmd oc apply -k "${PROVIDER_DIR}/maas/"

                if [ "$DRY_RUN" = false ]; then
                    log_info "Waiting for MaaSModelRef phase=Ready..."
                    TIMEOUT=180
                    ELAPSED=0
                    while [ $ELAPSED -lt $TIMEOUT ]; do
                        MODELREF_PHASE=$(oc get maasmodelref "$EXTMODEL_NAME" -n "$EXTMODEL_NS" \
                            -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                        [ "$MODELREF_PHASE" = "Ready" ] && break
                        sleep 5
                        ELAPSED=$((ELAPSED + 5))
                    done
                    if [ "${MODELREF_PHASE:-}" = "Ready" ]; then
                        log_info "MaaSModelRef: Ready"
                    else
                        log_warn "MaaSModelRef not Ready after ${TIMEOUT}s (phase: ${MODELREF_PHASE:-unknown})"
                    fi

                    MAAS_GW="https://maas.${CLUSTER_DOMAIN}"
                    OC_TOKEN=$(oc whoami -t 2>/dev/null || echo "")
                    if [ -n "$OC_TOKEN" ]; then
                        MODEL_READY=$(curl -sk "${MAAS_GW}/maas-api/v1/models" \
                            -H "Authorization: Bearer ${OC_TOKEN}" 2>/dev/null \
                            | grep -o "\"id\":\"${EXTMODEL_NAME}\"" || echo "")
                        if [ -n "$MODEL_READY" ]; then
                            log_info "Model ${EXTMODEL_NAME} visible in MaaS API (ready)"
                        else
                            log_warn "Model ${EXTMODEL_NAME} not yet visible in MaaS API"
                        fi

                        log_step "Testing ${EXTERNAL_MODEL_PROVIDER} inference through MaaS gateway..."
                        log_info "Creating ephemeral API key for testing..."
                        API_KEY_RESPONSE=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
                            -H "Authorization: Bearer ${OC_TOKEN}" \
                            -H "Content-Type: application/json" \
                            -d "{\"name\": \"phase8-test\", \"subscription\": \"${EXTMODEL_SUBSCRIPTION}\", \"expiresIn\": \"1h\", \"ephemeral\": true}" 2>/dev/null || echo "")

                        TEST_API_KEY=$(echo "$API_KEY_RESPONSE" | grep -o '"key":"[^"]*"' | head -1 | cut -d'"' -f4)

                        if [ -n "$TEST_API_KEY" ]; then
                            log_info "Ephemeral API key created"

                            INFERENCE_RESPONSE=$(curl -sk -X POST \
                                "${MAAS_GW}/external-models/${EXTMODEL_NAME}/v1/chat/completions" \
                                -H "Authorization: Bearer ${TEST_API_KEY}" \
                                -H "Content-Type: application/json" \
                                -d "{\"model\": \"${EXTMODEL_TARGET_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Say hello in exactly 3 words.\"}], \"max_tokens\": 20}" \
                                --max-time 30 2>/dev/null || echo "")

                            if echo "$INFERENCE_RESPONSE" | grep -q '"choices"'; then
                                REPLY_TEXT=$(echo "$INFERENCE_RESPONSE" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
                                log_info "${EXTERNAL_MODEL_PROVIDER} inference SUCCESS: ${REPLY_TEXT}"
                            else
                                HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' -X POST \
                                    "${MAAS_GW}/external-models/${EXTMODEL_NAME}/v1/chat/completions" \
                                    -H "Authorization: Bearer ${TEST_API_KEY}" \
                                    -H "Content-Type: application/json" \
                                    -d "{\"model\": \"${EXTMODEL_TARGET_MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hi\"}], \"max_tokens\": 5}" \
                                    --max-time 15 2>/dev/null || echo "000")
                                log_warn "${EXTERNAL_MODEL_PROVIDER} inference returned HTTP ${HTTP_CODE} - model is registered and governed but inference routing may need BBR ext-proc propagation"
                            fi

                            TEST_KEY_ID=$(echo "$API_KEY_RESPONSE" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
                            if [ -n "$TEST_KEY_ID" ]; then
                                curl -sk -X DELETE "${MAAS_GW}/maas-api/v1/api-keys/${TEST_KEY_ID}" \
                                    -H "Authorization: Bearer ${OC_TOKEN}" &>/dev/null || true
                            fi
                        else
                            log_warn "Could not create API key for testing (response: $(echo "$API_KEY_RESPONSE" | head -c 200))"
                        fi
                    else
                        log_warn "No OC token available - skipping API verification"
                    fi
                fi

                log_info "External models deployment complete (provider: ${EXTERNAL_MODEL_PROVIDER})"
            fi
        fi
    fi
fi

# =============================================================================
# Phase 9: LiteMaaS + LiteLLM (Optional)
# =============================================================================
if should_run 9 && [ "$WITH_LITEMAAS" = true ]; then
    log_phase 9 "LiteMaaS + LiteLLM (PoC GUI)"

    if ! require_sibling_repo "LiteMaaS (litemaas-rhoai)" "$LITEMAAS_RHOAI_DIR" \
        "scripts/install.sh" "LITEMAAS_RHOAI_DIR" \
        "litemaas-rhoai (local clone next to this guide)"; then
        log_error "Aborting Phase 9"
        exit 1
    fi

    log_step "Installing LiteMaaS into namespace litemaas..."
    log_info "Using: $LITEMAAS_RHOAI_DIR"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would run: $LITEMAAS_RHOAI_DIR/scripts/install.sh"
    else
        (
            cd "$LITEMAAS_RHOAI_DIR"
            ./scripts/install.sh
        )
        log_info "LiteMaaS Helm install finished"

        if [ -n "$MAAS_API_KEY" ]; then
            log_step "Wiring LiteLLM backends to MaaS gateway (MAAS_API_KEY set)..."
            export MAAS_API_KEY
            export MAAS_GATEWAY="https://maas.${CLUSTER_DOMAIN}"
            (
                cd "$LITEMAAS_RHOAI_DIR"
                ./scripts/wire-maas-models.sh --discover-cluster --api-key "$MAAS_API_KEY" --all \
                    || log_warn "wire-maas-models.sh reported issues — register backends manually later"
            )
        else
            log_warn "MAAS_API_KEY not set — skipping LiteLLM model wire"
            log_info "  After creating a MaaS API key:"
            log_info "  export MAAS_API_KEY=... MAAS_GATEWAY=https://maas.${CLUSTER_DOMAIN}"
            log_info "  (cd $LITEMAAS_RHOAI_DIR && ./scripts/wire-maas-models.sh --discover-cluster --api-key \"\$MAAS_API_KEY\" --all)"
        fi

        if [ -x "$SCRIPT_DIR/verify-guis.sh" ] || [ -f "$SCRIPT_DIR/verify-guis.sh" ]; then
            "$SCRIPT_DIR/verify-guis.sh" --litemaas || log_warn "LiteMaaS soft verify had warnings"
        fi
    fi
fi

# =============================================================================
# Phase 10: Compact MaaS (Optional)
# =============================================================================
if should_run 10 && [ "$WITH_COMPACT_MAAS" = true ]; then
    log_phase 10 "Compact MaaS (native UX, no LiteLLM)"

    if ! require_sibling_repo "Compact MaaS (compact-maas)" "$COMPACT_MAAS_DIR" \
        "scripts/deploy.sh" "COMPACT_MAAS_DIR" \
        "compact-maas (or legacy rhoai-maas-console) next to this guide"; then
        log_error "Aborting Phase 10"
        exit 1
    fi

    MAAS_GW_URL="https://maas.${CLUSTER_DOMAIN}"
    log_step "Applying Phase 2 RBAC (maas-admins)..."
    log_info "Using: $COMPACT_MAAS_DIR"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would run apply-phase2-rbac.sh and deploy.sh with MAAS_GATEWAY_URL=$MAAS_GW_URL"
    else
        if [ -f "$COMPACT_MAAS_DIR/scripts/apply-phase2-rbac.sh" ]; then
            (
                cd "$COMPACT_MAAS_DIR"
                ./scripts/apply-phase2-rbac.sh
            ) || log_warn "apply-phase2-rbac.sh had warnings — continuing deploy"
        else
            log_warn "apply-phase2-rbac.sh not found — skipping RBAC apply"
        fi

        log_step "Deploying Compact MaaS (builds + Helm)..."
        (
            cd "$COMPACT_MAAS_DIR"
            export CLUSTER_DOMAIN
            export MAAS_GATEWAY_URL="$MAAS_GW_URL"
            if [ "${COMPACT_MAAS_SKIP_BUILD:-false}" = true ]; then
                export SKIP_BUILDS=1
                ./scripts/deploy.sh --helm-only
            else
                ./scripts/deploy.sh
            fi
        )

        if [ -x "$SCRIPT_DIR/fix-compact-maas-config.sh" ] || [ -f "$SCRIPT_DIR/fix-compact-maas-config.sh" ]; then
            if ! COMPACT_MAAS_DIR="$COMPACT_MAAS_DIR" "$SCRIPT_DIR/fix-compact-maas-config.sh" 2>/dev/null; then
                log_step "Re-applying OAuth / gateway / enrollment URLs..."
                COMPACT_MAAS_DIR="$COMPACT_MAAS_DIR" "$SCRIPT_DIR/fix-compact-maas-config.sh" --apply-fix \
                    || log_warn "Compact MaaS config repair failed — login may redirect to wrong oauth-openshift host"
            fi
        fi

        if [ -x "$SCRIPT_DIR/fix-compact-maas-native-maas.sh" ] || [ -f "$SCRIPT_DIR/fix-compact-maas-native-maas.sh" ]; then
            if ! COMPACT_MAAS_DIR="$COMPACT_MAAS_DIR" "$SCRIPT_DIR/fix-compact-maas-native-maas.sh" 2>/dev/null; then
                log_step "Re-applying BBR anchor with maas-api bypass..."
                COMPACT_MAAS_DIR="$COMPACT_MAAS_DIR" "$SCRIPT_DIR/fix-compact-maas-native-maas.sh" --apply-fix \
                    || log_warn "BBR anchor repair failed — ExternalModel chat or key mint may be broken"
            fi
        fi

        if [ -x "$SCRIPT_DIR/verify-guis.sh" ] || [ -f "$SCRIPT_DIR/verify-guis.sh" ]; then
            "$SCRIPT_DIR/verify-guis.sh" --compact-maas || log_warn "Compact MaaS verify failed (see fix-compact-maas-native-maas.sh)"
        fi
    fi
fi

# =============================================================================
# Phase 11: Lago billing (Optional)
# =============================================================================
if should_run 11 && [ "$WITH_LAGO_BILLING" = true ]; then
    log_phase 11 "Lago billing (budget entities + graduated throttling)"

    if [ "$DRY_RUN" = false ]; then
        maas_billing_require_backend lago || exit 1
    else
        detected="$(maas_billing_backend_detected)"
        if [[ "$detected" == "openmeter" || "$detected" == "conflict" ]]; then
            log_warn "[DRY RUN] Would abort: OpenMeter billing already installed (detected: ${detected})"
        fi
    fi

    if ! maas_gateway_telemetry_ready; then
        log_step "Gateway telemetry not found — installing Phase 7 observability (required for usage-reporter)..."
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] Would run: $SCRIPT_DIR/setup-maas.sh --from-phase 7 --with-observability --skip-models --skip-verify"
        else
            "$SCRIPT_DIR/setup-maas.sh" --from-phase 7 --with-observability --skip-models --skip-verify || {
                log_error "Phase 7 observability install failed — cannot continue Phase 11"
                exit 1
            }
        fi
    else
        log_info "Gateway telemetry (TelemetryPolicy/maas-telemetry) already present"
    fi

    if [ "$SKIP_LAGO_PLATFORM" = true ]; then
        log_info "Skipping Lago Helm install (--skip-lago-platform)"
    elif [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would run: $SCRIPT_DIR/install-lago-platform.sh"
    else
        log_step "Installing Lago platform (Helm)..."
        CLUSTER_DOMAIN="$CLUSTER_DOMAIN" "$SCRIPT_DIR/install-lago-platform.sh" || \
            log_warn "Lago Helm install had warnings — maas-billing base will still be applied"
    fi

    log_step "Applying MaaS billing base (namespace, tier templates, RBAC)..."
    run_cmd oc apply -k "$MANIFESTS_DIR/11-lago/base/"

    if [ -f "$MANIFESTS_DIR/11-lago/maas-billing-api/kustomization.yaml" ]; then
        log_step "Applying maas-billing-api manifests..."
        run_cmd oc apply -k "$MANIFESTS_DIR/11-lago/maas-billing-api/"
        if [ "$DRY_RUN" = false ] && [ -x "$SCRIPT_DIR/build-maas-billing-image.sh" ]; then
            log_step "Building maas-billing container image (OpenShift binary build)..."
            "$SCRIPT_DIR/build-maas-billing-image.sh" || log_warn "maas-billing image build failed — retry: ./scripts/build-maas-billing-image.sh"
        fi
        if [ "$DRY_RUN" = false ] && [ -x "$SCRIPT_DIR/install-lago-catalog.sh" ] && [ "$SKIP_LAGO_PLATFORM" != true ]; then
            if ! oc get secret maas-billing-secrets -n maas-billing &>/dev/null; then
                log_warn "Secret maas-billing-secrets missing — create after Lago UI API key:"
                log_warn "  oc create secret generic maas-billing-secrets -n maas-billing --from-literal=LAGO_API_KEY=<key>"
            else
                log_step "Bootstrapping Lago billable metric + plan..."
                "$SCRIPT_DIR/install-lago-catalog.sh" || log_warn "Lago catalog bootstrap had warnings — see docs/11-lago-billing.md"
            fi
        fi
    fi

    for component in usage-reporter budget-enforcer enrollment-ui; do
        if [ -f "$MANIFESTS_DIR/11-lago/${component}/kustomization.yaml" ]; then
            log_step "Applying ${component}..."
            run_cmd oc apply -k "$MANIFESTS_DIR/11-lago/${component}/"
        fi
    done

    if [ -x "$SCRIPT_DIR/verify-lago.sh" ] || [ -f "$SCRIPT_DIR/verify-lago.sh" ]; then
        if [ "$DRY_RUN" = false ]; then
            "$SCRIPT_DIR/verify-lago.sh" || log_warn "Lago billing soft verify had warnings"
        fi
    fi

    log_info "Phase 11 applied. Set LAGO_API_KEY in maas-billing-secrets, enroll entities via maas-billing-api (see docs/11-lago-billing.md)"
fi

# =============================================================================
# Phase 12: OpenMeter billing (Optional)
# =============================================================================
if should_run 12 && [ "$WITH_OPENMETER_BILLING" = true ]; then
    log_phase 12 "OpenMeter billing (budget entities + graduated throttling)"

    if [ "$DRY_RUN" = false ]; then
        maas_billing_require_backend openmeter || exit 1
    else
        detected="$(maas_billing_backend_detected)"
        if [[ "$detected" == "lago" || "$detected" == "conflict" ]]; then
            log_warn "[DRY RUN] Would abort: Lago billing already installed (detected: ${detected})"
        fi
    fi

    if ! maas_gateway_telemetry_ready; then
        log_step "Gateway telemetry not found — installing Phase 7 observability (required for usage-reporter)..."
        if [ "$DRY_RUN" = true ]; then
            log_info "[DRY RUN] Would run: $SCRIPT_DIR/setup-maas.sh --from-phase 7 --with-observability --skip-models --skip-verify"
        else
            "$SCRIPT_DIR/setup-maas.sh" --from-phase 7 --with-observability --skip-models --skip-verify || {
                log_error "Phase 7 observability install failed — cannot continue Phase 12"
                exit 1
            }
        fi
    else
        log_info "Gateway telemetry (TelemetryPolicy/maas-telemetry) already present"
    fi

    if [ "$SKIP_OPENMETER_PLATFORM" = true ]; then
        log_info "Skipping OpenMeter Helm install (--skip-openmeter-platform)"
    elif [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would run: $SCRIPT_DIR/install-openmeter-platform.sh"
    else
        log_step "Installing OpenMeter platform (Helm)..."
        CLUSTER_DOMAIN="$CLUSTER_DOMAIN" "$SCRIPT_DIR/install-openmeter-platform.sh" || \
            log_warn "OpenMeter Helm install had warnings — maas-billing base will still be applied"
    fi

    log_step "Applying MaaS billing base (namespace, tier templates, RBAC)..."
    run_cmd oc apply -k "$MANIFESTS_DIR/12-openmeter/base/"

    if [ -f "$MANIFESTS_DIR/12-openmeter/maas-billing-api/kustomization.yaml" ]; then
        log_step "Applying maas-billing-api manifests..."
        run_cmd oc apply -k "$MANIFESTS_DIR/12-openmeter/maas-billing-api/"
        if [ "$DRY_RUN" = false ] && [ -x "$SCRIPT_DIR/build-maas-billing-image.sh" ]; then
            log_step "Building maas-billing container image (shared with Phase 11)..."
            MAAS_BILLING_SRC="${MAAS_BILLING_SRC:-$MANIFESTS_DIR/11-lago/maas-billing}" \
                "$SCRIPT_DIR/build-maas-billing-image.sh" || \
                log_warn "maas-billing image build failed — retry: ./scripts/build-maas-billing-image.sh"
        fi
        if [ "$DRY_RUN" = false ] && [ -x "$SCRIPT_DIR/install-openmeter-catalog.sh" ] && [ "$SKIP_OPENMETER_PLATFORM" != true ]; then
            log_step "Bootstrapping OpenMeter meter + feature..."
            "$SCRIPT_DIR/install-openmeter-catalog.sh" || log_warn "OpenMeter catalog bootstrap had warnings — see docs/12-openmeter-billing.md"
            if [ -x "$SCRIPT_DIR/install-openmeter-demo-entity.sh" ]; then
                log_step "Ensuring demo budget entity (admin)..."
                "$SCRIPT_DIR/install-openmeter-demo-entity.sh" || log_warn "Demo entity enrollment had warnings"
            fi
        fi
    fi

    for component in usage-reporter budget-enforcer enrollment-ui; do
        if [ -f "$MANIFESTS_DIR/12-openmeter/${component}/kustomization.yaml" ]; then
            log_step "Applying ${component}..."
            run_cmd oc apply -k "$MANIFESTS_DIR/12-openmeter/${component}/"
        fi
    done

    if [ -x "$SCRIPT_DIR/verify-openmeter.sh" ] || [ -f "$SCRIPT_DIR/verify-openmeter.sh" ]; then
        if [ "$DRY_RUN" = false ]; then
            "$SCRIPT_DIR/verify-openmeter.sh" || log_warn "OpenMeter billing soft verify had warnings"
        fi
    fi

    log_info "Phase 12 applied. Enroll entities via maas-billing-api (see docs/12-openmeter-billing.md)"
fi

# =============================================================================
# Final Summary
# =============================================================================
echo ""
log_phase "" "Summary"

MAAS_URL="https://maas.${CLUSTER_DOMAIN}"

if [ "$DRY_RUN" = true ]; then
    log_info "MaaS API URL:  ${MAAS_URL}"
    log_info "Status:        DRY RUN  - no changes applied"
else
    # Gather final state
    RHOAI_VERSION=$(oc get csv -n redhat-ods-operator -l operators.coreos.com/rhods-operator.redhat-ods-operator= -o jsonpath='{.items[0].spec.version}' 2>/dev/null || echo "unknown")
    GW_STATUS=$(oc get gateway maas-default-gateway -n openshift-ingress \
        -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "Unknown")
    API_READY=$(oc get deployment maas-api -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    HEALTH=$(curl -sk -o /dev/null -w '%{http_code}' "${MAAS_URL}/maas-api/health" 2>/dev/null || echo "000")

    log_info "RHOAI version: ${RHOAI_VERSION}"
    log_info "MaaS API URL:  ${MAAS_URL}"
    log_info "Gateway:       Programmed=${GW_STATUS}"
    log_info "maas-api:      ${API_READY} replica(s)"
    log_info "Health:        HTTP ${HEALTH}"

    if [ "$SKIP_MODELS" = false ] && { [ "$HAS_MODELS" = true ] || oc get llminferenceservice -A --no-headers 2>/dev/null | grep -q .; }; then
        log_info "Models (local):"
        oc get llminferenceservice -A --no-headers 2>/dev/null | while read -r line; do
            log_info "  $line"
        done
    fi

    if oc get externalmodel -n external-models &>/dev/null 2>&1; then
        log_info "Models (external):"
        oc get externalmodel -n external-models --no-headers 2>/dev/null | while read -r line; do
            log_info "  $line"
        done
    fi

    if [ "$WITH_LITEMAAS" = true ] || oc get ns litemaas &>/dev/null; then
        LITE_HOST=$(oc get route -n litemaas -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -E '^litemaas\.' | head -1 || true)
        [ -n "$LITE_HOST" ] && log_info "LiteMaaS UI:   https://${LITE_HOST}"
    fi
    if [ "$WITH_COMPACT_MAAS" = true ] || oc get ns compact-maas &>/dev/null; then
        COMPACT_HOST=$(oc -n compact-maas get route compact-maas -o jsonpath='{.spec.host}' 2>/dev/null || true)
        [ -n "$COMPACT_HOST" ] && log_info "Compact MaaS:  https://${COMPACT_HOST}"
    fi
    if [ "$WITH_OPENMETER_BILLING" = true ] || { oc get configmap maas-billing-config -n maas-billing -o jsonpath='{.data.BILLING_BACKEND}' 2>/dev/null | grep -q openmeter; }; then
        OM_HOST=$(oc -n openmeter get route openmeter -o jsonpath='{.spec.host}' 2>/dev/null || true)
        [ -n "$OM_HOST" ] && log_info "OpenMeter API: https://${OM_HOST}"
        BILLING_HOST=$(oc -n maas-billing get route maas-billing-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
        [ -n "$BILLING_HOST" ] && log_info "Billing API:   https://${BILLING_HOST}"
    elif [ "$WITH_LAGO_BILLING" = true ] || oc get ns maas-billing &>/dev/null; then
        LAGO_HOST=$(oc -n lago get route lago-front -o jsonpath='{.spec.host}' 2>/dev/null || true)
        [ -n "$LAGO_HOST" ] && log_info "Lago UI:       https://${LAGO_HOST}"
        LAGO_API=$(oc -n lago get route lago-api -o jsonpath='{.spec.host}' 2>/dev/null || true)
        [ -n "$LAGO_API" ] && log_info "Lago API:      https://${LAGO_API}"
    fi

    echo ""
    log_info "Next steps:"
    [ "$SKIP_MODELS" = true ] && log_info "  Deploy models:      ./scripts/deploy-model.sh --model auto"
    [ "$SKIP_VERIFY" = true ] && log_info "  Run verification:   ./scripts/verify-maas.sh"
    [ "$WITH_OBSERVABILITY" = false ] && log_info "  Add observability:  $0 --from-phase 7 --with-observability"
    [ "$WITH_EXTERNAL_MODELS" = false ] && log_info "  Add external models: $0 --from-phase 8 --with-external-models --external-model-provider openai --external-model-api-key <KEY>"
    [ "$WITH_LITEMAAS" = false ] && log_info "  Add LiteMaaS GUI:    $0 --from-phase 9 --with-litemaas"
    [ "$WITH_COMPACT_MAAS" = false ] && log_info "  Add Compact MaaS:    $0 --from-phase 10 --with-compact-maas"
    [ "$WITH_LAGO_BILLING" = false ] && [ "$WITH_OPENMETER_BILLING" = false ] && log_info "  Add Lago billing:       $0 --from-phase 11 --with-lago-billing"
    [ "$WITH_OPENMETER_BILLING" = false ] && log_info "  Add OpenMeter billing:  $0 --from-phase 12 --with-openmeter-billing"
    log_info "  RHOAI Dashboard:    https://$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || echo '<dashboard-route>')"
fi

echo ""
log_info "Done."
