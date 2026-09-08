---
name: install-maas
description: Install MaaS (Models as a Service) on a connected RHOAI cluster using this guide's Kustomize manifests and automation scripts.
argument-hint: "[--model simulator|granite-tiny-gpu|gpt-oss-20b|auto] [--from-phase N] [--skip-models] [--skip-verify] [--with-observability] [--with-compact-maas] [--with-litemaas] [--with-lago-billing]"
allowed-tools: Bash(oc *), Bash(./*), Bash(envsubst *), Bash(curl *), Bash(jq *), Bash(grep *), Bash(ls *), Bash(cat *), Bash(date *), Bash(mkdir *), Bash(echo *), Bash(bash *), AskUserQuestion
---

# Install MaaS on Connected RHOAI Cluster

Install Models as a Service on OpenShift with RHOAI using `./scripts/setup-maas.sh`.

**Phases 1–4** = MaaS platform only. **Phase 5** deploys one **bundled** model (`simulator`, `granite-tiny-gpu`, `gpt-oss-20b`) unless any `LLMInferenceService` already exists — use `--skip-models` before GUI deploy or custom catalog models (e.g. Gemma).

## Primary Entry Point

```bash
./scripts/setup-maas.sh [OPTIONS]
```

## Arguments

- `--model <name>` — `simulator` | `granite-tiny-gpu` | `gpt-oss-20b` | `auto` (default: `auto`)
- `--from-phase <N>` — Start from phase N (0–10; 9–10 = optional GUIs)
- `--skip-models` — Skip Phase 5 (platform-only)
- `--skip-verify` — Skip Phase 6
- `--with-observability` — Phase 7
- `--with-compact-maas` — Phase 10
- `--with-litemaas` — Phase 9
- `--with-lago-billing` — Phase 11 (auto Phase 7 gateway telemetry if missing)
- `--skip-lago-platform` — Phase 11 without Lago Helm (external Lago)
- `--dry-run` — Preview only

## Phases

| Phase | What it does |
|-------|-------------|
| 0 | Preflight |
| 1 | Operators (RHOAI, RHCL, cert-manager, LWS) |
| 2 | Platform (Kuadrant, UWM, GatewayClass, MaaS gateway, 2Gi proxy memory, `default-gateway-tls`) |
| 3 | PostgreSQL + secrets |
| 4 | DSC `modelsAsService: Managed`, dashboard flags, wait for `maas-api` |
| 5 | Bundled model + MaaS registration — **skipped** if any `LLMInferenceService` exists |
| 6 | `verify.sh` E2E |
| 7 | Observability (optional) |
| 9–10 | LiteMaaS / Compact MaaS GUIs (optional) |
| 11 | Lago billing scaffold (optional; auto Phase 7) |

## Common patterns

```bash
# Platform only — then GUI with Publish as MaaS
./scripts/setup-maas.sh --skip-models

# Full bundled validation
./scripts/setup-maas.sh --model simulator

# Resume
./scripts/setup-maas.sh --from-phase 4

# Compact MaaS only (after phases 1–4 + model registered)
# Clone ../rhoai-maas-console or ../compact-maas next to this guide first
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas
./scripts/verify-guis.sh --compact-maas   # fails if native key mint broken
```

**Compact MaaS sibling repo:** `../compact-maas` or `../rhoai-maas-console` (set `COMPACT_MAAS_DIR` if elsewhere). Phase 10 runs OpenShift builds — allow **10–25 min**.

**Lago billing:** `./scripts/setup-maas.sh --from-phase 11 --with-lago-billing` — installs Phase 7 gateway telemetry if missing, then Lago Helm + `maas-billing` base.

## Inference test (after model registered)

```bash
MAAS_URL="https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
API_KEY=$(curl -sk -X POST "${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "Content-Type: application/json" \
  -d '{"name":"test","subscription":"<sub>","expiresIn":"1h"}' | jq -r '.key')
MODEL_ID=$(curl -sk "${MAAS_URL}/v1/models" -H "Authorization: Bearer ${API_KEY}" | jq -r '.data[0].id')
curl -sk "${MAAS_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":20}"
```

Use `.key` (not `.token`). List at `/v1/models`; infer at `/v1/chat/completions`.

## Troubleshooting

- **Duplicate OperatorGroup** in `redhat-ods-operator` — keep one; see Phase 4 docs
- **Gateway OOM** — all three gateways need 2Gi; re-run `--from-phase 4`
- **maas-api** — RHOAI 3.5+: namespace `redhat-ai-gateway-infra`; 3.4: `redhat-ods-applications`
- **GUI model not in MaaS** — deploy after `maas-api` healthy; or register manually (Phase 5 Path C)

## Final Report

Script prints RHOAI version, MaaS URL, gateway status, health check, and next steps.
