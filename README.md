# RHOAI Models-as-a-Service (MaaS) Guide

Companion guide to deploy **Red Hat OpenShift AI (RHOAI) Models-as-a-Service** on OpenShift using Kustomize manifests and automation scripts.

- Kustomize manifests with status gates between every phase
- Single automation script for end-to-end deployment (`setup-maas.sh`)
- CPU-only **simulator** model for validation without GPUs
- **Local docs:** [Phase 8 — External Models](docs/08-external-models.md) (Markdown; full IBM RHAI / OpenAI / troubleshooting detail)

**Targets RHOAI 3.4** per the [official MaaS docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). This fork has been exercised on **RHOAI 3.5** (dashboard nav, `maas-api` in `redhat-ai-gateway-infra`, gateway memory fixes). Treat 3.5 as supported-with-notes, not a separate product guide.

Requires OpenShift 4.19+ with cluster-admin access.

> **Note:** This is not a replacement for Red Hat’s official documentation. It is an opinionated companion with manifests, scripts, and field notes from real cluster installs.

**Published guide:** https://rh-aiservices-bu.github.io/rhoai-maas-guide/  
**Upstream repo:** https://github.com/rh-aiservices-bu/rhoai-maas-guide

## How this fork differs from upstream

| Area | Upstream focus | This guide adds |
|------|----------------|-----------------|
| **Lifecycle** | Often reads as “run script → model included” | **Phases 1–4 = platform only**; models are a separate step (Phase 5, GUI, or manual register) |
| **Phase 5** | Auto-deploy one model | Only **`simulator`**, **`granite-tiny-gpu`**, **`gpt-oss-20b`**; **skips** if any `LLMInferenceService` exists |
| **GUI models** | Light coverage | **Publish as MaaS** timing, RHOAI **3.5** nav, **register existing GUI model** workflow |
| **Gateways** | `maas-default-gateway` OOM fix | **All three** ingress gateways need **2Gi** proxy memory; script applies TLS + memory fixes |
| **Phase 8** | AsciiDoc in Antora | **[docs/](docs/)** — canonical Markdown (Phase 8 started the pattern; all phases now in `docs/`) |
| **Script** | Phases 0–6 | RHOAI **3.5** DSC/dashboard patches, duplicate OperatorGroup guard, gateway helpers |

## Phases

Each phase has step-by-step instructions, status gates, and troubleshooting in [`docs/`](docs/).

### Installation (platform)

| Phase | Description | Time |
|-------|-------------|------|
| [1. Prerequisites](docs/01-prerequisites.md) | Operators (RHOAI, RHCL, cert-manager, LWS) | 5–10 min |
| [2. Platform Configuration](docs/02-platform-config.md) | Kuadrant/Authorino, UWM, GatewayClass, MaaS gateway (**2Gi** proxy memory) | 5–10 min |
| [3. MaaS Platform](docs/03-maas-platform.md) | PostgreSQL and secrets | ~5 min |
| [4. RHOAI Configuration](docs/04-rhoai-config.md) | DSC `modelsAsService: Managed`, dashboard flags, wait for `maas-api` | 5–10 min |

### Models & verification

| Phase | Description | Time |
|-------|-------------|------|
| [5. Model Deployment](docs/05-maas-models.md) | Bundled models **or** GUI / manual MaaS registration | 1–15 min |
| [6. Verification](docs/06-verification.md) | API keys, inference, rate limits (`verify.sh`) | ~5 min |
| [8. External Models](docs/08-external-models.md) *(optional)* | OpenAI-compatible / IBM RHAI — **no local inference** | 5–15 min |

### Optional

| Phase | Description |
|-------|-------------|
| [7. Observability](docs/07-observability.md) | COO + gateway telemetry (`--with-observability`) |
| [9–10. GUIs](docs/09-optional-guis.md) | Compact MaaS (`--with-compact-maas`) or LiteMaaS (`--with-litemaas`) |
| [11. Lago billing](docs/11-lago-billing.md) | Budget entities, usage, graduated throttling (`--with-lago-billing`) |

## Automated setup

Phases are idempotent — re-running skips completed work.

```bash
# Platform + bundled model + verification (default)
./scripts/setup-maas.sh

# Platform only — use before GUI deploy or custom catalog models (e.g. Gemma)
./scripts/setup-maas.sh --skip-models

# Resume after failure
./scripts/setup-maas.sh --from-phase 4
```

Common flags: `--model simulator|granite-tiny-gpu|gpt-oss-20b|auto`, `--skip-verify`, `--with-observability`, `--with-compact-maas`, `--with-litemaas`, `--with-lago-billing`, `--dry-run`. See [quick-start](docs/quick-start.md).

**Script helpers (Phases 2 & 4):** syncs `default-gateway-tls` for external inference, applies **2Gi** Istio proxy limits on `maas-default-gateway`, `data-science-gateway`, and `openshift-ai-inference` (see `manifests/02-platform-config/`).

## Choosing a model deployment path

Phases **1–4** install the MaaS **platform** only. A model appears in the catalog after **registration** (Phase 5, **Publish as MaaS**, or manual YAML).

| Path | When to use | Action |
|------|-------------|--------|
| **A — Full script** | Quick validation with a bundled model | `./scripts/setup-maas.sh` or `--model simulator` |
| **B — Script + GUI** | Custom catalog model (e.g. Gemma) on GPU | `./scripts/setup-maas.sh --skip-models` → deploy in dashboard with **Publish as MaaS** |
| **C — Register existing** | Model deployed before MaaS was ready | Label namespace, patch gateway, apply `MaaSModelRef` / policy / subscription — [Phase 5 § Register existing](docs/05-maas-models.md#register-existing-gui-model) |
| **D — External only** | No in-cluster GPU | `./scripts/setup-maas.sh --skip-models` → [Phase 8](docs/08-external-models.md) |

**GUI order:** deploy models **after** `maas-api` is healthy (`curl -sk https://maas.<domain>/maas-api/health`). Deploying earlier yields inference-only on `inference-gateway` (OpenShift token), not MaaS API keys.

**Phase 5 skip:** if *any* `LLMInferenceService` exists cluster-wide, Phase 5 is skipped — it does **not** auto-register existing GUI models.

**Subscriptions:** Phase 5 and **Publish as MaaS** create `MaaSSubscription` + `MaaSAuthPolicy`. Default tier allows `system:authenticated` (any logged-in user can mint `*-free` keys).

### RHOAI 3.5 dashboard

Under **Gen AI Studio**:

- **AI asset endpoints → Models** — deployed models; MaaS-published models show a **Model as a Service** badge (one model may list two URL forms — namespace path and `publishers/…/models/…` — that is normal).
- **API keys** — sibling menu item (not inside AI asset endpoints).

## Test inference with a MaaS API key

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MAAS_URL="https://maas.${CLUSTER_DOMAIN}"

API_KEY=$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"test","subscription":"<your-subscription>","expiresIn":"1h"}' \
  | jq -r '.key')

MODEL_ID=$(curl -sk "${MAAS_URL}/v1/models" \
  -H "Authorization: Bearer ${API_KEY}" | jq -r '.data[0].id')

curl -sk "${MAAS_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}"
```

Use `.key` (not `.token`). List models at `/v1/models`; infer at `/v1/chat/completions` with the `id` from the listing. Subscription name must match a `MaaSSubscription` (e.g. `redhataigemma-4-e4b-it-free` for a manually registered Gemma).

Helper: `./scripts/test-inference.sh --base-url "${MAAS_URL}" --api-key "${API_KEY}" --model "${MODEL_ID}"`

## Bundled models (Phase 5 only)

| Model | GPU | VRAM | Use case |
|-------|-----|------|----------|
| `simulator` | No | — | CPU validation |
| `granite-tiny-gpu` | Yes | &lt; 40 GiB | T4, L4, A10 |
| `gpt-oss-20b` | Yes | ≥ 40 GiB | L40S, A100, H100 |

## External models

```bash
./scripts/setup-maas.sh --skip-models --with-compact-maas   # optional GUI

# OpenAI, OpenRouter, or IBM RHAI (see --help for --preset)
# Default: validates upstream + BBR reload + gateway E2E on first model (--skip-validate to register only)
./scripts/import-external-models.sh --preset openai \
  --api-key "$OPENAI_API_KEY" --namespace llm --all

./scripts/import-external-models.sh --preset openrouter \
  --api-key "$OPENROUTER_API_KEY" --namespace llm --all
```

Details: [docs/08-external-models.md](docs/08-external-models.md).

## Troubleshooting (quick)

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Gateway pods `CrashLoopBackOff` / `OOMKilled` | 1Gi Istio proxy limit | Re-run `./scripts/setup-maas.sh --from-phase 4` or [Phase 2 gateway memory](docs/02-platform-config.md) |
| External inference TLS / listener not programmed | Missing `default-gateway-tls` | Script `ensure_default_gateway_tls()`; see Phase 2 |
| No **Publish as MaaS** in GUI | Model deployed before MaaS ready | Path **C** or redeploy after `--skip-models` |
| API key works for `/v1/models`, inference `401` | ext-proc / payload-processing on gateway | See [Phase 5 troubleshooting](docs/05-maas-models.md); open Red Hat support if persistent |
| External inference `credentials not found in store` | Provider Secret missing `inference.llm-d.ai/ipp-managed` and/or BBR cache stale | [Phase 8 Known Issues](docs/08-external-models.md#credentials-not-found-in-store); re-run import without `--skip-validate` |
| Phase 5 deployed unwanted model | Script auto-picked `auto` | Delete model; use `--skip-models` if GUI model already exists |
| Duplicate OperatorGroup / failed RHOAI CSV | Script + GUI both installed operator | Single `OperatorGroup` in `redhat-ods-operator` |

Verification script: `manifests/06-verification/verify.sh`

## Documentation map

| Resource | Location |
|----------|----------|
| Local guide (Markdown) | [`docs/`](docs/) |
| Published Antora site | https://rh-aiservices-bu.github.io/rhoai-maas-guide/ |
| Architecture / request flow | [docs/08-architecture.md](docs/08-architecture.md) |
| Optional GUIs | [docs/09-optional-guis.md](docs/09-optional-guis.md) |
| Lago billing (Phase 11) | [docs/11-lago-billing.md](docs/11-lago-billing.md) |
| Official RHOAI 3.4 MaaS | https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index |
| Official RHOAI 3.5 MaaS | https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/index |
| Upstream MaaS project | https://opendatahub-io.github.io/models-as-a-service/latest/ |

## License

Apache License 2.0 — [LICENSE](LICENSE) (same as upstream `rh-aiservices-bu/rhoai-maas-guide`).

Sibling products: **Compact MaaS** — AGPL-3.0-only; **litemaas-rhoai** — AGPL-3.0-only.
