# RHOAI Models-as-a-Service (MaaS) Guide

Guide to deploy RHOAI 3.4 Models-as-a-Service on OpenShift.

- Kustomize manifests with status gates between every phase
- Single automation script for end-to-end deployment
- CPU-only simulator model for validation without GPUs

Requires OpenShift 4.19+ with cluster-admin access.

> **Note:** This guide is not a replacement for the [official RHOAI 3.4 Models-as-a-Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

**Full documentation:** https://rh-aiservices-bu.github.io/rhoai-maas-guide/
**GitHub Repository** https://github.com/rh-aiservices-bu/rhoai-maas-guide

## Phases

Each phase has step-by-step instructions, status gates, and troubleshooting.

### Installation Guide

| Phase | Description | Time |
|-------|-------------|------|
| [1. Prerequisites](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/01-prerequisites.html) | Operator subscriptions (RHOAI, RHCL, cert-manager, LWS) | 5-10 min |
| [2. Platform Configuration](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/02-platform-config.html) | Kuadrant/Authorino, User Workload Monitoring, GatewayClass, Gateway | 5-10 min |
| [3. MaaS Platform](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/03-maas-platform.html) | PostgreSQL database and secrets | 5 min |
| [4. RHOAI Configuration](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/04-rhoai-config.html) | DataScienceCluster, DSCInitialization, Dashboard settings | 5-10 min |

### Model Deployment & Verification

| Phase | Description | Time |
|-------|-------------|------|
| [5. Model Deployment](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/05-maas-models.html) | Deploy and register LLM models with MaaS | 1-15 min |
| [6. Verification](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/06-verification.html) | End-to-end checks (API keys, inference, rate limiting) | 5 min |
| [8. External Models](content/modules/ROOT/pages/08-external-models.adoc) *(optional)* | OpenAI-compatible SaaS / IBM RHAI — **no local inference** | 5-15 min |

### Observability

| Phase | Description | Time |
|-------|-------------|------|
| [7. Observability](https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/07-observability.html) *(optional)* | COO subscription + Gateway telemetry dashboards | 5 min |

### Optional GUIs

| Phase | Description | Flag |
|-------|-------------|------|
| 9. LiteMaaS + LiteLLM | PoC GUI with LiteLLM proxy (`litemaas` ns) | `--with-litemaas` |
| 10. MaaS Console | Thin native MaaS UI/BFF, **no LiteLLM** (`rhoai-maas-console` ns) | `--with-maas-console` |

Both GUIs are independent and can coexist. **Recommended product path:** MaaS Console. LiteMaaS is for PoC / proxy features ($ budgets, virtual keys). See [Optional GUIs](content/modules/ROOT/pages/09-optional-guis.adoc).

Sibling checkouts (or set env):

| Env | Default |
|-----|---------|
| `LITEMAAS_RHOAI_DIR` | `../litemaas-rhoai` |
| `MAAS_CONSOLE_DIR` | `../rhoai-maas-console` |

## Automated Setup

A single script runs all phases end-to-end. Each phase is idempotent - re-running skips what is already done.

```bash
./scripts/setup-maas.sh
```

Resume from a specific phase after a failure:

```bash
./scripts/setup-maas.sh --from-phase 4
```

With observability (Cluster Observability Operator + Gateway telemetry):

```bash
./scripts/setup-maas.sh --with-observability
```

Optional GUIs (after MaaS is up, or in the same run):

```bash
./scripts/setup-maas.sh --with-maas-console
./scripts/setup-maas.sh --with-litemaas
./scripts/setup-maas.sh --with-maas-console --with-litemaas
```

External-only (no local inference servers) + Console:

```bash
./scripts/setup-maas.sh --skip-models --with-maas-console
# Then add OpenAI / IBM RHAI ExternalModels — see Phase 8 docs
```

## Available Models

| Model | GPU Required | VRAM | Use Case |
|-------|-------------|------|----------|
| `simulator` | No | None | Testing/demo (CPU-only) |
| `granite-tiny-gpu` | Yes | < 40 GiB | Small GPU (T4, L4, A10) |
| `gpt-oss-20b` | Yes | >= 40 GiB | Large GPU (L40S, A100, H100) |

## Documentation

- [RHOAI 3.4 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index)
- [Upstream MaaS Documentation](https://opendatahub-io.github.io/models-as-a-service/latest/)
- [Upstream MaaS Architecture](https://opendatahub-io.github.io/models-as-a-service/latest/concepts/architecture/)
- Optional GUIs: [content/modules/ROOT/pages/09-optional-guis.adoc](content/modules/ROOT/pages/09-optional-guis.adoc)

## License

See [LICENSE](LICENSE).
