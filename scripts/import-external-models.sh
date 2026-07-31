#!/usr/bin/env bash
#
# import-external-models.sh - Bulk-register external OpenAI-compatible models
# as MaaS cluster resources, without using the Compact MaaS Admin GUI.
#
# Discovers models via `GET {endpoint}{path-prefix}/v1/models` (Bearer auth)
# and, for each selected id, creates the same resources Compact MaaS Admin's
# "Create ExternalModel" form would:
#   1. A shared credential Secret (labels: bbr-managed + ipp-managed)
#   2. ExternalModel                (spec.provider / targetModel / endpoint)
#   3. MaaSModelRef                 (catalog entry)
#   4. MaaSAuthPolicy + MaaSSubscription (open system:authenticated tier,
#      unless --skip-governance or --restricted)
#   5. HTTPRoute URLRewrite heal    (/<namespace>/<name> -> path-prefix or /)
#
# Idempotent: every mutation is `oc apply` (or an idempotent PATCH for the
# HTTPRoute), so re-running is safe.
#
# Usage:
#   ./scripts/import-external-models.sh --endpoint api.openai.com \
#       --api-key "$OPENAI_API_KEY" --all
#
#   ./scripts/import-external-models.sh --endpoint us-east.rhai.ibm.com \
#       --path-prefix /v1/projects/<uuid>/inference \
#       --api-key "$RHAI_API_KEY" --namespace llm \
#       --models granite-4-0-h-small,granite-4-0-h-tiny
#
# See --help for the full option list.
#

set -euo pipefail

# Colors (match setup-maas.sh / deploy-model.sh conventions)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# All log helpers write to stderr: several functions below (discover_models,
# apply_or_preview, etc.) are captured via $(...) on stdout, and log noise
# mixed into that capture would corrupt JSON/YAML parsing.
log_info()  { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_head()  { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}" >&2; }

# Every cluster mutation below is an idempotent oc apply/patch, so Ctrl+C at
# any point (e.g. during a slow HTTPRoute heal) is always safe to do — just
# say so on the way out instead of leaving the user guessing.
on_interrupt() {
    echo "" >&2
    log_warn "Interrupted. Re-running the same command is safe — every step is idempotent (oc apply/patch)."
    exit 130
}
trap on_interrupt INT TERM

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
ENDPOINT_RAW=""
API_KEY="${EXTERNAL_MODEL_API_KEY:-}"
PATH_PREFIX=""
NAMESPACE="external-models"
GOVERNANCE_NAMESPACE="models-as-a-service"
PROVIDER="openai"
FILTER=""
MODELS_ALLOWLIST=""
SELECT_ALL=false
LIST_ONLY=false
SECRET_NAME=""
NAME_PREFIX=""
SKIP_GOVERNANCE=false
RESTRICTED=false
TOKEN_LIMIT=10000
TOKEN_WINDOW="1h"
SKIP_NAMESPACE=false
SKIP_ROUTE_HEAL=false
WAIT_READY=true
INSECURE=false
DRY_RUN=false

KNOWN_PROVIDERS="openai anthropic azure-openai vertex bedrock-openai"

usage() {
    cat <<'EOF'
Usage: import-external-models.sh --endpoint <fqdn-or-url> --api-key <key> [OPTIONS]

Discover models from an external OpenAI-compatible endpoint (GET /v1/models)
and register them on the cluster as MaaS ExternalModel + MaaSModelRef (+
optional governance), matching what Compact MaaS Admin's ExternalModel
"Create" form provisions. No GUI required.

Required:
  --endpoint <fqdn-or-url>   Provider host, e.g. api.openai.com, or a full URL
                             (e.g. https://us-east.rhai.ibm.com/v1/projects/<uuid>/inference).
                             A path embedded in the URL is used as --path-prefix
                             unless --path-prefix is also given.
                             IMPORTANT: if the base URL already ends in /v1, pass the
                             host only (no /v1) — the script always appends /v1/models
                             itself, so host+/v1 would query .../v1/v1/models.
  --api-key <key>            Provider (or remote MaaS gateway) API key
                             (or set EXTERNAL_MODEL_API_KEY)

Discovery / selection:
  --path-prefix <path>       Upstream base path (e.g. /v1/projects/<uuid>/inference).
                             Must start with /, no trailing slash. Default: none (OpenAI root).
  --list                     Discover and print model ids, then exit (no cluster changes).
  --all                      Register every discovered model.
  --models <id1,id2,...>     Comma-separated allowlist of model ids to register.
                             Ids not present in the discovery response are still
                             accepted (warns) so hidden/undocumented ids work too.
  --filter <regex>           Only consider discovered ids matching this extended regex
                             (narrows the list before --all / --models / interactive select).
  -k, --insecure             Skip TLS verification on the discovery GET request.

Without --all / --models, and when running in a terminal, you will be prompted
to pick models interactively from the numbered discovery list.

Cluster resources:
  --provider <name>          ExternalModel BBR provider translator (default: openai).
                             Known: openai, anthropic, azure-openai, vertex, bedrock-openai
  --namespace <ns>           Namespace for ExternalModel/MaaSModelRef (default: external-models).
                             Use "llm" to match the Compact MaaS default namespace.
  --secret-name <name>       Shared credential Secret name (default: derived from
                             --endpoint, e.g. api-openai-com-credentials). One secret
                             is created/reused for every model registered in this run.
  --name-prefix <prefix>     Prefix added to sanitized k8s resource names.
  --skip-namespace           Do not create/check the target namespace.
  --skip-route-heal          Do not patch the HTTPRoute URLRewrite filter.
  --no-wait                  Do not wait for MaaSModelRef to reach phase=Ready.

Note on HTTPRoute healing: the MaaS controller creates each model's HTTPRoute
asynchronously, so healing polls for up to ~90s. If it never appears/settles in
time for a given model, that model is skipped with a warning and the script
moves on — it does not abort --all/--models. Re-running the same command later
is always safe (every mutation is an idempotent oc apply/patch); pass --models
with just the remaining ids to retry a subset.

Governance (MaaSAuthPolicy + MaaSSubscription):
  --skip-governance          Only create Secret + ExternalModel + MaaSModelRef.
                             Create AuthPolicy/Subscription (or a private Subscription)
                             separately via Admin or YAML.
  --governance-namespace <ns> Namespace for AuthPolicy/Subscription (default: models-as-a-service).
  --restricted                Create AuthPolicy/Subscription with empty subjects/owner
                              (no system:authenticated) — enroll groups/users afterward.
  --token-limit <n>           Subscription token rate limit (default: 10000).
  --token-window <window>     Subscription token rate window (default: 1h).

General:
  --dry-run                  Print discovered models and every manifest that would be
                              applied; makes no cluster changes (still performs the
                              discovery GET against the endpoint).
  -h, --help                  Show this help message.

Examples:
  # Stock OpenAI, register every model, default governance
  ./scripts/import-external-models.sh --endpoint api.openai.com \
      --api-key "$OPENAI_API_KEY" --all

  # IBM RHAI / project-prefixed host, pick specific models, Compact MaaS namespace
  ./scripts/import-external-models.sh \
      --endpoint us-east.rhai.ibm.com \
      --path-prefix /v1/projects/002d4a39-9d40-4c25-a9fa-a603eebdb574/inference \
      --api-key "$RHAI_API_KEY" --namespace llm \
      --models granite-4-0-h-small,granite-4-0-h-tiny

  # Just see what's there, no changes
  ./scripts/import-external-models.sh --endpoint api.openai.com \
      --api-key "$OPENAI_API_KEY" --list

  # Preview everything (manifests only) without touching the cluster
  ./scripts/import-external-models.sh --endpoint api.openai.com \
      --api-key "$OPENAI_API_KEY" --all --dry-run
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --endpoint)             ENDPOINT_RAW="$2"; shift 2 ;;
        --api-key)              API_KEY="$2"; shift 2 ;;
        --path-prefix)          PATH_PREFIX="$2"; shift 2 ;;
        --namespace)            NAMESPACE="$2"; shift 2 ;;
        --provider)             PROVIDER="$2"; shift 2 ;;
        --filter)               FILTER="$2"; shift 2 ;;
        --models)               MODELS_ALLOWLIST="$2"; shift 2 ;;
        --all)                  SELECT_ALL=true; shift ;;
        --list)                 LIST_ONLY=true; shift ;;
        --secret-name)          SECRET_NAME="$2"; shift 2 ;;
        --name-prefix)          NAME_PREFIX="$2"; shift 2 ;;
        --skip-governance)      SKIP_GOVERNANCE=true; shift ;;
        --governance-namespace) GOVERNANCE_NAMESPACE="$2"; shift 2 ;;
        --restricted)           RESTRICTED=true; shift ;;
        --token-limit)          TOKEN_LIMIT="$2"; shift 2 ;;
        --token-window)         TOKEN_WINDOW="$2"; shift 2 ;;
        --skip-namespace)       SKIP_NAMESPACE=true; shift ;;
        --skip-route-heal)      SKIP_ROUTE_HEAL=true; shift ;;
        --no-wait)              WAIT_READY=false; shift ;;
        -k|--insecure)          INSECURE=true; shift ;;
        --dry-run)               DRY_RUN=true; shift ;;
        -h|--help)               usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Validation helpers
# -----------------------------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { log_error "Required command not found: $1"; exit 1; }
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

normalize_endpoint() {
    local raw
    raw="$(trim "$1")"
    SCHEME="https"
    local rest="$raw"
    if [[ "$rest" == https://* ]]; then
        SCHEME="https"; rest="${rest#https://}"
    elif [[ "$rest" == http://* ]]; then
        SCHEME="http"; rest="${rest#http://}"
    fi
    rest="${rest%/}"
    if [[ "$rest" == */* ]]; then
        ENDPOINT="${rest%%/*}"
        EMBEDDED_PATH="/${rest#*/}"
    else
        ENDPOINT="$rest"
        EMBEDDED_PATH=""
    fi
}

normalize_path_prefix() {
    local p
    p="$(trim "$1")"
    if [ -z "$p" ] || [ "$p" = "/" ]; then
        printf ''
        return 0
    fi
    case "$p" in
        /*) ;;
        *)
            log_error "--path-prefix must start with / (e.g. /v1/projects/<id>/inference)"
            exit 1
            ;;
    esac
    if printf '%s' "$p" | grep -Eq '://|^//|[?# ]'; then
        log_error "--path-prefix must be a URL path only — no scheme, host, query, or fragment"
        exit 1
    fi
    printf '%s' "$p" | sed -E 's:/+$::'
}

sanitize_name() {
    local raw="$1" s
    s=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    s=$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')
    [ -n "$NAME_PREFIX" ] && s="${NAME_PREFIX}-${s}"
    if [ ${#s} -gt 63 ]; then
        s="${s:0:63}"
        s=$(printf '%s' "$s" | sed -E 's/-+$//')
    fi
    [ -z "$s" ] && s="model"
    printf '%s' "$s"
}

USED_NAMES=()
name_taken() {
    local n="$1" u
    for u in "${USED_NAMES[@]:-}"; do
        [ "$u" = "$n" ] && return 0
    done
    return 1
}


# Sets global UNIQUE_NAME and appends to global USED_NAMES. Must be called
# directly (not via $(...)) since command substitution forks a subshell and
# would silently discard the USED_NAMES append, breaking de-duplication.
UNIQUE_NAME=""
unique_name() {
    local base suffix candidate
    base="$(sanitize_name "$1")"
    candidate="$base"
    suffix=2
    while name_taken "$candidate"; do
        candidate="${base:0:59}-${suffix}"
        suffix=$((suffix + 1))
    done
    USED_NAMES+=("$candidate")
    UNIQUE_NAME="$candidate"
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
if [ -z "$ENDPOINT_RAW" ]; then
    log_error "--endpoint is required"
    usage
    exit 1
fi
if [ -z "$API_KEY" ]; then
    log_error "--api-key is required (or set EXTERNAL_MODEL_API_KEY)"
    exit 1
fi

require_cmd curl
require_cmd python3
if [ "$DRY_RUN" = false ] && [ "$LIST_ONLY" = false ]; then
    require_cmd oc
fi

normalize_endpoint "$ENDPOINT_RAW"

if [ -n "$EMBEDDED_PATH" ]; then
    if [ -n "$PATH_PREFIX" ] && [ "$(trim "$PATH_PREFIX")" != "$EMBEDDED_PATH" ]; then
        log_warn "Both a path in --endpoint ('${EMBEDDED_PATH}') and --path-prefix ('${PATH_PREFIX}') were given; using --path-prefix."
    elif [ -z "$PATH_PREFIX" ]; then
        PATH_PREFIX="$EMBEDDED_PATH"
        log_info "Detected upstream path prefix from --endpoint: ${PATH_PREFIX}"
    fi
fi
PATH_PREFIX="$(normalize_path_prefix "$PATH_PREFIX")"

if [[ "$ENDPOINT" == *" "* ]] || [ -z "$ENDPOINT" ]; then
    log_error "Invalid --endpoint '${ENDPOINT_RAW}' — expected an FQDN (e.g. api.openai.com), not empty/whitespace"
    exit 1
fi
if [[ "$ENDPOINT" == *:* ]]; then
    log_warn "--endpoint '${ENDPOINT}' contains a port — ExternalModel.spec.endpoint does not support ports on a real cluster (this is fine for local --dry-run testing)."
fi

if ! printf '%s' " $KNOWN_PROVIDERS " | grep -q " ${PROVIDER} "; then
    log_warn "Provider '${PROVIDER}' is not in the known BBR translator list (${KNOWN_PROVIDERS}). Continuing anyway."
fi

BASE_URL="${SCHEME}://${ENDPOINT}${PATH_PREFIX}"

if [ -z "$SECRET_NAME" ]; then
    slug=$(printf '%s' "$ENDPOINT" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')
    SECRET_NAME="${slug}-credentials"
fi

log_head "Configuration"
log_info "Endpoint base:        ${BASE_URL}"
log_info "Provider:             ${PROVIDER}"
log_info "Namespace:            ${NAMESPACE}"
[ "$SKIP_GOVERNANCE" = false ] && log_info "Governance namespace: ${GOVERNANCE_NAMESPACE} ($( [ "$RESTRICTED" = true ] && echo "restricted" || echo "open: system:authenticated" ))"
log_info "Credential Secret:    ${SECRET_NAME}"
[ "$DRY_RUN" = true ] && log_warn "DRY RUN — no cluster changes will be made"

# -----------------------------------------------------------------------------
# Discovery
# -----------------------------------------------------------------------------
discover_models() {
    local url="${BASE_URL}/v1/models"
    log_step "Discovering models: GET ${url}"
    local curl_args=(-sS -w '\n%{http_code}' --max-time 20 \
        -H "Authorization: Bearer ${API_KEY}" -H "Accept: application/json")
    [ "$INSECURE" = true ] && curl_args+=(-k)

    local raw
    if ! raw=$(curl "${curl_args[@]}" "$url" 2>&1); then
        log_error "Could not reach ${url}: ${raw}"
        exit 1
    fi
    local http_code body
    http_code=$(printf '%s' "$raw" | tail -1)
    body=$(printf '%s' "$raw" | sed '$d')

    if [ "$http_code" != "200" ]; then
        log_error "GET ${url} returned HTTP ${http_code}"
        case "$http_code" in
            401|403) log_error "Credentials rejected — check --api-key." ;;
            404) log_error "Not found — check --endpoint FQDN and --path-prefix (e.g. IBM RHAI needs /v1/projects/<id>/inference; leave empty for OpenAI-root hosts)." ;;
            000) log_error "No response — check DNS/connectivity/firewall for ${ENDPOINT}." ;;
        esac
        log_error "Response body: $(printf '%s' "$body" | head -c 300)"
        exit 1
    fi
    printf '%s' "$body"
}

parse_model_ids() {
    python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as e:
    print('__PARSE_ERROR__ ' + str(e))
    sys.exit(0)
items = data.get('data') if isinstance(data, dict) else data
if items is None:
    items = []
for it in items:
    if isinstance(it, dict) and it.get('id'):
        print(it['id'])
    elif isinstance(it, str):
        print(it)
"
}

DISCOVERY_BODY="$(discover_models)"
DISCOVERED_IDS=()
while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [[ "$line" == __PARSE_ERROR__* ]]; then
        log_error "Could not parse JSON response from ${BASE_URL}/v1/models: ${line#__PARSE_ERROR__ }"
        exit 1
    fi
    DISCOVERED_IDS+=("$line")
done < <(printf '%s' "$DISCOVERY_BODY" | parse_model_ids)

if [ "${#DISCOVERED_IDS[@]}" -eq 0 ]; then
    log_error "No models discovered at ${BASE_URL}/v1/models (empty 'data' array)."
    exit 1
fi

if [ -n "$FILTER" ]; then
    FILTERED_IDS=()
    for id in "${DISCOVERED_IDS[@]}"; do
        if printf '%s' "$id" | grep -Eq "$FILTER"; then
            FILTERED_IDS+=("$id")
        fi
    done
    DISCOVERED_IDS=("${FILTERED_IDS[@]:-}")
    if [ "${#DISCOVERED_IDS[@]}" -eq 0 ] || [ -z "${DISCOVERED_IDS[0]:-}" ]; then
        log_error "No discovered model ids match --filter '${FILTER}'"
        exit 1
    fi
fi

log_head "Discovered ${#DISCOVERED_IDS[@]} model(s)"
i=1
for id in "${DISCOVERED_IDS[@]}"; do
    printf '  %2d) %s\n' "$i" "$id"
    i=$((i + 1))
done

if [ "$LIST_ONLY" = true ]; then
    exit 0
fi

# -----------------------------------------------------------------------------
# Selection
# -----------------------------------------------------------------------------
SELECTED_IDS=()
if [ -n "$MODELS_ALLOWLIST" ]; then
    IFS=',' read -ra REQUESTED <<< "$MODELS_ALLOWLIST"
    for want in "${REQUESTED[@]}"; do
        want="$(trim "$want")"
        [ -z "$want" ] && continue
        found=false
        for id in "${DISCOVERED_IDS[@]}"; do
            [ "$id" = "$want" ] && { found=true; break; }
        done
        [ "$found" = false ] && log_warn "Requested model '${want}' is not in the discovery response — registering it as-is."
        SELECTED_IDS+=("$want")
    done
elif [ "$SELECT_ALL" = true ]; then
    SELECTED_IDS=("${DISCOVERED_IDS[@]}")
elif [ -t 0 ] && [ -t 1 ]; then
    echo ""
    read -r -p "Select models to register (comma-separated numbers, 'all', or blank to cancel): " CHOICE
    CHOICE="$(trim "$CHOICE")"
    if [ -z "$CHOICE" ]; then
        log_info "No selection made — exiting."
        exit 0
    elif [ "$CHOICE" = "all" ]; then
        SELECTED_IDS=("${DISCOVERED_IDS[@]}")
    else
        IFS=',' read -ra NUMS <<< "$CHOICE"
        for n in "${NUMS[@]}"; do
            n="$(printf '%s' "$n" | tr -d '[:space:]')"
            [ -z "$n" ] && continue
            if ! [[ "$n" =~ ^[0-9]+$ ]]; then
                log_warn "Ignoring invalid selection: '$n'"
                continue
            fi
            idx=$((n - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DISCOVERED_IDS[@]}" ]; then
                SELECTED_IDS+=("${DISCOVERED_IDS[$idx]}")
            else
                log_warn "Ignoring out-of-range selection: $n"
            fi
        done
    fi
else
    log_error "No selection given and no terminal to prompt — pass --all, --models id1,id2, or --list."
    exit 1
fi

if [ "${#SELECTED_IDS[@]}" -eq 0 ]; then
    log_error "No models selected."
    exit 1
fi

log_head "Selected ${#SELECTED_IDS[@]} model(s) for registration"
for id in "${SELECTED_IDS[@]}"; do
    echo "  - $id"
done

# -----------------------------------------------------------------------------
# Manifest builders
# -----------------------------------------------------------------------------
build_external_model_yaml() {
    local name="$1" target_model="$2"
    # Note: command substitution strips trailing newlines, so the conditional
    # annotations block relies on the literal newline in the heredoc below it
    # (not a trailing \n baked into the substituted string) to separate it from `spec:`.
    cat <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
$( [ -n "$PATH_PREFIX" ] && printf '  annotations:\n    compact-maas/upstream-path-prefix: "%s"' "$PATH_PREFIX" )
spec:
  provider: ${PROVIDER}
  targetModel: ${target_model}
  endpoint: ${ENDPOINT}
  credentialRef:
    name: ${SECRET_NAME}
YAML
}

build_modelref_yaml() {
    local name="$1" target_model="$2"
    cat <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${name}
  namespace: ${NAMESPACE}
  annotations:
    openshift.io/description: "External model ${target_model} via import-external-models.sh"
spec:
  modelRef:
    kind: ExternalModel
    name: ${name}
YAML
}

build_authpolicy_yaml() {
    local name="$1" subjects_yaml
    if [ "$RESTRICTED" = true ]; then
        subjects_yaml=$(printf '  subjects:\n    groups: []\n    users: []')
    else
        subjects_yaml=$(printf '  subjects:\n    groups:\n      - name: system:authenticated\n    users: []')
    fi
    cat <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: ${name}-access
  namespace: ${GOVERNANCE_NAMESPACE}
spec:
  modelRefs:
    - name: ${name}
      namespace: ${NAMESPACE}
${subjects_yaml}
YAML
}

build_subscription_yaml() {
    local name="$1" owner_yaml
    if [ "$RESTRICTED" = true ]; then
        owner_yaml=$(printf '  owner:\n    groups: []\n    users: []')
    else
        owner_yaml=$(printf '  owner:\n    groups:\n      - name: system:authenticated\n    users: []')
    fi
    cat <<YAML
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: ${name}-free
  namespace: ${GOVERNANCE_NAMESPACE}
  annotations:
    openshift.io/display-name: "${name} (imported)"
spec:
${owner_yaml}
  modelRefs:
    - name: ${name}
      namespace: ${NAMESPACE}
      tokenRateLimits:
        - limit: ${TOKEN_LIMIT}
          window: ${TOKEN_WINDOW}
  priority: 10
YAML
}

apply_or_preview() {
    local label="$1" manifest="$2"
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would apply ${label}:"
        printf '%s\n' "$manifest" | sed 's/^/    /'
    else
        printf '%s\n' "$manifest" | oc apply -f - | sed 's/^/    /'
    fi
}

# -----------------------------------------------------------------------------
# Namespace + shared Secret
# -----------------------------------------------------------------------------
ensure_namespace() {
    [ "$SKIP_NAMESPACE" = true ] && return 0
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would ensure namespace '${NAMESPACE}' exists with label maas.opendatahub.io/gateway-access=true"
        return 0
    fi
    if oc get namespace "$NAMESPACE" &>/dev/null; then
        log_info "Namespace ${NAMESPACE} already exists"
    else
        log_step "Creating namespace ${NAMESPACE}..."
        cat <<YAML | oc apply -f - | sed 's/^/    /'
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
  labels:
    maas.opendatahub.io/gateway-access: "true"
YAML
    fi
}

apply_secret() {
    log_step "Ensuring shared credential Secret '${SECRET_NAME}' in ${NAMESPACE}..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would create/update Secret ${SECRET_NAME} (data key: api-key) with labels:"
        log_info "[DRY RUN]   inference.networking.k8s.io/bbr-managed=true"
        log_info "[DRY RUN]   inference.networking.k8s.io/ipp-managed=true"
        return 0
    fi
    oc create secret generic "$SECRET_NAME" \
        --from-literal=api-key="$API_KEY" \
        -n "$NAMESPACE" \
        --dry-run=client -o yaml | oc apply -f - >/dev/null
    oc label secret "$SECRET_NAME" -n "$NAMESPACE" \
        inference.networking.k8s.io/bbr-managed=true \
        inference.networking.k8s.io/ipp-managed=true --overwrite >/dev/null
    log_info "Secret ${SECRET_NAME} ready (bbr-managed + ipp-managed)"
}

# -----------------------------------------------------------------------------
# HTTPRoute URLRewrite heal (mirrors compact-maas httproute-rewrite.ts)
# -----------------------------------------------------------------------------
# The patch-computation script is invoked with `python3 -c "$HEAL_PATCH_PY" ...`
# (script passed as an argv string), NOT `python3 - <<HEREDOC`. That distinction
# matters: `python3 -` reads the script itself from stdin, so combining it with
# a heredoc means stdin is entirely consumed by the script source, leaving
# nothing for the subsequent `json.load(sys.stdin)` call to read — it always
# sees an empty stream and always fails with "Expecting value: line 1 column 1
# (char 0)", regardless of what the route actually looks like on the cluster.
# `-c` avoids this: the script text is an argument, so stdin stays free for the
# piped route JSON.
HEAL_PATCH_PY=$(cat <<'PY'
import json, sys
namespace, name, target_prefix = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    route = json.load(sys.stdin)
except Exception as e:
    print('__PARSE_ERROR__ ' + str(e))
    sys.exit(0)
want_path = f"/{namespace}/{name}"
rules = (route.get('spec') or {}).get('rules') or []
rule_idx = -1
for i, rule in enumerate(rules):
    for m in rule.get('matches') or []:
        p = m.get('path') or {}
        if p.get('type') == 'PathPrefix' and p.get('value') == want_path:
            rule_idx = i
            break
    if rule_idx >= 0:
        break
if rule_idx < 0:
    print('NO_RULE')
    sys.exit(0)

filters = rules[rule_idx].get('filters')
desired = {
    'type': 'URLRewrite',
    'urlRewrite': {'path': {'type': 'ReplacePrefixMatch', 'replacePrefixMatch': target_prefix}},
}

def is_desired(f):
    if not isinstance(f, dict) or f.get('type') != 'URLRewrite':
        return False
    path = (f.get('urlRewrite') or {}).get('path') or {}
    return path.get('type') == 'ReplacePrefixMatch' and path.get('replacePrefixMatch') == target_prefix

if isinstance(filters, list) and any(is_desired(f) for f in filters):
    print('ALREADY')
    sys.exit(0)

patch = []
if not isinstance(filters, list):
    patch.append({'op': 'add', 'path': f'/spec/rules/{rule_idx}/filters', 'value': [desired]})
else:
    rewrite_idx = next((i for i, f in enumerate(filters) if isinstance(f, dict) and f.get('type') == 'URLRewrite'), -1)
    if rewrite_idx >= 0:
        patch.append({'op': 'replace', 'path': f'/spec/rules/{rule_idx}/filters/{rewrite_idx}', 'value': desired})
    else:
        patch.append({'op': 'add', 'path': f'/spec/rules/{rule_idx}/filters/0', 'value': desired})
print(json.dumps(patch))
PY
)

heal_http_route() {
    local name="$1" target_prefix="${2:-/}"
    [ "$SKIP_ROUTE_HEAL" = true ] && return 0
    log_step "Ensuring HTTPRoute ${name} rewrites /${NAMESPACE}/${name} -> ${target_prefix}..."
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would ensure HTTPRoute ${name} -n ${NAMESPACE} URLRewrite -> ${target_prefix}"
        return 0
    fi

    # Explicit GVK (httproute.gateway.networking.k8s.io) avoids any ambiguity
    # with short-name resolution across API groups/discovery cache state.
    local gvk="httproute.gateway.networking.k8s.io"
    # NOT_FOUND waits (async reconciler creating the route) legitimately take
    # up to ~90s. A run of consecutive parse/cmd errors, though, means
    # something is actually wrong (auth, API hiccup, bug) — bail out of THIS
    # model much sooner than the full 90s budget so --all keeps moving.
    local attempts=0 max_attempts=18 delay=5 fail_attempts=0 fail_cap=3
    local route_json patch get_rc out_file err_file last_err
    out_file=$(mktemp) err_file=$(mktemp)
    trap 'rm -f "$out_file" "$err_file"' RETURN

    while [ $attempts -lt $max_attempts ]; do
        : >"$out_file"; : >"$err_file"
        # if/then/else (not `cmd; rc=$?`) because this runs under `set -e`:
        # a bare nonzero exit status here would abort the whole script.
        if oc get "${gvk}/${name}" -n "$NAMESPACE" -o json >"$out_file" 2>"$err_file"; then
            get_rc=0
        else
            get_rc=$?
        fi
        route_json="$(cat "$out_file")"
        last_err="$(cat "$err_file")"

        if [ "$get_rc" -eq 0 ] && [ -n "$(printf '%s' "$route_json" | tr -d '[:space:]')" ]; then
            fail_attempts=0
            patch=$(printf '%s' "$route_json" | python3 -c "$HEAL_PATCH_PY" "$NAMESPACE" "$name" "$target_prefix" 2>"$err_file") || patch="__CMD_ERROR__"
            last_err="$(cat "$err_file")"
            case "$patch" in
                ALREADY)
                    log_info "HTTPRoute ${name} already has the desired URLRewrite"
                    return 0
                    ;;
                NO_RULE)
                    log_warn "HTTPRoute ${name} has no PathPrefix /${NAMESPACE}/${name} rule yet (still reconciling)"
                    ;;
                __PARSE_ERROR__*|__CMD_ERROR__|"")
                    fail_attempts=$((fail_attempts + 1))
                    log_warn "HTTPRoute ${name}: got an unparsable response this poll (${patch:-empty}); retrying..."
                    [ -n "$last_err" ] && log_warn "  stderr: $(printf '%s' "$last_err" | head -c 300)"
                    ;;
                *)
                    if oc patch "${gvk}/${name}" -n "$NAMESPACE" --type=json -p "$patch" >"$err_file" 2>&1; then
                        log_info "HTTPRoute ${name} URLRewrite -> ${target_prefix} applied"
                        return 0
                    fi
                    fail_attempts=$((fail_attempts + 1))
                    log_warn "Failed to patch HTTPRoute ${name} (will retry): $(cat "$err_file" | head -c 300)"
                    ;;
            esac
        elif [ "$get_rc" -ne 0 ]; then
            fail_attempts=0
            log_warn "HTTPRoute ${name} not found yet (waiting for MaaS external-model reconciler)..."
            [ -n "$last_err" ] && log_warn "  oc get error: $(printf '%s' "$last_err" | head -c 300)"
        else
            fail_attempts=$((fail_attempts + 1))
            log_warn "HTTPRoute ${name} exists but returned an empty body this poll; retrying..."
        fi

        if [ "$fail_attempts" -ge "$fail_cap" ]; then
            log_warn "HTTPRoute ${name}: ${fail_attempts} consecutive unparsable/failed polls — this looks like a real problem, not reconciler lag."
            log_warn "  Giving up early ($((attempts * delay))s in) instead of waiting out the full $((max_attempts * delay))s budget."
            log_warn "  Inspect manually: oc get ${gvk} ${name} -n ${NAMESPACE} -o yaml"
            return 0
        fi

        attempts=$((attempts + 1))
        sleep "$delay"
    done
    log_warn "Gave up healing HTTPRoute ${name} after $((max_attempts * delay))s — continuing to the next model."
    log_warn "  Heal it manually once the route settles: oc get ${gvk} ${name} -n ${NAMESPACE} -o yaml"
    return 0
}

wait_modelref_ready() {
    local name="$1" timeout=120 elapsed=0 phase=""
    log_info "Waiting for MaaSModelRef ${name} to become Ready (timeout ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        phase=$(oc get maasmodelref "$name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        [ "$phase" = "Ready" ] && break
        sleep 5
        elapsed=$((elapsed + 5))
    done
    if [ "$phase" = "Ready" ]; then
        log_info "MaaSModelRef ${name}: Ready"
    else
        log_warn "MaaSModelRef ${name} not Ready after ${timeout}s (phase: ${phase:-unknown})"
        log_warn "  oc describe maasmodelref ${name} -n ${NAMESPACE}"
    fi
}

# -----------------------------------------------------------------------------
# Register each selected model
# -----------------------------------------------------------------------------
ensure_namespace
apply_secret

REGISTERED_NAMES=()
for model_id in "${SELECTED_IDS[@]}"; do
    unique_name "$model_id"
    name="$UNIQUE_NAME"
    log_head "Registering '${model_id}' as '${name}'"

    apply_or_preview "ExternalModel/${name}" "$(build_external_model_yaml "$name" "$model_id")"
    apply_or_preview "MaaSModelRef/${name}" "$(build_modelref_yaml "$name" "$model_id")"

    if [ "$SKIP_GOVERNANCE" = false ]; then
        apply_or_preview "MaaSAuthPolicy/${name}-access" "$(build_authpolicy_yaml "$name")"
        apply_or_preview "MaaSSubscription/${name}-free" "$(build_subscription_yaml "$name")"
    fi

    heal_http_route "$name" "${PATH_PREFIX:-/}"

    if [ "$DRY_RUN" = false ] && [ "$WAIT_READY" = true ]; then
        wait_modelref_ready "$name"
    fi

    REGISTERED_NAMES+=("$name")
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
log_head "Summary"
if [ "${#REGISTERED_NAMES[@]}" -eq 0 ]; then
    log_warn "No models were registered."
    exit 0
fi

log_info "$( [ "$DRY_RUN" = true ] && echo "[DRY RUN] Would register" || echo "Registered" ) ${#REGISTERED_NAMES[@]} model(s) in namespace '${NAMESPACE}':"
for n in "${REGISTERED_NAMES[@]}"; do
    echo "  - $n"
done

if [ "$SKIP_GOVERNANCE" = true ]; then
    echo ""
    log_info "Governance was skipped (--skip-governance). Models are registered but not"
    log_info "yet visible/callable until a MaaSAuthPolicy + MaaSSubscription exist for them"
    log_info "(create via Admin, or re-run without --skip-governance)."
fi

if [ "$DRY_RUN" = true ]; then
    exit 0
fi

DOMAIN=""
if command -v oc >/dev/null 2>&1; then
    DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
fi
GW="https://maas.${DOMAIN:-<cluster-domain>}"
FIRST="${REGISTERED_NAMES[0]}"

echo ""
echo "Verify:"
echo "  oc get maasmodelref -n ${NAMESPACE}"
echo ""
echo "Mint a key and call the gateway (example for '${FIRST}'):"
cat <<EOF
  API_KEY=\$(curl -sk -X POST "${GW}/maas-api/v1/api-keys" \\
      -H "Authorization: Bearer \$(oc whoami -t)" \\
      -H "Content-Type: application/json" \\
      -d '{"name": "import-test", "subscription": "${FIRST}-free", "expiresIn": "1h"}' \\
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token') or d.get('key'))")

  curl --http1.1 -sS -X POST "${GW}/${NAMESPACE}/${FIRST}/v1/chat/completions" \\
      -H "Authorization: Bearer \${API_KEY}" \\
      -H "Content-Type: application/json" \\
      -d '{"model": "${FIRST}", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 32}'
EOF
