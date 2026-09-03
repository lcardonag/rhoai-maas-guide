# RHOAI Models-as-a-Service (MaaS) Guide

Guide to deploy Red Hat OpenShift AI Models as a Service on OpenShift. **Targets RHOAI 3.4**; also exercised on **RHOAI 3.5** (dashboard nav, `maas-api` in `redhat-ai-gateway-infra`, gateway memory fixes).

- Kustomize manifests with status gates between every phase
- Automation script: Phases **1–4** = MaaS platform; models are a **separate** step (Phase 5, GUI, or manual register)
- CPU-only **simulator** for validation without GPUs
- Local reference: [Phase 8 — External Models](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md) (Markdown)
Requires OpenShift 4.19+ with cluster-admin access.

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI 3.4 Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index) or the [3.5 equivalent](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts.

## Getting Started

Clone the repository and work from its root directory. All commands and file paths in this guide are relative to the cloned repo.

```bash
git clone https://github.com/rh-aiservices-bu/rhoai-maas-guide.git
cd rhoai-maas-guide
```

You also need:

- OpenShift 4.19+ cluster with `oc` CLI authenticated as cluster-admin
- `envsubst`, `curl`, `jq` available on PATH
## Phases

Each phase has step-by-step instructions, status gates, and troubleshooting.

### Installation Guide

| Phase | Description | Time |
| --- | --- | --- |
| [1. Prerequisites](./01-prerequisites.md) | Operator subscriptions (RHOAI, RHCL, cert-manager, LWS) | 5-10 min |
| [2. Platform Configuration](./02-platform-config.md) | Kuadrant/Authorino, UWM, GatewayClass, MaaS gateway (2Gi proxy memory, `default-gateway-tls`) | 5-10 min |
| [3. MaaS Platform](./03-maas-platform.md) | PostgreSQL database and secrets | 5 min |
| [4. RHOAI Configuration](./04-rhoai-config.md) | DataScienceCluster, DSCInitialization, Dashboard settings | 5-10 min |

### Model Deployment & Verification

| Phase | Description | Time |
| --- | --- | --- |
| [5. Model Deployment](./05-maas-models.md) | Bundled models only (`simulator`, `granite-tiny-gpu`, `gpt-oss-20b`) **or** GUI **Publish as MaaS** / manual register. Phase 5 skipped if any `LLMInferenceService` exists. | 1-15 min |
| [6. Verification](./06-verification.md) | End-to-end checks (API keys, inference, rate limiting) | 5 min |

### Observability

| Phase | Description | Time |
| --- | --- | --- |
| [7. Observability](./07-observability.md) _(optional)_ | COO subscription + Gateway telemetry dashboards | 5 min |

### External Models

| Phase | Description | Time |
| --- | --- | --- |
| [8. External Models](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md) _(optional)_ | Expose third-party LLM APIs (OpenAI, Bedrock, Gemini) through the MaaS gateway | 5-10 min |

## Choosing a model deployment path

Phases **1–4** install the platform only. See [Automated Setup](./quick-start.md) and [Phase 5](./05-maas-models.md) for details.

| Path | When | Action |
| --- | --- | --- |
| **A — Full script** | Quick validation with a bundled model | `./scripts/setup-maas.sh` or `--model simulator` |
| **B — Script + GUI** | Custom catalog model (e.g. Gemma) | `./scripts/setup-maas.sh --skip-models` → deploy with **Publish as MaaS** |
| **C — Register existing** | Model deployed before MaaS was ready | [Manual MaaS registration](./05-maas-models.md#register-existing-gui-model) |
| **D — External only** | No in-cluster GPU | `--skip-models` → [Phase 8](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md) |

**RHOAI 3.5 dashboard:** **Gen AI Studio → AI asset endpoints** (Models) and **API keys** (sibling menu). One model may show two URL forms — that is normal.

## Automated Setup

For end-to-end deployment using a single script, see the [Automated Setup](./quick-start.md) page.

## Available Models

| Model | GPU Required | VRAM | Use Case |
| --- | --- | --- | --- |
| `simulator` | No | None | Testing/demo (CPU-only) |
| `granite-tiny-gpu` | Yes | < 40 GiB | Small GPU (T4, L4, A10) |
| `gpt-oss-20b` | Yes | >= 40 GiB | Large GPU (L40S, A100, H100) |

## Documentation

- [RHOAI 3.4 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index)
- [RHOAI 3.5 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/govern_llm_access_with_models-as-a-service/index)
- [Upstream MaaS Documentation](https://opendatahub-io.github.io/models-as-a-service/latest/)
- [Upstream MaaS Architecture](https://opendatahub-io.github.io/models-as-a-service/latest/concepts/architecture/)
