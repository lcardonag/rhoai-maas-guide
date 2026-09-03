# Phase 5: MaaS Model Deployment

Deploy and register LLM models with the MaaS platform.

Full documentation: https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/05-maas-models.html

## What Phase 5 does

Each bundle under this directory applies **both**:

| Subdirectory | Resources |
|--------------|-----------|
| `llm/` | `LLMInferenceService` (inference pod + `maas-default-gateway` routing) |
| `maas/` | `MaaSModelRef`, `MaaSAuthPolicy`, `MaaSSubscription` (free + premium) |

`setup-maas.sh` Phase 5 runs `oc apply -k manifests/05-maas-models/<model>/` — deploy **and** MaaS registration in one step.

## Bundled models only

Phase 5 / `--model` accepts **only**:

| Name | GPU | Notes |
|------|-----|-------|
| `simulator` | No | CPU mock LLM (~30s startup) |
| `granite-tiny-gpu` | Yes (~8 GiB VRAM) | Small Granite on vLLM |
| `gpt-oss-20b` | Yes (~16 GiB VRAM) | Larger model |
| `auto` | Detects GPU | Picks one of the above (script default) |

Custom catalog models (e.g. Gemma) are **not** in this directory. Use the OpenShift AI dashboard (**Publish as MaaS**) or copy/adapt the `maas/` YAMLs for your `LLMInferenceService`.

## Recommended workflows

### Path A — Script end-to-end (bundled model)

```bash
./scripts/setup-maas.sh
# or explicitly:
./scripts/setup-maas.sh --model simulator
```

### Path B — Script platform, GUI model (custom weights)

```bash
# 1. Platform only — wait for maas-api health before deploying in GUI
./scripts/setup-maas.sh --skip-models

# 2. OpenShift AI dashboard → deploy model → Advanced → Publish as MaaS
```

**Publish as MaaS** appears only after Phases 1–4 complete (`modelsAsAService: Managed`, `maas-api` running). Deploying earlier gives inference on `inference-gateway` only — not the MaaS catalog.

### Path C — Register an existing GUI model manually

If the model was deployed before MaaS was ready:

1. Label namespace: `maas.opendatahub.io/gateway-access=true`
2. Patch `LLMInferenceService` to use `maas-default-gateway` (see `granite-tiny-gpu/llm/model.yaml`)
3. Apply `MaaSModelRef` + `maas/` governance CRs (adapt names/namespaces from `simulator/maas/`)

## Subscriptions and user access

Phase 5 creates `MaaSSubscription` and `MaaSAuthPolicy` automatically. Guide defaults use `system:authenticated` — any user logged into OpenShift AI can see the model and mint a `*-free` API key. No per-user assignment is required for the open tier.

For restricted access, edit `subjects` on the auth policy and subscription, or use Compact MaaS Admin (Phase 10).

## Script skip behavior

If **any** `LLMInferenceService` exists cluster-wide, Phase 5 is skipped entirely (no second model, no registration of existing services). To run Phase 5 anyway, remove other `LLMInferenceService` CRs first or apply the `maas/` manifests manually.

## Apply manually

```bash
oc create namespace llm
oc label namespace llm maas.opendatahub.io/gateway-access=true opendatahub.io/dashboard=true --overwrite
oc apply -k manifests/05-maas-models/simulator/
```

## Inference testing (in-cluster models)

```bash
MAAS_URL="https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
API_KEY=$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d '{"name":"test","subscription":"simulator-free","expiresIn":"1h"}' | jq -r '.key')
MODEL_ID=$(curl -sk "${MAAS_URL}/v1/models" -H "Authorization: Bearer ${API_KEY}" | jq -r '.data[0].id')
curl -sk "${MAAS_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":20}"
```

Use `.key` (not `.token`). List at `/v1/models`; infer at `/v1/chat/completions` with `MODEL_ID` from the listing.
