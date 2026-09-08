# Phase 5: MaaS Model Deployment

This phase deploys LLM models and registers them with the MaaS platform. Each model includes the inference workload (LLMInferenceService) and the MaaS control plane resources (MaaSModelRef, MaaSAuthPolicy, MaaSSubscription) that enable API key management, access control, and rate limiting.

> **Tip:** All file paths and `oc apply` commands in this guide are relative to the [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide) repository root. Make sure you have cloned it and are working from its root directory (see [Getting Started](./index.md#getting-started)).

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

## Prerequisites

- [Phases 1](./01-prerequisites.md)-[4](./04-rhoai-config.md) completed (RHOAI installed, MaaS platform running)
- `maas-api` healthy: `curl -sk https://maas.<domain>/maas-api/health` returns `{"status":"healthy"}`
- MaaS Gateway `maas-default-gateway` programmed in `openshift-ingress`
## Choosing a deployment path

Phases 1–4 install the MaaS **platform**. A model appears in the MaaS catalog only after it is **registered** (Phase 5, **Publish as MaaS**, or manual `MaaSModelRef` YAML).

| Path | When | How |
| --- | --- | --- |
| **A — Full script** | Validate MaaS quickly with a bundled model | `./scripts/setup-maas.sh` or `--model simulator` |
| **B — Script + GUI** | Custom catalog model (e.g. Gemma) on GPU | `./scripts/setup-maas.sh --skip-models`, then dashboard deploy with **Publish as MaaS** in Advanced settings |
| **C — Register existing GUI model** | Model deployed before MaaS was ready (no Publish option at deploy time) | Label namespace, patch gateway to `maas-default-gateway`, apply `maas/` YAMLs — see [Register Existing Gui Model](#register-existing-gui-model) |

> **Important:** **Order matters for the GUI.** Deploy models **after** Phase 4 completes and `maas-api` is running. If you deploy earlier, **Publish as MaaS** does not appear and the model is inference-only on `inference-gateway` (Kubernetes token auth), not in the MaaS catalog.

> **Warning:** `setup-maas.sh` Phase 5 deploys only the three bundled models below. It skips Phase 5 if **any** `LLMInferenceService` already exists anywhere in the cluster — it does **not** register pre-existing GUI deployments.

## OpenShift AI dashboard (RHOAI 3.5+)

After [Phase 4](./04-rhoai-config.md), enable `modelAsService: true` and `genAiStudio: true` on `OdhDashboardConfig` (the script does this).

| Location | Content |
| --- | --- |
| **Gen AI Studio → AI asset endpoints** | **Models** tab (deployed models; MaaS-published models show a **Model as a Service** badge) and **MCP Server** tab |
| **Gen AI Studio → API keys** | Create and manage MaaS API keys and subscriptions (sibling menu item — **not** inside AI asset endpoints) |

Guide model manifests create `MaaSAuthPolicy` and `MaaSSubscription` automatically. Default tier grants `system:authenticated` — any logged-in user can mint a `*-free` key. Restricted subscriptions require editing `subjects` or using Compact MaaS Admin.

## Available Models (Phase 5 / script only)

### simulator (recommended for initial testing)

A CPU-only mock LLM that requires no GPU. It uses the `llm-d-inference-sim` container to simulate an OpenAI-compatible inference endpoint. This is the best choice for validating the MaaS platform without GPU infrastructure.

- **Runtime**: llm-d-inference-sim (CPU-only)
- **Resources**: 100m-500m CPU, 256Mi-512Mi memory
- **GPU**: Not required
- **Startup time**: ~30 seconds
### granite-tiny-gpu

Red Hat AI Granite 4.0-h-tiny FP8 Dynamic, a small Granite model (~1B parameters) running on the Red Hat AI Inference Server (vLLM CUDA). Suitable for clusters with modest GPU resources.

- **Runtime**: vLLM CUDA (registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.3.0)
- **Model weights**: OCI modelcar from registry.redhat.io
- **Resources**: 2-4 CPU, 8Gi-24Gi memory, 1x NVIDIA GPU
- **GPU memory**: ~8GB required
- **Startup time**: 5-15 minutes (image pull + model loading)
### gpt-oss-20b

OpenAI gpt-oss-20b running on the Red Hat AI Inference Server (vLLM CUDA). Requires a capable GPU node (A10G or better) with sufficient VRAM.

- **Runtime**: vLLM CUDA (registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.3.0)
- **Model weights**: OCI modelcar from registry.redhat.io (~8GB download)
- **Resources**: 2-4 CPU, 16Gi-60Gi memory, 1x NVIDIA GPU
- **GPU memory**: ~16GB required
- **Startup time**: 5-15 minutes (image pull + model loading)
## Custom Resource Descriptions

Each model deployment creates the following CRDs under `maas.opendatahub.io/v1alpha1`:

### LLMInferenceService (namespace: `llm`)

Defines the inference workload: the container, model weights, resource requests, health probes, and gateway routing. This is the actual serving pod that handles inference requests.

### MaaSModelRef (namespace: `llm`)

Registers the LLMInferenceService with the MaaS control plane. The MaaS API uses this reference to discover available models and route API requests to the correct inference endpoint.

### MaaSAuthPolicy (namespace: `models-as-a-service`)

Defines who can access the model. The examples here grant access to all authenticated users (`system:authenticated` group). You can restrict access to specific users or groups by modifying the `subjects` field.

### MaaSSubscription (namespace: `models-as-a-service`)

Defines rate-limiting tiers for model access. Each model ships with two tiers:

- **Free tier** (priority 10): 100 tokens/min for all authenticated users
- **Premium tier** (priority 20): 100,000 tokens/min for all authenticated users
Higher-priority subscriptions take precedence. You can adjust limits, windows, and subject groups to match your usage policies.

### Per-model vs bundle subscriptions

Subscriptions are independent. You can run **both** patterns on the same cluster:

| Pattern | Example | Use case |
|---------|---------|----------|
| **Per-model** | `gemma-4-e4b-it-free`, `gpt-4o-mini-free` | Different limits, owners, or billing per model |
| **Bundle** | `coding-models` → CodeLlama + GPT-4o-mini + Granite | One API key for a use case (e.g. coding) |

- One **MaaSSubscription** can list **multiple** `modelRefs` (GUI: **Add models** on the same subscription).
- One **API key** binds to **one** subscription and can call **all models** on that subscription (set `model` in the JSON body at the [gateway root](#canonical-maas-url)).
- The same model may appear in more than one subscription (e.g. à la carte + bundle) with different limits.
- Each subscription needs a matching **MaaSAuthPolicy** (or use **Create a matching authorization policy** in the GUI).

`scripts/import-external-models.sh` creates one `<name>-free` subscription per model by default. Use `--skip-governance` and attach imported models to a bundle in the dashboard instead. By default the script also validates registration (upstream chat probe, BBR credential reload, gateway E2E on the first model); use `--skip-validate` for register-only bulk imports.

### MaaS governance (native UI) {#maas-governance-native-ui}

On **RHOAI 3.5+**, admins create subscriptions and auth policies under **Settings → MaaS governance** (not inside **Gen AI Studio → API keys**, which is for end-user key minting).

1. **Settings → MaaS governance → Create subscription**
2. Add **groups** (e.g. `system:authenticated`), **models** (in-cluster + external), **token limits**
3. Check **Create a matching authorization policy**
4. End users: **Gen AI Studio → API keys → Create API key** → pick the subscription

Enable the auth-policy admin UI if the governance page is incomplete:

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge \
  -p '{"spec":{"dashboardConfig":{"maasAuthPolicies":true}}}'
```

See [Phase 8 — external models](./08-external-models.md#per-model-reconciliation) for what the import script creates per model vs what the controller reconciles on the gateway.

## Deploying a Model

> **Note:**
> **Gateway Pod OOMKill**
>
> Deploying a model triggers the Istio gateway to load Kuadrant Wasm extensions, which can push the pod past the default `1Gi` memory limit. If you applied the `gateway-resources.yaml` ConfigMap in [Phase 2 Step 5b](./02-platform-config.md#gateway-pod-oomkill-prevention), this is already handled (the limit is set to `2Gi` via `parametersRef`).
>
> If the gateway pod starts OOMKilling after deploying a model, see [Phase 2: Gateway OOMKill Prevention](./02-platform-config.md#gateway-pod-oomkill-prevention) for the fix.

Create the `llm` namespace if it doesn't exist and label it for RHOAI:

```bash
oc create namespace llm
oc label namespace llm opendatahub.io/generated-namespace=true --overwrite
oc label namespace llm maas.opendatahub.io/gateway-access=true --overwrite
oc label namespace llm opendatahub.io/dashboard=true --overwrite
```

> **Important:** The `maas.opendatahub.io/gateway-access` label is required for any namespace that serves models through the MaaS Gateway. Without it, the Gateway will not accept HTTPRoutes from this namespace and the model will not be reachable.

> **Tip:** The `opendatahub.io/dashboard` label makes the `llm` namespace appear as a Data Science Project in the Red Hat OpenShift AI dashboard.

Deploy the simulator (no GPU required):

```bash
oc apply -k manifests/05-maas-models/simulator/
```

> **Note:**
> **HuggingFace Xet Download Hang**
>
> The simulator uses `hf://sshleifer/tiny-gpt2` as its model URI. HuggingFace has migrated model storage to the Xet protocol, which can cause the KServe storage-initializer init container to hang indefinitely during download. If the model pod is stuck in `Init:0/1` for more than 5 minutes, apply this workaround:
>
> ```bash
> oc patch deployment facebook-opt-125m-simulated-kserve -n llm \
>   --type=json \
>   -p '[{"op":"add","path":"/spec/template/spec/initContainers/0/env/-","value":{"name":"HF_HUB_DISABLE_XET","value":"1"}}]'
> ```
>
> This disables the Xet protocol and falls back to standard HTTP downloads. The patched pod should complete init within 30 seconds. Note that KServe may revert this patch on reconciliation, so reapply if the model is redeployed.
>
> GPU models using OCI modelcar images (granite-tiny-gpu, gpt-oss-20b) are **not** affected by this issue since they do not download from HuggingFace.

Or deploy a GPU model if your cluster has NVIDIA GPUs:

```bash
# For clusters with modest GPU (8GB+ VRAM)
oc apply -k manifests/05-maas-models/granite-tiny-gpu/

# For clusters with larger GPU (16GB+ VRAM, A10G or better)
oc apply -k manifests/05-maas-models/gpt-oss-20b/
```

Or use the automation script (same manifests, auto-detects GPU when `--model auto`):

```bash
./scripts/setup-maas.sh --from-phase 5
./scripts/setup-maas.sh --from-phase 5 --model granite-tiny-gpu
```

## Register an existing GUI-deployed model {#register-existing-gui-model}

Use this when a model was deployed from the dashboard **before** MaaS was ready, or without **Publish as MaaS**.

1. Confirm MaaS platform is up (Phase 4): `oc get maasmodelref -A` may be empty; `curl -sk https://maas.<domain>/maas-api/health` must succeed.
1. Label the model namespace for the MaaS gateway:
```bash
oc label namespace <your-namespace> maas.opendatahub.io/gateway-access=true --overwrite
```

1. Point the `LLMInferenceService` at `maas-default-gateway` (same as guide GPU models):
```bash
oc patch llminferenceservice <model-name> -n <your-namespace> --type=merge -p '{
  "spec": {
    "router": {
      "gateway": {
        "refs": [{
          "name": "maas-default-gateway",
          "namespace": "openshift-ingress"
        }]
      }
    }
  }
}'
```

1. Apply MaaS CRs — copy from `manifests/05-maas-models/simulator/maas/` (or any bundled `maas/` folder) and adjust names/namespaces:
- `MaaSModelRef` in the same namespace as the `LLMInferenceService`
- `MaaSAuthPolicy` and `MaaSSubscription` in `models-as-a-service`
1. Verify:
```bash
oc get maasmodelref -n <your-namespace> -o wide
curl -sk "https://maas.<domain>/maas-api/health"
# After minting an API key (see Testing Inference below):
# curl -sk "https://maas.<domain>/v1/models" -H "Authorization: Bearer ${API_KEY}"
```

The model should appear in **Gen AI Studio → AI asset endpoints → Models** with a **Model as a Service** badge. Users mint keys under **Gen AI Studio → API keys**.

## Verifying Model Readiness

After deploying, verify that the model is ready:

```bash
# Check LLMInferenceService status
oc get llminferenceservice -n llm

# Check that model pods are running
oc get pods -n llm

# Check MaaSModelRef registration
oc get maasmodelref -n llm -o wide

# Check MaaSAuthPolicy and MaaSSubscription
oc get maasauthpolicy -n models-as-a-service
oc get maassubscription -n models-as-a-service
```

The LLMInferenceService should show a `Ready` condition. For GPU models, initial startup takes 5-15 minutes while the container image is pulled and model weights are loaded into GPU memory.

## Testing Inference

Once the model is ready, test inference through the MaaS API:

```bash
# Get the MaaS API domain
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MAAS_URL="maas.${CLUSTER_DOMAIN}"

# Create an API key (requires the maas-api to be running)
API_KEY=$(curl -sk -X POST "https://${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name": "test-key", "subscription": "simulator-free", "expiresIn": "1h"}' \
  | jq -r '.key')

# List available models
curl -sk "https://${MAAS_URL}/v1/models" \
  -H "Authorization: Bearer ${API_KEY}"

# Resolve model id + base URL from the listing (do not hand-build /namespace/model paths)
MODEL_ID=$(curl -sk "https://${MAAS_URL}/v1/models" \
  -H "Authorization: Bearer ${API_KEY}" | jq -r '.data[0].id')
MODEL_URL=$(curl -sk "https://${MAAS_URL}/v1/models" \
  -H "Authorization: Bearer ${API_KEY}" | jq -r '.data[0].url')

# Send a chat completion request at the gateway root (/v1/chat/completions)
curl -sk "${MAAS_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_ID}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}]
  }"
```

> **Important:** API key creation returns the field `key` (prefix `sk-oai-…`), not `token`. List models at `/v1/models` (not `/maas-api/v1/models`). Inference uses `POST ${MAAS_URL}/v1/chat/completions` with the `id` from the listing (often `publishers/<namespace>/models/<name>`). Do not hand-build `/namespace/model/v1/...` paths unless debugging routing.

For GPU models, use the `id` and `subscription` from your `MaaSSubscription` (e.g. `granite-tiny-gpu-free`).

### Troubleshooting inference and AI asset endpoints

#### Canonical MaaS URL (what clients should use) {#canonical-maas-url}

For **MaaS-published** models, the only client-facing base URL is the **gateway root**:

```text
https://maas.<cluster-domain>/
```

Examples:

```bash
MAAS_URL="https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"

# List models
curl -sk "${MAAS_URL}/v1/models" -H "Authorization: Bearer ${API_KEY}"

# Infer — model id goes in the JSON body, not in the URL path
curl -sk "${MAAS_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"publishers/my-first-model/models/redhataigemma-4-e4b-it","messages":[{"role":"user","content":"hola"}]}'
```

Confirm the MaaS controller resolved the same endpoint:

```bash
oc get maasmodelref -n <model-namespace> -o custom-columns=\
NAME:.metadata.name,\
ENDPOINT:.status.endpoint,\
MODEL_ID:.status.resolvedModelAlias
```

Expected for a GUI-published Gemma on `maas-default-gateway`:

| Field | Example |
|-------|---------|
| `status.endpoint` | `https://maas.apps.<domain>/` |
| `status.resolvedModelAlias` | `publishers/<namespace>/models/<llmisvc-name>` |

Do **not** call per-model paths such as `/my-first-model/redhataigemma-4-e4b-it/v1/...` or `/publishers/.../v1/...` unless you are debugging routing. MaaS API keys and the catalog use the **gateway root** + `model` in the body.

#### Duplicate entries in AI asset endpoints / playground

A single `LLMInferenceService` on `maas-default-gateway` advertises multiple **model identifiers** in `status.addresses` (short name `redhataigemma-4-e4b-it` and publishers alias `publishers/…/models/…`). **Gen AI Studio → AI asset endpoints** may list both in the **Endpoints** column — that is KServe/RHOAI UI behavior, not two deployments.

| What you see | Use it? |
|--------------|---------|
| `https://maas.<domain>/` (MaaS gateway root) | **Yes** — canonical for API keys |
| `publishers/…/models/…` | **Model id** for the JSON `model` field — not a separate base URL |
| `redhataigemma-4-e4b-it` (short name) | **No** — ignore for MaaS clients; playground may 404 if selected |

**Playground:** the `lsd-genai-playground` stack should register only the MaaS provider pointing at `https://maas.<domain>/v1` with model id `publishers/…/models/…`. If a second provider (`vllm-inference-1` with the namespace path) appears, remove it from ConfigMap `llama-stack-config` in the project namespace and restart `deployment/lsd-genai-playground`.

Remove stale routes from earlier experiments (for example an old `llama-32-3b-instruct-route` on `openshift-ai-inference`):

```bash
oc delete httproute llama-32-3b-instruct-route -n my-first-model --ignore-not-found
oc delete servingruntime llama-32-3b-instruct -n my-first-model --ignore-not-found
```

#### API key works for `/v1/models` but inference returns `401`

Symptoms: `POST …/v1/chat/completions` returns `401` with `x-ext-auth-reason: Authentication required`, while `GET /v1/models` with the same `sk-oai-…` key returns `200`.

This can indicate Authorino is not receiving the `Authorization` header on inference routes (often related to `payload-pre-processing` / `payload-processing` ext-proc filters on `maas-default-gateway`). Registration (`MaaSModelRef` Ready) can still be correct.

Check:

```bash
oc get pods -n openshift-ingress | grep payload
oc logs -n kuadrant-system deploy/authorino --tail=20 | grep chat/completions
```

Workarounds while investigating: confirm the model pod serves locally (`oc exec` into the vLLM container), or redeploy with **Publish as MaaS** from the dashboard after MaaS is Ready. Re-run `./scripts/setup-maas.sh --from-phase 4` after platform upgrades.

#### Gateway proxy memory for GUI models

GUI-deployed models route through `openshift-ai-inference` as well as `maas-default-gateway` when published to MaaS. All three gateways in `openshift-ingress` need **2Gi** proxy memory — see [Phase 2 gateway OOM prevention](./02-platform-config.md#gateway-pod-oomkill-prevention).

## Removing a Model

```bash
oc delete -k manifests/05-maas-models/simulator/
```

## Appendix

### Directory Structure

Each model follows the same Kustomize layout:

```
{model}/
  kustomization.yaml          # Aggregates llm/ and maas/ subdirectories
  llm/
    model.yaml                # LLMInferenceService CR
    kustomization.yaml        # Sets namespace: llm (+ namePrefix for simulator)
  maas/
    maas-model.yaml           # MaaSModelRef CR
    maas-auth-policy.yaml     # MaaSAuthPolicy CR (namespace: models-as-a-service)
    maas-subscription-free.yaml     # Free tier MaaSSubscription
    maas-subscription-premium.yaml  # Premium tier MaaSSubscription
    kustomization.yaml        # Lists all MaaS resources
```

## References

- [Upstream MaaS Documentation](https://opendatahub-io.github.io/models-as-a-service/latest/)
- [MaaS CRD Reference (models-as-a-service repo)](https://github.com/opendatahub-io/models-as-a-service)
## Next step

Proceed to [Phase 6: Verification](./06-verification.md).
