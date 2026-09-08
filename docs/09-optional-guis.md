# Phase 9–10: Optional GUIs (LiteMaaS and Compact MaaS)

After native RHOAI MaaS is up (phases 1–4 minimum; **local models optional**), you can optionally install one or both GUIs. They live in **separate namespaces** and can coexist.

> **Tip:** For **external-only** clusters (no GPU / no in-cluster vLLM), use `./scripts/setup-maas.sh --skip-models` then [Phase 8](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md) (OpenAI-compatible SaaS, including IBM RHAI path prefixes), then `--with-compact-maas` and/or `--with-litemaas`.

## Product role: Compact MaaS vs RHOAI 3.5 dashboard

**Compact MaaS** is the **customer-facing MaaS portal** (LiteMaaS-shaped): external developers enroll, subscribe, mint, list, and revoke `sk-oai-*` keys **without opening OpenShift AI**. Native MaaS (gateway + `maas-api` + CRs) remains the data plane — Compact MaaS is a thin UI/BFF only.

| Who | Use this UI | For |
|-----|-------------|-----|
| **External API customer** | **Compact MaaS** (`https://compact-maas.<domain>`) | Enroll → subscribe → API keys → usage examples |
| **Platform / cluster admin** | RHOAI **Settings → MaaS governance** *or* Compact **Admin** | Subscriptions, auth policies; Compact Admin adds **ExternalModel** + enrollment approval |
| **Internal researcher** | RHOAI **Gen AI Studio** (Playground, MCP) | Experimentation — not the external API product path |

Compact MaaS does **not** replace native MaaS enforcement (Authorino, Limitador, `MaaSSubscription` patches). It must not break native curl or Gen AI Studio key mint — see [Native MaaS regression](#native-maas-regression-after-compact-maas).

## Which GUI should I use?

|  | **Compact MaaS (recommended product path)** | **LiteMaaS + LiteLLM (PoC)** |
| --- | --- | --- |
| Flag | `--with-compact-maas` | `--with-litemaas` |
| Namespace | `compact-maas` | `litemaas` |
| Architecture | Thin UI/BFF over **native** maas-api + Kuadrant/Limitador | Full stack with **LiteLLM** proxy + Postgres/Redis |
| Inference path | Client → MaaS gateway `/v1/chat/completions` (gateway root) or `/llm/<model>/v1/...` (per-model) | Client → LiteLLM → (usually) MaaS gateway |
| Best for | **External MaaS product** — enroll, keys, external model admin (no RHOAI nav) | Comparing LiteMaaS UX; $ budgets / virtual keys / single base URL |
| Sibling repo | `compact-maas` (`COMPACT_MAAS_DIR`; falls back to `rhoai-maas-console`) | `litemaas-rhoai` (`LITEMAAS_RHOAI_DIR`) |

**Product path:** prefer Compact MaaS. LiteMaaS remains a side-by-side PoC; this guide does not merge LiteLLM into Compact MaaS.

> **Note:** This guide is Apache-2.0. Compact MaaS (`compact-maas` / `rhoai-maas-console`) and the `litemaas-rhoai` deploy wrapper are **AGPL-3.0-only** — see each repo's `LICENSE`/`NOTICE`. Upstream LiteMaaS keeps its own license.

## Prerequisites

- Phases **1–4** complete (`https://maas.<cluster-domain>/maas-api/health` returns healthy). Phase 6 (verification) is recommended but not required to install a GUI.
- Sibling repos checked out **next to** this guide (or set the env vars below).
- `oc` logged in as a user that can create projects / run Helm installs.
- `helm` on PATH (Phase 10 uses Helm to install the console chart).
- For LiteMaaS wire step: a MaaS API key (`MAAS_API_KEY`).

### Clone the Compact MaaS sibling repo

Phase 10 does **not** vendor the console in this guide. Clone one of these repos **next to** `rhoai-maas-guide` (same parent directory):

```bash
cd "$(dirname "$(pwd)")"   # parent of rhoai-maas-guide

# Preferred name (if published):
git clone https://github.com/rh-aiservices-bu/compact-maas.git

# Or the current upstream name (same codebase):
git clone https://github.com/rh-aiservices-bu/rhoai-maas-console.git
```

The script auto-detects `../compact-maas`, then `../rhoai-maas-console`. If your checkout lives elsewhere:

```bash
export COMPACT_MAAS_DIR=/path/to/rhoai-maas-console
```

The directory must contain `scripts/deploy.sh`.

## Automated install

```bash
# MaaS + Compact MaaS (no LiteLLM)
./scripts/setup-maas.sh --with-compact-maas

# MaaS + LiteMaaS/LiteLLM PoC
./scripts/setup-maas.sh --with-litemaas

# Both GUIs
./scripts/setup-maas.sh --with-compact-maas --with-litemaas

# Resume GUI-only after core is done (most common for Compact MaaS)
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas
./scripts/setup-maas.sh --from-phase 9 --with-litemaas

# Explicit sibling path when only rhoai-maas-console is cloned
COMPACT_MAAS_DIR=../rhoai-maas-console ./scripts/setup-maas.sh --from-phase 10 --with-compact-maas
```

> **Timing:** Phase 10 runs **OpenShift binary builds** for backend and frontend inside `compact-maas`. Expect **10–25 minutes** on a typical sandbox cluster (network + build queue), not the 5–15 minute table estimate for Helm-only installs.

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

1. Runs `$COMPACT_MAAS_DIR/scripts/apply-phase2-rbac.sh` when present — creates `mass-admins` / `mass-users` (and legacy `maas-admins`), binds `compact-maas-admin`, and adds the current `oc` user to `mass-admins`.
1. Runs `$COMPACT_MAAS_DIR/scripts/deploy.sh` with `MAAS_GATEWAY_URL=https://maas.<domain>`. `deploy.sh` builds container images in `compact-maas`, installs the Helm chart, applies BBR/ExternalModel RBAC, and re-runs enrollment + metrics RBAC. End-user **Subscribe** works without a separate manual step (`console-enroll.yaml`).
1. Soft-verifies via `./scripts/verify-guis.sh --compact-maas`.

See `manifests/10-compact-maas/README.md`.

Unlike LiteMaaS, Compact MaaS sees models registered on native MaaS (Phase 5, or [Phase 8's import script](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md#after-import)) immediately — it browses the same catalog, no wiring step needed.

### Manual install (Compact MaaS only)

Equivalent to Phase 10 without `setup-maas.sh`:

```bash
export CLUSTER_DOMAIN="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
export MAAS_GATEWAY_URL="https://maas.${CLUSTER_DOMAIN}"
export COMPACT_MAAS_DIR="${COMPACT_MAAS_DIR:-../rhoai-maas-console}"

cd "$COMPACT_MAAS_DIR"
./scripts/apply-phase2-rbac.sh
./scripts/deploy.sh
```

**Config-only fix** (OAuth / enrollment URLs wrong after cluster change — no image rebuild):

```bash
./scripts/fix-compact-maas-config.sh --apply-fix
# alias:
./scripts/reconfigure-compact-maas.sh
```

Phase 10 runs this automatically if OAuth/gateway config does not match the cluster after `deploy.sh`. The console `deploy.sh` also re-applies Helm cluster sets when its built-in verify fails.

> **Note:** Run Helm from **`rhoai-maas-console`** (chart path `deploy/helm/compact-maas`). Running `helm upgrade ... deploy/helm/compact-maas` from **this guide repo** fails with `repo deploy not found`.

**OAuth issuer:** derived from the live `oauth-openshift` route in `openshift-authentication` (not `oauth-openshift.apps.${CLUSTER_DOMAIN}` when `CLUSTER_DOMAIN` already starts with `apps.`).

Console URL when finished:

```bash
oc -n compact-maas get route compact-maas -o jsonpath='https://{.spec.host}{"\n"}'
```

Log in with your OpenShift credentials. **Admin** features require membership in `mass-admins` (or legacy `maas-admins`); `apply-phase2-rbac.sh` adds the user who runs it.

## Manual verify

```bash
./scripts/verify-guis.sh
./scripts/verify-guis.sh --compact-maas
./scripts/verify-guis.sh --litemaas
```

Open the printed route URLs, log in with OpenShift credentials, and confirm the model catalog matches your MaaS subscriptions.

**Compact MaaS:** OpenShift login end-to-end; admin UI for users in `mass-admins` (or `maas-admins`). End-user flow: **Enroll** (if required) → **Subscribe** → **API keys** (mint / list / revoke).

```bash
# After Phase 10 — config + native MaaS regression (key mint via gateway)
./scripts/verify-guis.sh --compact-maas

# If key mint fails (BBR anchor strips /maas-api headers):
./scripts/fix-compact-maas-native-maas.sh          # diagnose
./scripts/fix-compact-maas-native-maas.sh --apply-fix   # re-apply anchor with maas-api bypass

# If login redirects to wrong oauth-openshift host:
./scripts/fix-compact-maas-config.sh --apply-fix
```

## Native MaaS regression after Compact MaaS {#native-maas-regression-after-compact-maas}

Compact MaaS must not break **native** key mint or inference. After every deploy or reconfigure, verify:

```bash
./scripts/verify-guis.sh --compact-maas
```

This mints an ephemeral `sk-oai-*` through the **same gateway path** the Compact MaaS Keys page uses (`POST https://maas.<domain>/maas-api/v1/api-keys` with your OpenShift token).

| Check | Command |
|-------|---------|
| Default (Compact MaaS + native key mint must pass) | `./scripts/verify-guis.sh --compact-maas` |
| Warn only if native key mint fails (legacy soft mode) | `./scripts/verify-guis.sh --compact-maas --soft-native` |
| Diagnose BBR anchor issue | `./scripts/fix-compact-maas-native-maas.sh` |
| Re-apply OAuth/gateway after cluster move | `./scripts/fix-compact-maas-config.sh --apply-fix` |

### Model id for inference (gateway root)

Use the **`id` from `GET /v1/models`**, not the subscription `modelRef` name:

| Backend | Subscription `modelRefs.name` | JSON `model` at `/v1/chat/completions` |
|---------|------------------------------|----------------------------------------|
| External (imported) | `codellama-7b-instruct` | Same short name |
| In-cluster (Gemma) | `gemma-4-e4b-it` | `publishers/llm/models/gemma-4-e4b-it` |

Compact MaaS usage examples should show gateway root + catalog `id` (see [Compact MaaS enhancements](./compact-maas-enhancements.md)).

**LiteMaaS:** OpenShift login for the LiteMaaS shell UI. The LiteLLM proxy underneath has its own separate local `admin` account and master key (used for `wire-maas-models.sh` / `wire-all-ready-models.sh` and the LiteLLM proxy API) — see `litemaas-rhoai`'s docs/auth-notes.md, "Retrieving LiteLLM admin credentials".

## Compact MaaS troubleshooting

| Symptom | Check |
| --- | --- |
| Phase 10 aborts: sibling repo missing | Clone `compact-maas` or `rhoai-maas-console` next to this guide, or set `COMPACT_MAAS_DIR` |
| Build stuck / slow | `oc -n compact-maas get builds,pods` — OpenShift builds run in-cluster |
| Admin UI 403 | `oc get group mass-admins -o yaml` — add user: `oc adm groups add-users mass-admins <user>` |
| Subscribe 403 on ConfigMap | Re-run `deploy.sh` (applies `console-enroll.yaml`) or `oc apply -f deploy/rbac/console-enroll.yaml` from the sibling repo |
| OpenShift login → `DNS_PROBE_FINISHED_NXDOMAIN` on `oauth-openshift.*` | Stale OAuth URLs — `./scripts/fix-compact-maas-config.sh --apply-fix` (issuer is read from the `oauth-openshift` route, not double-prefixed `apps.apps.*`) |
| Enrollment form: `justification` too small | **Justification** must be **≥ 10 characters** (e.g. `Need access for Gemma MaaS testing.`). After submit, a **mass-admins** user approves under **Admin → Enrollment**. |
| Enrollment approves but wrong subscription | Default is auto-detected from the cluster on `deploy.sh` (`gemma` on this cluster). Override with `ENROLLMENT_DEFAULT_SUBSCRIPTION` / `ENROLLMENT_DEFAULT_MODEL` before deploy. |
| Models card shows **No subscriptions for this model** but Admin has `gemma` | Catalog id (`publishers/.../models/<name>`) vs short `modelRef` name mismatch in Subscribe/Keys — fixed in newer `rhoai-maas-console`. **Workaround now:** open **API keys** with `?subscription=gemma` or mint via curl (below). Rebuild console: `cd ../rhoai-maas-console && ./scripts/deploy.sh` |
| ExternalModel Chat 401/404 | Re-run `scripts/fix-payload-processing-envoyfilter.sh` from the sibling repo (also run at end of `deploy.sh`) |
| **API key create** fails with `AUTH_FAILURE` / HTTP 500; list/search works | `compact-maas-bbr-anchor` ran ext_proc on `/maas-api/*` (check maas-api logs for `X-MaaS-Username=absent`). **Fix:** `./scripts/fix-compact-maas-native-maas.sh --apply-fix` re-applies the anchor with maas-api bypass (Phase 10 auto-runs if verify fails). **Verify:** `./scripts/verify-guis.sh --compact-maas`. **In-cluster workaround:** curl block below |
| Catalog empty | Native MaaS must have `MaaSModelRef` resources — deploy/publish a model or import external models first |

**API key create workaround** (when gateway header injection is broken; replace `admin` / groups with your OpenShift user):

```bash
oc run maas-key-mint --rm -i --restart=Never -n redhat-ai-gateway-infra \
  --image=curlimages/curl:latest --command -- \
  curl -sk -X POST "https://maas-api.redhat-ai-gateway-infra.svc:8443/v1/api-keys" \
  -H "X-MaaS-Username: admin" \
  -H 'X-MaaS-Group: ["system:authenticated","rhods-admins"]' \
  -H "Content-Type: application/json" \
  -d '{"name":"nueva","subscription":"gemma","expiresIn":"90d"}'
```

Save the `key` / `token` field from the JSON response — it is shown only once.

## Removing a model registered through a GUI

Deleting an `ExternalModel` from Compact MaaS Admin (or via `oc`) does not automatically clean up a LiteMaaS/LiteLLM wiring of that same model — LiteLLM keeps a separate registry. See [Removing an external model](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md#removing-an-external-model) for the full ordered teardown (governance CRs → model refs → HTTPRoute → credential Secret → LiteLLM entry).

## Compact MaaS — Track 1 (product core + native safety)

**Vision:** LiteMaaS-shaped **external MaaS portal** — enroll, subscribe, mint/list/revoke keys — plus admin ExternalModel. **Not** a replacement for Gen AI Studio or native MaaS.

| Track 1 item | Status in this guide | Upstream (`rhoai-maas-console`) |
|--------------|----------------------|--------------------------------|
| Product scope docs | ✅ [09-optional-guis.md](./09-optional-guis.md) | Admin/user copy alignment |
| Native regression verify | ✅ `verify-guis.sh --compact-maas` (always tests key mint; `--soft-native` to warn only) | — |
| BBR anchor diagnose/fix | ✅ `fix-compact-maas-native-maas.sh` | **P0:** anchor skips `/maas-api/*` |
| Gateway-root usage examples | Documented | **E1/E3** BFF `gateway-root` mode |
| Model id clarity (sub name vs catalog `id`) | Documented | **E4** Keys / Chat UI |

Future work (BFF flag, usage examples, admin bundle UX) remains in [Compact MaaS enhancements](./compact-maas-enhancements.md). Until `gateway-root` ships in the console, use the native curl pattern below with keys minted from Compact MaaS.

## Optional billing (Phase 11 — Lago, recommended)

**Lago** is the primary optional billing layer for this guide. It provides commercial metering, wallets, invoices, and a built-in UI; enforcement still patches native `MaaSSubscription` CRs.

| | **Compact MaaS** | **Lago billing** |
| --- | --- | --- |
| Flag | `--with-compact-maas` | `--with-lago-billing` |
| Namespace | `compact-maas` | `lago` + `maas-billing` |
| Purpose | Catalog, subscribe, API keys | Budget entities, usage, graduated throttling |
| Requires Phase 7 | No | **Yes** (auto-installed if missing) |
| Can combine? | Yes — common product path | `./scripts/setup-maas.sh --with-compact-maas --with-lago-billing` |

See [Phase 11: Lago billing](./11-lago-billing.md) and `manifests/11-lago/README.md`.

## Optional billing (Phase 12 — OpenMeter, alternative)

**OpenMeter** is an Apache-2.0 alternative to Lago — same budget-entity enforcement model (`maas-billing-api`, `usage-reporter`, `budget-enforcer`), different metering ingest (CloudEvents). Prefer **Lago** unless you need Apache-only metering without Lago’s commercial UI.

| | **Compact MaaS** | **OpenMeter billing** |
| --- | --- | --- |
| Flag | `--with-compact-maas` | `--with-openmeter-billing` |
| Namespace | `compact-maas` | `openmeter` + `maas-billing` |
| Purpose | Catalog, subscribe, API keys | Budget entities, grants, graduated throttling |
| Requires Phase 7 | No | **Yes** (auto-installed if missing) |
| vs Lago | — | Pick **one** billing backend per cluster |

```bash
./scripts/setup-maas.sh --from-phase 12 --with-openmeter-billing
./scripts/install-openmeter-billing.sh
```

See [Phase 12: OpenMeter billing](./12-openmeter-billing.md) and `manifests/12-openmeter/README.md`.
