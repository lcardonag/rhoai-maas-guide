# Phase 11: Lago + budget entities + graduated throttling

> **Status:** **MVP in progress** — Phase 11 installer, Lago Helm, `maas-billing-api`, `usage-reporter`, and `budget-enforcer` manifests. Enrollment UI still planned.  
> **Goal:** Enroll solo developers or companies in **Lago** (plans, wallets, invoices), track usage against a monthly budget, and enforce **graduated throttling** on native RHOAI MaaS by **patching one `MaaSSubscription` per entity** — **no API key rotation**.

> **Aligned with:** [Phase 12 OpenMeter plan](./12-openmeter-billing.md) — same budget-entity model, tier templates, and `budget-enforcer` pattern. Lago differs in **commercial UX** (built-in billing UI, Stripe) and **event format**; enforcement on MaaS is identical.

> **Alternative:** [Phase 12 OpenMeter](./12-openmeter-billing.md) — Apache-2.0 metering with the same enforcement model. Pick **one** backend per cluster. To switch from OpenMeter to Lago, see [Switch from OpenMeter to Lago](#switch-from-openmeter-to-lago) below.

> **Pick one backend per cluster:** do not install Phase 11 (Lago) and Phase 12 (OpenMeter) together — both use namespace `maas-billing`.

---

## Principles

1. **Do not replace** Authorino, `maas-api`, or Limitador — they remain the runtime control plane.
2. **Lago owns money** — plans, wallets, usage aggregation, invoices, payments (via Stripe, etc.).
3. **One budget entity = one Lago customer = one MaaS subscription name** — solo dev or company.
4. **Enforcement = patch the same subscription CR** — keys stay valid; limits and `modelRefs` change by tier.
5. **Metering is async** — inference must not block on Lago (accept small overshoot lag).
6. **No key rotation** for tier changes — subscription name on existing `sk-oai-…` keys is unchanged.
7. **Compact MaaS is optional for MVP** — admin enrollment + native MaaS key mint works; Compact MaaS adds self-serve catalog/subscribe UX for paying users.

---

## Scope

| In scope (MVP → V1) | Out of scope (initially) |
|---------------------|---------------------------|
| Lago self-hosted on OpenShift | Lago Embedded multi-tenant |
| Budget entity enrollment (admin API + UI) | LiteMaaS dual metering |
| `usage-reporter` (Prometheus → Lago events) | Synchronous Lago check on every inference |
| `budget-enforcer` (thresholds → patch CR) | Per-user sub-budgets inside one company |
| Tier templates: full / throttled / free-only / exhausted | Key rotation between tier subscriptions |
| Solo (`owner.users`) and company (`owner.groups`) | |
| Compact MaaS entitlement gate (subscribe / key mint) | |

---

## Target architecture

```text
┌──────────────────────────────────────────────────────────────────────┐
│  Admin / operator                                                     │
│  Enrollment UI ──► maas-billing-api ──► Lago customer + MaaS CRs     │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  End user                                                             │
│  (1) Pay / top-up wallet in Lago UI                                   │
│  (2) Mint sk-oai-* on budget-<entity> (Compact MaaS or native MaaS)   │
│  (3) Inference on MaaS gateway                                        │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│  MaaS gateway (Authorino + Limitador) — unchanged data plane          │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ Phase 7 metrics (user, subscription, model)
                                ▼
                       ┌─────────────────┐
                       │ usage-reporter  │──► Lago usage events
                       └─────────────────┘
                                ▲
              Lago webhooks / wallet balance poll
                                │
                       ┌─────────────────┐
                       │ budget-enforcer │──► patch MaaSSubscription
                       └─────────────────┘     (same name, tier template)
```

| Component | Responsibility |
|-----------|----------------|
| **Lago** | Customer, plan/wallet, billable metrics, invoices, `wallet.depleted` webhooks |
| **maas-billing-api** | Enrollment API, entity registry, template catalog, Lago + K8s orchestration |
| **Enrollment UI** | Create solo/company entities, link to Lago customer, view tier state |
| **Compact MaaS** (optional) | Catalog, subscribe gate, API key UX for external users |
| **usage-reporter** | Prometheus deltas → Lago events (`external_customer_id` = entity id) |
| **budget-enforcer** | State machine: `ok` → `throttled` → `free_only` → `exhausted` → period reset |
| **MaaS** | One `MaaSSubscription` + `MaaSAuthPolicy` per entity |

---

## Budget entity model

Same model as [Phase 12](./12-openmeter-billing.md#budget-entity-model).

| Field | Solo developer | Company |
|-------|----------------|---------|
| `entity_id` | `be:alice` | `be:acme` |
| Lago `external_id` | `be:alice` | `be:acme` |
| `MaaSSubscription` name | `budget-alice` | `budget-acme` |
| `spec.owner` | `users: [{name: alice}]` | `groups: [{name: acme-developers}]` |
| Budget | Lago wallet or plan credit | Shared company wallet |
| Keys | Alice mints on `budget-alice` | Each member mints on `budget-acme` |

**Registry** (Postgres in `maas-billing-api`):

```text
budget_entities
  entity_id          PK
  display_name
  member_type        user | group
  member_ref         openshift username or group name
  maas_subscription  budget-<slug>
  lago_external_id   same as entity_id
  lago_customer_id   UUID from Lago API
  catalog_profile    standard | enterprise
  enforcement_state  ok | throttled | free_only | exhausted
  created_at
```

Convention: `maas_subscription = budget-<slug>` (e.g. `be:alice` → `budget-alice`).

---

## Graduated enforcement (no key rotation)

Identical to OpenMeter plan — enforced on MaaS, driven by Lago wallet/plan consumption %.

| Usage % | Lago | MaaS action | User experience |
|---------|------|-------------|-----------------|
| **< 90%** | Normal | `full` template | Full model access, normal limits |
| **≥ 90%** | Alert / webhook | None (optional email + Lago UI notice) | Warning only |
| **≥ 95%** | `throttled` state | Patch → `throttled` template | More **429** (tighter `tokenRateLimits`) |
| **≥ 99%** | `free_only` state | Patch → `free_only` template | Paid/external models **403**; free models work |
| **≥ 100%** | `exhausted` / `wallet.depleted` | Patch → `exhausted` template | **403** on all models (empty `modelRefs`) |
| **Period reset / top-up** | Wallet credited | Patch → `full` template | Back to normal |

**Critical:** All tiers use the **same** `MaaSSubscription` metadata.name. Keys bound to `budget-acme` pick up new limits automatically — **no key rotation**.

### Tier templates

Share templates with Phase 12 under `manifests/11-lago/templates/` (or a common `manifests/billing-templates/`). Four profiles per catalog: `full`, `throttled`, `free_only`, `exhausted`. See [Phase 12 tier templates](./12-openmeter-billing.md#tier-templates-configmap-or-git-backed-yaml).

### 100% exhausted (confirmed)

**Patch only** — set `modelRefs: []` on the entity subscription. Do **not** revoke keys (consistent with OpenMeter plan).

---

## User experience

### Where users do what

| User action | System |
|-------------|--------|
| Buy plan / add credits / pay invoice / view spend | **Lago UI** |
| Admin: enroll solo/company entity | **Enrollment UI** → `maas-billing-api` |
| Browse models, subscribe (optional), mint API keys | **Compact MaaS** or **native MaaS / RHOAI dashboard** |
| Call `/v1/chat/completions` with `sk-oai-…` | **Native MaaS gateway** |

**Do not** ask users to “get a token in Lago.” Lago does not mint MaaS API keys.

### Canonical flow

1. **Commercial (Lago)** — admin or user tops up wallet / subscribes to plan in Lago.
2. **Enrollment** — admin creates budget entity → Lago customer + `budget-<entity>` `MaaSSubscription`.
3. **Product** — user mints key against `budget-<entity>` (Compact MaaS or curl).
4. **Inference (MaaS)** — unchanged gateway auth + Limitador + model route.
5. **Metering** — `usage-reporter` → Lago events.
6. **Enforcement** — `budget-enforcer` patches subscription at 95% / 99% / 100%.

### Compact MaaS (optional but recommended for external SaaS)

- **Gate before subscribe / key mint:** check Lago wallet balance or active plan (fail closed for new access).
- **UI:** link to Lago billing portal; show current enforcement tier from `maas-billing-api`.
- Paying external users: **Lago + Compact MaaS**; internal chargeback: **Lago + admin enrollment + native mint** is enough.

---

## Two different “tokens”

| What | System | Artifact |
|------|--------|----------|
| Commercial budget | Lago | Customer, plan, wallet, invoice |
| Inference credential | MaaS | `sk-oai-…` API key + `MaaSSubscription` |
| Operational burst limits | Limitador | `tokenRateLimits` on subscription (tier templates) |

Lago meters **commercial** usage. Limitador enforces **runtime** limits from the **current** subscription template. Do not conflate Lago wallet with Limitador windows.

---

## Integration surfaces

### A. Enrollment (`maas-billing-api` → Lago + MaaS)

On `POST /api/v1/entities`:

1. Create Lago customer (`external_id` = `entity_id`).
2. Assign plan or create prepaid wallet with monthly budget.
3. Apply `MaaSSubscription` + `MaaSAuthPolicy` from `full` template.
4. Insert `budget_entities` row.

### B. Entitlement gate (Compact MaaS → Lago) — optional layer

**When:** before **Subscribe** and before `POST /maas-api/v1/api-keys` (if using Compact MaaS).

**Checks:**

- Lago wallet balance > 0 or active subscription, and
- `enforcement_state != exhausted` (read from `maas-billing-api` or infer from Lago).

**On failure:** “Upgrade or add credits” → Lago portal.

**Policy:** sync REST, ~2s timeout, fail closed for **new** keys/subscribes. Existing keys remain valid but hit **429/403** as enforcer patches tiers — **no key rotation**.

### C. Usage ingestion (MaaS → Lago)

Prometheus (Phase 7) → **`usage-reporter`**:

1. Map `subscription` label → `entity_id` via registry (`budget-acme` → `be:acme`).
2. POST Lago events with idempotent `transaction_id`.

```json
{
  "transaction_id": "maas-<uuid>",
  "external_customer_id": "be:acme",
  "code": "llm_tokens",
  "properties": {
    "model": "publishers/llm/models/granite-4-tiny-gpu",
    "subscription": "budget-acme",
    "user": "bob",
    "input_tokens": 1200,
    "output_tokens": 340
  }
}
```

Billable metrics in Lago: `input_tokens`, `output_tokens` (or combined `llm_tokens`).

### D. Budget enforcer (Lago → MaaS)

**Inputs:**

- Lago webhook: `wallet.depleted`, `wallet.balance_updated`, or custom alert at 90/95/99%, **or**
- Poll Lago wallet balance / current usage vs plan every 60s.

**Logic:** same state machine as [Phase 12 budget-enforcer](./12-openmeter-billing.md#budget-enforcer).

```text
percent = consumed / budget * 100
≥95%  → apply_template(throttled)
≥99%  → apply_template(free_only)
≥100% → apply_template(exhausted)
reset / top-up → apply_template(full)
```

Lago `wallet.depleted` at 100% complements polling; enforcer still patches MaaS (does not rely on revoking keys).

---

## Enrollment flow

### Solo developer

1. User or admin tops up wallet in **Lago**.
2. Admin creates entity: type **Solo**, username `alice`, budget linked to Lago wallet.
3. API creates Lago customer + `budget-alice` subscription (`owner.users: [alice]`).
4. Alice mints key: `subscription: "budget-alice"`.

### Company

1. Company wallet/plan in **Lago**.
2. Admin creates entity: type **Company**, group `acme-developers`.
3. API creates `budget-acme` (`owner.groups: [acme-developers]`).
4. Each employee mints their own key on `budget-acme` (shared pool).

---

## Implementation phases

### 11a — Lago platform

- Namespace `lago` on OpenShift.
- API, workers, UI, Postgres, Redis, ClickHouse.
- Routes, secrets (API key, RSA, optional Stripe).
- **License:** Lago platform is **AGPL-3.0**.

### 11b — Lago catalog

- Billable metrics: `input_tokens`, `output_tokens` (or `llm_tokens`).
- Plans / wallet products aligned with catalog profiles.
- Webhook endpoints for enforcer (balance alerts).

### 11b2 — Tier templates

- `manifests/11-lago/templates/` — `full`, `throttled`, `free_only`, `exhausted`.
- Document free-model list per profile.

### 11c — maas-billing-api

- Entity registry + `POST /entities` (Lago customer + MaaS CRs).
- Expose `enforcement_state` for Compact MaaS gate.
- Shared design with Phase 12 where possible (same DB schema, different `billing_backend=lago`).

### 11d — Enrollment UI

- Admin: create solo/company, link Lago customer, view usage % and tier.
- OpenShift OAuth.

### 11e — usage-reporter

- `manifests/11-lago/usage-reporter/`
- Prometheus → Lago events; idempotency + replay runbook.

### 11f — budget-enforcer

- `manifests/11-lago/budget-enforcer/`
- Lago webhooks + balance poll → patch `MaaSSubscription`.
- Period reset on billing cycle / wallet top-up.

### 11g — Compact MaaS bridge (optional)

- BFF: `LAGO_API_URL`, gate on subscribe + key mint.
- UI: Lago portal link, tier badge (`ok` / `throttled` / …).

### 11h — Verification

- `scripts/verify-lago.sh`: entity created, inference, usage in Lago, 95% patch → throttled, reset → full.

---

## Repository layout (planned)

```text
manifests/11-lago/
  README.md
  lago/                      # Helm / kustomize
  templates/                 # tier YAML (may share with 12-openmeter)
  maas-billing-api/
  usage-reporter/
  budget-enforcer/
  enrollment-ui/

scripts/
  verify-lago.sh

docs/
  11-lago-billing.md         # this file
```

---

## MVP vs V1 vs V2

### MVP

- [x] Phase 11 installer (`--with-lago-billing`) + observability auto-check
- [x] Lago Helm scaffold (`scripts/install-lago-platform.sh`)
- [x] `maas-billing` namespace, tier templates ConfigMap, operator RBAC
- [x] `maas-billing-api` — entity enrollment REST API + SQLite registry
- [x] `usage-reporter` — Prometheus → Lago events (batch)
- [x] `budget-enforcer` — wallet % → patch `MaaSSubscription` tier
- [x] `scripts/build-maas-billing-image.sh`, `scripts/install-lago-catalog.sh`
- [ ] Lago self-hosted production hardening (external Postgres/Redis/S3)
- [ ] Admin enrollment UI (API + curl works today)
- [ ] End-to-end: top-up → enroll → key → infer → usage in Lago → throttle patch
- [ ] Native MaaS key mint (no Compact MaaS required)

### V1

- [ ] Compact MaaS entitlement gate + Lago portal links.
- [ ] Email/Slack at 90%.
- [ ] `verify-lago.sh` in CI.
- [ ] Stripe sandbox.

### V2

- [ ] Embedded billing widgets in Compact MaaS.
- [ ] Per-user usage breakdown in Lago (`user` property dimension).
- [ ] Finance exports; `cost_center` chargeback from Phase 7.

---

## Lago vs OpenMeter (same enforcement, different commercial layer)

| | **Phase 11 Lago** | **Phase 12 OpenMeter** |
|--|-------------------|------------------------|
| Commercial UX | Lago UI, invoices, Stripe | Custom / admin enrollment |
| License | AGPL-3.0 | Apache-2.0 |
| Usage ingest | Lago REST events | CloudEvents |
| Budget signal | Wallet balance, plan usage | Metered entitlement / grant |
| **MaaS enforcement** | **Same:** patch one sub, no key rotation | **Same** |
| **Tier templates** | **Shared** | **Shared** |

Pick **one** billing backend per deployment; reuse `budget-enforcer` and templates with a thin backend adapter.

---

## Risks and open decisions

| Topic | Decision |
|-------|----------|
| AGPL | Lago + Compact MaaS AGPL stack acceptable? |
| Free tier bypass | Block global `*-free` keys for enrolled users? |
| Exhausted at 100% | Empty `modelRefs` (confirmed, no revoke) |
| Async lag | Act at 93%/97% or shorter reporter interval |
| Hot path | No Lago on inference; enforcer patches CR async |
| Backend choice | Lago vs OpenMeter per use case (invoices vs Apache metering) |

---

## Switch from OpenMeter to Lago

Use this when Phase 12 (OpenMeter) was installed and you want Lago’s commercial layer (UI, wallets, invoices) instead.

```bash
# 1. Remove OpenMeter + maas-billing (Phase 12)
./scripts/uninstall-openmeter-billing.sh

# 2. Install Lago billing (Phase 11)
./scripts/setup-maas.sh --from-phase 11 --with-lago-billing

# 3. Verify
./scripts/verify-lago.sh
```

After install:

1. Open **Lago UI** (`oc get route lago-front -n lago`) and create an API key.
2. Store it: `oc create secret generic maas-billing-secrets -n maas-billing --from-literal=LAGO_API_KEY=<key>`
3. Bootstrap catalog: `./scripts/install-lago-catalog.sh`
4. Re-enroll budget entities via `maas-billing-api` (OpenMeter customer IDs do not carry over).

**Tier templates:** Update `manifests/11-lago/base/templates-configmap.yaml` so `modelRefs` point at a **Ready** `MaaSModelRef` on your cluster (default in this guide: `llm/gemma-4-e4b-it`).

Existing `MaaSSubscription/budget-*` CRs from OpenMeter enrollment can be patched or recreated by re-running entity enrollment.

---

## Install (Phase 11)

Lago billing is a **standalone optional phase** (like Compact MaaS / LiteMaaS). It can run with or without Compact MaaS.

**Observability:** `usage-reporter` reads Prometheus gateway metrics labeled with `subscription`, `user`, and `model` (Phase 7 `TelemetryPolicy/maas-telemetry`). If that policy is missing, Phase 11 **automatically runs Phase 7** before installing Lago.

```bash
# Standalone (typical after MaaS + models are up)
./scripts/setup-maas.sh --from-phase 11 --with-lago-billing

# Shorthand
./scripts/install-lago-billing.sh

# With Compact MaaS (product console + Lago commercial layer)
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas --with-lago-billing

# External Lago (skip in-cluster Helm); still applies maas-billing base
./scripts/setup-maas.sh --from-phase 11 --with-lago-billing --skip-lago-platform

# Verify
./scripts/verify-lago.sh
```

Manifest README: `manifests/11-lago/README.md`.

### Enroll a budget entity (API)

After Phase 11 and a valid `LAGO_API_KEY` in `maas-billing-secrets`:

```bash
BILLING_API=$(oc -n maas-billing get route maas-billing-api -o jsonpath='https://{.spec.host}')

curl -sk -X POST "${BILLING_API}/api/v1/entities" \
  -H 'Content-Type: application/json' \
  -d '{
    "display_name": "Alice",
    "member_type": "user",
    "member_ref": "admin",
    "monthly_budget_credits": 10000
  }'
```

This creates a Lago customer, assigns plan `maas-standard` (or prepaid wallet fallback), and applies `MaaSSubscription/budget-admin` from the `standard.full` tier template. Mint keys with `subscription: "budget-admin"`.

---

## Suggested install order (full stack)

```bash
./scripts/setup-maas.sh --skip-models --with-observability
# Optional: --with-compact-maas for external SaaS UX

./scripts/setup-maas.sh --from-phase 11 --with-lago-billing
```

Manual equivalent:

```bash
./scripts/setup-maas.sh --from-phase 7 --with-observability --skip-models --skip-verify
./scripts/install-lago-platform.sh
oc apply -k manifests/11-lago/base/
```

Future components (enrollment UI):

```bash
oc apply -k manifests/11-lago/enrollment-ui/
```

---

## References

- [Capacity planning: 1M subscribers](./13-capacity-planning.md) — multi-cell OpenShift scale (hyperscaler-agnostic)
- [Lago](https://github.com/getlago/lago) — AGPL-3.0 metering and billing
- [Phase 12: OpenMeter (aligned enforcement)](./12-openmeter-billing.md)
- [Phase 7: Observability](./07-observability.md) — gateway telemetry
- [Phase 8: Architecture](./08-architecture.md) — subscription binding on keys
- [Phase 9–10: Optional GUIs](./09-optional-guis.md) — Compact MaaS
