# Phase 9–10: Optional GUIs (LiteMaaS and Compact MaaS)

After native RHOAI MaaS is up (phases 1–4 minimum; **local models optional**), you can optionally install one or both GUIs. They live in **separate namespaces** and can coexist.

> **Tip:** For **external-only** clusters (no GPU / no in-cluster vLLM), use `./scripts/setup-maas.sh --skip-models` then [Phase 8](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md) (OpenAI-compatible SaaS, including IBM RHAI path prefixes), then `--with-compact-maas` and/or `--with-litemaas`.

## Which GUI should I use?

|  | **Compact MaaS (recommended product path)** | **LiteMaaS + LiteLLM (PoC)** |
| --- | --- | --- |
| Flag | `--with-compact-maas` | `--with-litemaas` |
| Namespace | `compact-maas` | `litemaas` |
| Architecture | Thin UI/BFF over **native** maas-api + Kuadrant/Limitador | Full stack with **LiteLLM** proxy + Postgres/Redis |
| Inference path | Client → MaaS gateway `/llm/<model>/v1/...` | Client → LiteLLM → (usually) MaaS gateway |
| Best for | Production-shaped demos on RHOAI MaaS only | Comparing LiteMaaS UX; $ budgets / virtual keys / single base URL |
| Sibling repo | `compact-maas` (`COMPACT_MAAS_DIR`; falls back to `rhoai-maas-console`) | `litemaas-rhoai` (`LITEMAAS_RHOAI_DIR`) |

**Product path:** prefer Compact MaaS. LiteMaaS remains a side-by-side PoC; this guide does not merge LiteLLM into Compact MaaS.

> **Note:** This guide is Apache-2.0. Compact MaaS (`compact-maas` / `rhoai-maas-console`) and the `litemaas-rhoai` deploy wrapper are **AGPL-3.0-only** — see each repo's `LICENSE`/`NOTICE`. Upstream LiteMaaS keeps its own license.

## Prerequisites

- Phases **1–4** complete (`https://maas.<cluster-domain>/maas-api/health` returns healthy). Phase 6 (verification) is recommended but not required to install a GUI.
- Sibling repos checked out **next to** this guide (or set the env vars below).
- `oc` logged in as a user that can create projects / run Helm installs.
- For LiteMaaS wire step: a MaaS API key (`MAAS_API_KEY`).
## Automated install

```bash
# MaaS + Compact MaaS (no LiteLLM)
./scripts/setup-maas.sh --with-compact-maas

# MaaS + LiteMaaS/LiteLLM PoC
./scripts/setup-maas.sh --with-litemaas

# Both GUIs
./scripts/setup-maas.sh --with-compact-maas --with-litemaas

# Resume GUI-only after core is done
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas
./scripts/setup-maas.sh --from-phase 9 --with-litemaas
```

### Environment

| Variable | Meaning |
| --- | --- |
| `COMPACT_MAAS_DIR` | Path to `compact-maas` (default `../compact-maas`, then `../rhoai-maas-console`) |
| `MAAS_CONSOLE_DIR` | Deprecated alias for `COMPACT_MAAS_DIR` |
| `LITEMAAS_RHOAI_DIR` | Path to `litemaas-rhoai` (default `../litemaas-rhoai`) |
| `MAAS_API_KEY` | Optional. When set during Phase 9, runs `wire-maas-models.sh --discover-cluster --all`. This key is **local** to this cluster's MaaS gateway — do not reuse a remote/other-cluster MaaS key here. |
| `MAAS_GATEWAY_URL` | Set automatically by Phase 10 for Compact MaaS Helm (`https://maas.<domain>`) |

## What each phase runs

### Phase 9 — LiteMaaS

1. Calls `$LITEMAAS_RHOAI_DIR/scripts/install.sh` (Helm into `litemaas`).
1. If `MAAS_API_KEY` is set, wires LiteLLM backends to the cluster MaaS gateway (`wire-maas-models.sh --discover-cluster --all`).
1. Soft-verifies namespace/routes via `./scripts/verify-guis.sh --litemaas`.
> **Tip:** LiteMaaS starts with an **empty** model catalog even if models are already registered on native MaaS (Phase 5 or [Phase 8's import script](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md#after-import)) — LiteLLM keeps its own registry. Wire them explicitly with `MAAS_API_KEY` above, or later via `litemaas-rhoai/scripts/wire-all-ready-models.sh` (mints one local MaaS key per `Ready` model and registers it in LiteLLM in one pass) or `wire-maas-models.sh`. See [Compact MaaS vs LiteMaaS after import](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md#after-import).

See `manifests/09-litemaas/README.md`.

### Phase 10 — Compact MaaS

1. Runs `$COMPACT_MAAS_DIR/scripts/apply-phase2-rbac.sh` (maas-admins) when present.
1. Runs `$COMPACT_MAAS_DIR/scripts/deploy.sh` with `MAAS_GATEWAY_URL=https://maas.<domain>`. `deploy.sh` also applies the Phase 3 self-subscribe enrollment RBAC (`console-enroll.yaml`) automatically, so end-user **Subscribe** works without a separate manual RBAC step.
1. Soft-verifies via `./scripts/verify-guis.sh --compact-maas`.
See `manifests/10-compact-maas/README.md`.

Unlike LiteMaaS, Compact MaaS sees models registered on native MaaS (Phase 5, or [Phase 8's import script](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md#after-import)) immediately — it browses the same catalog, no wiring step needed.

## Manual verify

```bash
./scripts/verify-guis.sh
./scripts/verify-guis.sh --compact-maas
./scripts/verify-guis.sh --litemaas
```

Open the printed route URLs, log in with OpenShift credentials, and confirm the model catalog matches your MaaS subscriptions.

> **Note:** That OpenShift login is for the **LiteMaaS** UI, not LiteLLM. The LiteLLM proxy underneath LiteMaaS has its own separate local `admin` account and master key (used for `wire-maas-models.sh` / `wire-all-ready-models.sh` and the LiteLLM proxy API) — see `litemaas-rhoai`'s docs/auth-notes.md, "Retrieving LiteLLM admin credentials".

## Removing a model registered through a GUI

Deleting an `ExternalModel` from Compact MaaS Admin (or via `oc`) does not automatically clean up a LiteMaaS/LiteLLM wiring of that same model — LiteLLM keeps a separate registry. See [Removing an external model](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md#removing-an-external-model) for the full ordered teardown (governance CRs → model refs → HTTPRoute → credential Secret → LiteLLM entry).
