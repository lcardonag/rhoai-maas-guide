# Automated Setup

`setup-maas.sh` automates Phases 0–6 (operators through verification). Phases **1–4** install the MaaS **platform** only. Phase **5** deploys one **bundled** model (`simulator`, `granite-tiny-gpu`, or `gpt-oss-20b`) unless any `LLMInferenceService` already exists — use `--skip-models` for GUI or custom catalog models (e.g. Gemma). Each phase is idempotent; re-running skips what's already done.

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

## Clone and Run

```bash
git clone https://github.com/rh-aiservices-bu/rhoai-maas-guide.git
cd rhoai-maas-guide
./scripts/setup-maas.sh
```

This runs Phases 0–6 by default. Phase 5 is skipped when any `LLMInferenceService` exists cluster-wide. The script detects what's already installed and skips completed phases.

## Arguments

| Option | Description | Default |
| --- | --- | --- |
| `--model <name>` | Model to deploy: `simulator` (CPU), `granite-tiny-gpu` (small GPU), `gpt-oss-20b` (large GPU), `auto` (auto-detect by GPU VRAM) | `auto` |
| `--from-phase <N>` | Start from phase N (0-12), skipping earlier phases | `0` |
| `--skip-models` | Skip Phase 5 (model deployment) |  |
| `--skip-verify` | Skip Phase 6 (verification) |  |
| `--with-observability` | Also run Phase 7 (COO + Gateway telemetry) |  |
| `--with-litemaas` | Also run Phase 9 (LiteMaaS + LiteLLM PoC; sibling `litemaas-rhoai`) |  |
| `--with-compact-maas` | Also run Phase 10 (Compact MaaS; sibling `compact-maas` or `rhoai-maas-console`) |  |
| `--with-lago-billing` | Also run Phase 11 (Lago + maas-billing scaffold; auto Phase 7 if telemetry missing) |  |
| `--skip-lago-platform` | With Phase 11: skip Lago Helm (external Lago) |  |
| `--with-openmeter-billing` | Also run Phase 12 (OpenMeter + maas-billing scaffold; auto Phase 7 if telemetry missing) |  |
| `--skip-openmeter-platform` | With Phase 12: skip OpenMeter Helm (external OpenMeter) |  |
| `--dry-run` | Preview what would be applied without making changes |  |

## Phases

| Phase | What it does | Time |
| --- | --- | --- |
| 0 | Preflight - detect cluster state, decide which phases to run | instant |
| 1 | Operators - `oc apply -k manifests/01-prerequisites/operators/`, wait for CSVs | 2-5 min |
| 2 | Platform - Kuadrant, UWM, GatewayClass, envsubst Gateway | 2-5 min |
| 3 | MaaS Platform - PostgreSQL secrets/deployment | 2-3 min |
| 4 | RHOAI - DSC with modelsAsService: Managed, Dashboard flags, wait for maas-api | 3-5 min |
| 5 | Model - deploy one bundled model (`simulator`, `granite-tiny-gpu`, or `gpt-oss-20b`) **and** register with MaaS (`MaaSModelRef`, auth policy, subscriptions). Skipped if any `LLMInferenceService` already exists. | 0.5-15 min |
| 6 | Verify - 6-phase E2E (API, auth, rate limits, cleanup) | 3-5 min |
| 7 | Observability - COO subscription + Gateway TelemetryPolicy | 2-3 min |
| 9 | LiteMaaS + LiteLLM (optional) - sibling install into `litemaas` | 5-15 min |
| 10 | Compact MaaS (optional) - thin native UI into `compact-maas` (OpenShift image builds) | 10-25 min |
| 11 | Lago billing (optional) - Lago Helm + `maas-billing` base; auto Phase 7 if needed | 15-30 min |
| 12 | OpenMeter billing (optional) - OpenMeter Helm + `maas-billing`; auto Phase 7 if needed | 20-40 min |

Pick **one** billing backend per cluster (**Lago recommended** for commercial UX; OpenMeter is an Apache-2.0 alternative). `setup-maas.sh` refuses to install the second backend while the first is present and prints removal steps.

### Switch from OpenMeter to Lago

If Phase 12 (OpenMeter) is already installed:

```bash
./scripts/uninstall-openmeter-billing.sh
./scripts/setup-maas.sh --from-phase 11 --with-lago-billing
./scripts/verify-lago.sh
```

See [Lago billing](./11-lago-billing.md#switch-from-openmeter-to-lago) for enrollment and tier template notes.

## Common Usage Patterns

### Full installation (recommended)

For a fresh cluster with no MaaS components:

```bash
./scripts/setup-maas.sh
```

### With observability

```bash
./scripts/setup-maas.sh --with-observability
```

### With optional GUIs

```bash
./scripts/setup-maas.sh --with-compact-maas
./scripts/setup-maas.sh --with-litemaas
# Or both:
./scripts/setup-maas.sh --with-compact-maas --with-litemaas
```

See [Optional GUIs](./09-optional-guis.md) for sibling repo clone paths and when to choose each.

GUI-only after core MaaS is already installed:

```bash
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas
# If only rhoai-maas-console is cloned:
COMPACT_MAAS_DIR=../rhoai-maas-console ./scripts/setup-maas.sh --from-phase 10 --with-compact-maas

# After deploy (~10–25 min): verify Compact MaaS + native key mint (must pass)
./scripts/verify-guis.sh --compact-maas
# If key mint fails: ./scripts/fix-compact-maas-native-maas.sh [--apply-fix]
```

### Lago billing (optional, standalone or with Compact MaaS)

```bash
./scripts/setup-maas.sh --from-phase 11 --with-lago-billing
# or
./scripts/install-lago-billing.sh

# With product console
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas --with-lago-billing
```

Phase 11 installs **Phase 7 gateway telemetry** automatically when `TelemetryPolicy/maas-telemetry` is missing (required for the future `usage-reporter`). See [Lago billing](./11-lago-billing.md).

### OpenMeter billing (optional Apache-2.0 alternative to Lago)

```bash
./scripts/setup-maas.sh --from-phase 12 --with-openmeter-billing
# or
./scripts/install-openmeter-billing.sh

# With Compact MaaS
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas --with-openmeter-billing
```

See [OpenMeter billing](./12-openmeter-billing.md). Do not combine `--with-lago-billing` and `--with-openmeter-billing` on the same cluster. To migrate to Lago, run `./scripts/uninstall-openmeter-billing.sh` first.

### Platform first, then GUI model (custom catalog weights)

For models not in Phase 5 (e.g. Gemma from the model catalog), install the platform before deploying in the dashboard:

```bash
./scripts/setup-maas.sh --skip-models
```

Wait until `maas-api` is healthy, then deploy in the OpenShift AI dashboard with **Publish as MaaS** enabled in Advanced settings. If MaaS was not ready at deploy time, that option is missing and the model is inference-only until you register it manually — see [Register an existing GUI-deployed model](./05-maas-models.md#register-existing-gui-model).

### External-only (no local inference)

```bash
./scripts/setup-maas.sh --skip-models --with-compact-maas
```

Then register OpenAI-compatible SaaS or IBM RHAI models per [Phase 8: External Models](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md) (Compact MaaS Admin **Upstream path prefix**, or YAML templates under `manifests/08-external-models/openai-compatible-prefixed/`).

### Resume from a specific phase

If a previous run failed at Phase 4:

```bash
./scripts/setup-maas.sh --from-phase 4
```

### Models only

If the platform is already installed and you want a **bundled** guide model (`simulator`, `granite-tiny-gpu`, or `gpt-oss-20b`):

```bash
./scripts/setup-maas.sh --from-phase 5
```

Or use the standalone model script for more control:

```bash
./scripts/deploy-model.sh --model simulator
```

### Verify only

```bash
./scripts/setup-maas.sh --from-phase 6
```

Or directly:

```bash
./manifests/06-verification/verify.sh
```

## Convenience Scripts

These wrap individual phases for standalone use:

| Script | What it does |
| --- | --- |
| `scripts/deploy-model.sh` | Phase 5 only - deploy a model with GPU auto-detection |
| `scripts/test-inference.sh` | Send inference requests to a deployed model endpoint |
| `scripts/verify-maas.sh` | Phase 6 only - wrapper for `manifests/06-verification/verify.sh` |

## State Detection

Phase 0 inspects the cluster and reports what's already installed. The script uses this to skip completed phases:

- Operators installed? Skip Phase 1.
- Kuadrant + UWM + Gateway ready? Skip Phase 2.
- PostgreSQL running? Skip Phase 3.
- DSC with `modelsAsService: Managed` + `maas-api` running? Skip Phase 4.
- Any `LLMInferenceService` in the cluster? Skip Phase 5 (does not register existing GUI models).
Override with `--from-phase N` to force re-running from a specific phase.

## AI-Assisted Installation

If you use an AI coding tool ([Claude Code](https://claude.ai/code), [Open Code](https://opencode.ai), [Cursor](https://cursor.com), [Roo Code](https://roosoft.com)), the `/install-maas` skill wraps the same script with an interactive, AI-assisted workflow. Clone the repo, open it in your tool, and run:

```
/install-maas
```

Or with arguments:

```
/install-maas --model simulator --with-observability
```

See [AI-Assisted Installation](./claude-code.md) for details.

## Final Report

The script ends with a summary: RHOAI version, MaaS API URL, Gateway status, health check, deployed models, and suggested next steps.
