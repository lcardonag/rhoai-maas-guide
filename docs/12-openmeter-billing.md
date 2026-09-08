# Phase 12: OpenMeter + budget entities + graduated throttling

> **Status:** **MVP in progress** — Phase 12 installer, OpenMeter Helm, `maas-billing-api`, `usage-reporter`, and `budget-enforcer` (shared image with Phase 11, `BILLING_BACKEND=openmeter`). Enrollment UI planned.  
> **Goal:** Enroll solo developers or companies in **OpenMeter**, track usage against a monthly grant, and enforce **graduated throttling** on native RHOAI MaaS by **patching one `MaaSSubscription` per entity** — **no API key rotation**.

> **Alternative to Lago:** [Phase 11 Lago billing](./11-lago-billing.md) is the recommended path for commercial metering (UI, wallets, Stripe). OpenMeter is Apache-2.0 with API-only OSS — same MaaS enforcement model.

> **Pick one backend per cluster:** Phase 11 (Lago) and Phase 12 (OpenMeter) both use `maas-billing` namespace — do not install both. To migrate to Lago: `./scripts/uninstall-openmeter-billing.sh` then `./scripts/setup-maas.sh --from-phase 11 --with-lago-billing`.

---

## Principles

1. **Do not replace** Authorino, `maas-api`, or Limitador — they remain the runtime control plane.
2. **OpenMeter owns the budget** — meters, grants, usage reports, threshold notifications.
3. **One budget entity = one OpenMeter customer = one MaaS subscription name** — solo dev or company.
4. **Enforcement = patch the same subscription CR** — keys stay valid; limits and `modelRefs` change by tier.
5. **Metering is async** — inference must not block on OpenMeter (accept small overshoot lag).
6. **No key rotation** for tier changes — subscription name on existing `sk-oai-…` keys is unchanged.

---

## Scope

| In scope (MVP → V1) | Out of scope (initially) |
|---------------------|---------------------------|
| OpenMeter OSS on OpenShift | Full invoice lifecycle / Stripe |
| Budget entity enrollment UI (admin) | Compact MaaS product integration |
| `usage-reporter` (Prometheus → CloudEvents) | LiteMaaS dual metering |
| `budget-enforcer` (thresholds → patch CR) | Synchronous OpenMeter check on every request |
| Tier templates: full / throttled / free-only / exhausted | Per-user sub-budgets inside one company |
| Solo (`owner.users`) and company (`owner.groups`) | Self-serve payment |

---

## Target architecture

```text
┌──────────────────────────────────────────────────────────────────────┐
│  Admin / operator                                                     │
│  Enrollment UI ──► maas-billing-api ──► OpenMeter + MaaS CRs         │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  End user (solo or company member)                                    │
│  Mint sk-oai-* (native MaaS / RHOAI dashboard) ──► inference         │
└───────────────────────────────┬──────────────────────────────────────┘
                                │
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│  MaaS gateway (Authorino + Limitador) — unchanged data plane          │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ Phase 7 metrics (user, subscription, model)
                                ▼
                       ┌─────────────────┐
                       │ usage-reporter  │──► OpenMeter CloudEvents
                       └─────────────────┘
                                ▲
                       webhooks / poll
                                │
                       ┌─────────────────┐
                       │ budget-enforcer │──► patch MaaSSubscription
                       └─────────────────┘     (same name, tier template)
```

| Component | Responsibility |
|-----------|----------------|
| **OpenMeter** | Customer, meter, metered entitlement / grant, usage queries, threshold webhooks |
| **maas-billing-api** | Enrollment API, entity registry, template catalog, orchestration |
| **Enrollment UI** | Create solo/company entities, set grant, view usage tier |
| **usage-reporter** | Prometheus deltas → CloudEvents (`subject` = entity id) |
| **budget-enforcer** | State machine: `ok` → `throttled` → `free_only` → `exhausted` → monthly reset |
| **MaaS** | One `MaaSSubscription` + `MaaSAuthPolicy` per entity; users mint keys against it |

---

## Budget entity model

A **budget entity** is the unit of billing and enforcement — either one person or one company.

| Field | Solo developer | Company |
|-------|----------------|---------|
| `entity_id` | `be:alice` | `be:acme` |
| OpenMeter `customer.key` | `be:alice` | `be:acme` |
| `MaaSSubscription` name | `budget-alice` | `budget-acme` |
| `spec.owner` | `users: [{name: alice}]` | `groups: [{name: acme-developers}]` |
| Grant | e.g. 1M tokens/month | e.g. 50M tokens/month |
| Keys | Alice mints on `budget-alice` | Each member mints on `budget-acme` |

**Registry** (Postgres in `maas-billing-api`):

```text
budget_entities
  entity_id          PK
  display_name
  member_type        user | group
  member_ref         openshift username or group name
  maas_subscription  budget-<slug>
  openmeter_key      same as entity_id
  monthly_grant      bigint (tokens)
  enforcement_state  ok | throttled | free_only | exhausted
  created_at
```

Convention: `maas_subscription = budget-<slug>` where slug is derived from `entity_id` (e.g. `be:alice` → `budget-alice`).

---

## Graduated enforcement (no key rotation)

| Usage % | OpenMeter | MaaS action | User experience |
|---------|-----------|-------------|-----------------|
| **< 90%** | Normal | `full` template on subscription | Full model access, normal limits |
| **≥ 90%** | Notification | None (optional email/Slack) | Warning only |
| **≥ 95%** | `throttled` state | Patch → `throttled` template | More **429** (tighter `tokenRateLimits`) |
| **≥ 99%** | `free_only` state | Patch → `free_only` template | Paid/external models **403**; free models work |
| **≥ 100%** | `exhausted` state | Patch → `exhausted` OR revoke keys | **403/429/401** on all usage |
| **Period reset** | Grant reset | Patch → `full` template | Back to normal |

**Critical:** All tiers use the **same** `MaaSSubscription` metadata.name. Authorino reads the **current** CR; keys bound to `budget-acme` automatically pick up new limits and model lists.

### Tier templates (ConfigMap or Git-backed YAML)

Store four templates per **catalog profile** (not per entity). Entity enrollment references a profile (e.g. `standard`, `enterprise`).

```yaml
# templates/standard/full.yaml — excerpt
modelRefs:
  - name: granite-4-tiny-gpu
    namespace: llm
    tokenRateLimits:
      - limit: 100000
        window: 1m
  - name: simulator
    namespace: llm
    tokenRateLimits:
      - limit: 10000
        window: 1m
# + entitled external models from profile

# templates/standard/throttled.yaml
modelRefs: <same models as full>
# tokenRateLimits: e.g. 500/min on each

# templates/standard/free_only.yaml
modelRefs:
  - name: simulator
    namespace: llm
    tokenRateLimits:
      - limit: 100
        window: 1m
  # only models tagged "free" in catalog profile

# templates/standard/exhausted.yaml
modelRefs: []
# or tokenRateLimits: [{limit: 0, window: 1m}] on all refs
```

`budget-enforcer` applies: `spec.modelRefs` + preserves `spec.owner` and `metadata.name`.

---

## Enrollment flow

### Admin creates a solo developer

1. Admin opens **Enrollment UI** → “New budget entity” → type **Solo**.
2. Enter: display name, OpenShift username (`alice`), monthly grant (tokens), catalog profile.
3. **maas-billing-api**:
   - `POST` OpenMeter customer `be:alice`
   - Create metered entitlement / grant for `llm_tokens` with monthly period
   - Apply `MaaSSubscription` `budget-alice` (`owner.users: [alice]`, `full` template)
   - Apply matching `MaaSAuthPolicy` (model access for refs in template)
   - Insert row in `budget_entities`
4. Alice mints API key via native MaaS:

```bash
curl -sk -X POST "https://maas.${CLUSTER_DOMAIN}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"alice-work","subscription":"budget-alice","expiresIn":"8760h"}'
```

### Admin creates a company

Same flow with type **Company**: OpenShift group name (`acme-developers`), subscription `budget-acme`, `owner.groups`.

### Self-service (V1, optional)

Authenticated user requests entity if username not already enrolled; admin approves grant size. Same API, `status: pending` → `active`.

---

## Enrollment UI (MVP)

Lightweight web app or OpenShift console plugin — **admin-facing** for MVP.

| Screen | Actions |
|--------|---------|
| **Entities list** | Filter by state (`ok`, `throttled`, …), usage %, grant remaining |
| **Create entity** | Solo vs company, member ref, grant, profile |
| **Entity detail** | Usage chart (OpenMeter API), current tier, subscription name, member list |
| **Adjust grant** | Top-up or change monthly grant in OpenMeter + audit log |
| **Manual tier override** | Force `full` / `throttled` / `free_only` (break-glass) |

**Auth:** OpenShift OAuth (cluster admin or dedicated `maas-billing-admin` group).

**Stack suggestion:** React + `maas-billing-api` (Go or Node) — keep UI thin; all writes go through API.

---

## maas-billing-api

Single orchestration service; owns entity registry and coordinates OpenMeter + Kubernetes.

### Endpoints (MVP)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/v1/entities` | Create entity (solo/company) |
| `GET` | `/api/v1/entities` | List entities |
| `GET` | `/api/v1/entities/{id}` | Detail + OpenMeter usage snapshot |
| `PATCH` | `/api/v1/entities/{id}/grant` | Update monthly grant |
| `POST` | `/api/v1/entities/{id}/reset` | Force `full` template (ops) |
| `GET` | `/api/v1/catalog-profiles` | List tier template profiles |
| `GET` | `/health` | Liveness |

### Create entity sequence

```text
1. Validate member_ref exists (lookup OpenShift User/Group — optional MVP: trust admin input)
2. OpenMeter: customers.create({ key: entity_id, name: display_name })
3. OpenMeter: `POST /api/v2/customers/{key}/entitlements` (`type: metered`, `featureKey: llm_tokens`, `usagePeriod: { interval: MONTH }`, `issueAfterReset: monthly_grant`)
4. Grant is issued automatically via `issueAfterReset` (do not also POST grants — OpenMeter rejects the combination)
5. K8s: apply MaaSSubscription from full template + owner
6. K8s: apply MaaSAuthPolicy for models in template
7. DB: insert budget_entities row, state=ok
```

Env vars: `OPENMETER_URL`, `OPENMETER_API_KEY`, `MAAS_SUBSCRIPTION_NAMESPACE=models-as-a-service`, `TEMPLATE_DIR`.

---

### OpenMeter meter (catalog bootstrap)

Use meter slug **`maas_llm_tokens`** with `valueProperty: $.input_tokens` (JSONPath is relative to the CloudEvents `data` object — **not** `$.data.input_tokens`). The legacy `llm_tokens` meter slug is wrong on clusters bootstrapped before this fix; re-run:

```bash
./scripts/install-openmeter-catalog.sh
```

### usage-reporter

Batch Deployment polling Prometheus (Phase 7 gateway metrics) with the projected **ServiceAccount token** against **HTTPS** Thanos.

**PromQL (OpenShift):** `authorized_hits{subscription=~"budget-.*"}` — Kuadrant limitador metric with `subscription`, `user`, and `model` labels. Requires enrolled `budget-*` subscriptions and traffic on those keys (not `*-free`).

**ConfigMap keys:** `PROMETHEUS_URL`, `REPORTER_PROMQL`, `REPORTER_INTERVAL_SECONDS`

Map `subscription` → `entity_id` via registry (`budget-alice` → `be:alice`).

### Output

CloudEvents to OpenMeter ingest API:

```json
{
  "specversion": "1.0",
  "type": "maas.tokens.consumed",
  "source": "rhoai-maas-guide/usage-reporter",
  "subject": "be:acme",
  "id": "<idempotent-uuid>",
  "time": "2026-09-02T19:00:00Z",
  "data": {
    "subscription": "budget-acme",
    "user": "bob",
    "model": "publishers/llm/models/granite-4-tiny-gpu",
    "input_tokens": 1200,
    "output_tokens": 340
  }
}
```

### OpenMeter meter definition

- **Slug:** `llm_tokens`
- **Aggregation:** `SUM` of `input_tokens + output_tokens` (or separate meters)
- **Group by:** optional `model` dimension for reports

**Interval:** 1–2 minutes MVP (balance lag vs load).

**Idempotency:** `id` = hash(`subscription`, `scrape_window`, `user`, `model`, token deltas).

---

## budget-enforcer

State machine driven by OpenMeter balance / usage percentage.

### Inputs

- OpenMeter webhook: `entitlement.threshold` (configure at 90, 95, 99, 100), **or**
- Poll every 60s: `GET /customers/{key}/entitlements/llm_tokens/value`

### Logic

```text
percent = used / grant * 100

if percent >= 100 and state != exhausted:
  apply_template(entity, exhausted); state = exhausted
elif percent >= 99 and state not in (free_only, exhausted):
  apply_template(entity, free_only); state = free_only
elif percent >= 95 and state == ok:
  apply_template(entity, throttled); state = throttled
elif percent >= 90 and not notified_this_period:
  send_notification(entity); mark notified

on entitlement period reset (OpenMeter event or cron):
  apply_template(entity, full); state = ok; clear notified flag
```

### apply_template implementation

```bash
# Pseudocode — budget-enforcer uses client-go or oc apply
PATCH MaaSSubscription/budget-acme
  spec.modelRefs = templates[profile][tier].modelRefs
  spec.owner     = unchanged
```

Use **server-side apply** or strategic merge patch; never rename the subscription.

### 100% exhausted options

| Mode | Behavior | Recommendation |
|------|----------|----------------|
| **A — empty modelRefs** | All models 403 | Simple, reversible on reset |
| **B — zero limits** | 429 on all | Keeps model list visible in errors |
| **C — revoke keys** | 401 | Hard stop; users must mint new keys after reset — **avoid** per no-rotation policy |

**MVP:** Mode A (`modelRefs: []`) or zero limits on remaining refs.

---

## OpenMeter platform (12a)

Deploy OpenMeter OSS on OpenShift.

| Piece | Notes |
|-------|-------|
| Namespace | `openmeter` |
| Dependencies | Kafka, ClickHouse, Postgres (Helm or operator) |
| Route | `openmeter.apps.<cluster>` — internal only for MVP |
| API key | Secret `openmeter-api-key` consumed by billing services |
| Version | Pin release; OSS billing APIs are beta — use metering + entitlements only for MVP |

**Bootstrap (once):**

1. Create feature `llm_tokens`
2. Create meter `llm_tokens` bound to CloudEvent type `maas.tokens.consumed`
3. Configure notification rules at 90%, 95%, 99%, 100%

See [OpenMeter OSS quickstart](https://openmeter.io/docs/api/open-source).

### OpenShift post-Helm fixes

The OCI chart (`oci://ghcr.io/openmeterio/helm-charts/openmeter`, pin e.g. `1.0.0-beta.232`) merges values in ways that **reset on every `helm upgrade`**:

1. **Postgres** — embedded Bitnami Postgres has no TLS; workers crash with `SSL is not enabled on the server` unless `ConfigMap/openmeter` contains `?sslmode=disable` on the postgres URL.
2. **API port** — the chart hardcodes `--address 0.0.0.0:80`; OpenShift non-root pods cannot bind port 80. Patch `openmeter-api` to **8080** and point the Service `targetPort` at 8080.

**Always use the guide installer** (fixes run automatically after Helm):

```bash
./scripts/install-openmeter-platform.sh
```

If you upgraded with raw `helm` and the API is in CrashLoopBackOff:

```bash
./scripts/fix-openmeter-openshift.sh
```

Implementation: `scripts/lib/openmeter-openshift.sh` (shared by install + fix scripts).

---

## MaaS governance per entity (12b)

For each enrolled entity, provision:

| Resource | Naming | Notes |
|----------|--------|-------|
| `MaaSSubscription` | `budget-<slug>` | Owner = user or group; tier from template |
| `MaaSAuthPolicy` | `budget-<slug>-access` | Model refs aligned with subscription |

**AuthPolicy:** generate from same catalog profile as subscription (reuse guide patterns from Phase 5).

**Priority:** use `priority: 20` for budget subs; keep global `*-free` at `priority: 10` if still offered.

**Bypass policy:** document whether users may still mint `*-free` keys (bypasses company budget). For strict mode, restrict free subs to admins only.

---

## Implementation phases

### 12a — OpenMeter platform

- [x] Helm installer (`scripts/install-openmeter-platform.sh`) + post-Helm OpenShift fixes (`scripts/lib/openmeter-openshift.sh`, `scripts/fix-openmeter-openshift.sh`)
- [x] Routes, values template (`manifests/12-openmeter/openmeter/values-openshift.yaml`)
- [x] Catalog bootstrap (`scripts/install-openmeter-catalog.sh`)

### 12b — Entity registry + templates

- [x] `manifests/12-openmeter/base/` — tier templates ConfigMap + RBAC
- [ ] Document “free model” list per profile

### 12c — maas-billing-api

- [x] Deployment + Route (admin internal)
- [x] `POST /entities` — OpenMeter customer + entitlement + K8s CRs + DB row
- [ ] Unit tests for slug / naming conventions

### 12d — Enrollment UI

- [ ] List + create entity screens
- [ ] Entity detail with usage % from OpenMeter
- [ ] OpenShift OAuth login

### 12e — usage-reporter

- [x] Prometheus query + CloudEvents ingest
- [ ] Confirm Phase 7 token counters (request-count proxy today)
- [ ] Idempotency hardening + replay runbook

### 12f — budget-enforcer

- [x] Poller via `/api/v1/enforcer/tick`
- [ ] OpenMeter webhook receiver (optional)
- [ ] Period reset handler

### 12g — Verification

- [x] `scripts/verify-openmeter.sh` (scaffold)
- [x] `scripts/verify-openmeter-e2e.sh` (key → infer → meter delta)
- [x] Full E2E: entity → key → infer → usage (automated script)
- [ ] Full E2E: throttle patch at 95%/99%/100%

### 12h — Documentation + setup script

- [x] `./scripts/setup-maas.sh --with-openmeter-billing`
- [x] `scripts/install-openmeter-billing.sh`

---

## Suggested install order

```bash
# Prerequisites: Phases 1–6 complete; Phase 7 strongly recommended
./scripts/setup-maas.sh --skip-models --with-observability

# Phase 12 (OpenMeter)
./scripts/setup-maas.sh --from-phase 12 --with-openmeter-billing

# Verify
./scripts/verify-openmeter.sh
./scripts/verify-openmeter-e2e.sh
```

Manifest README: `manifests/12-openmeter/README.md`.

### Enroll a budget entity (API)

```bash
BILLING_API=$(oc -n maas-billing get route maas-billing-api -o jsonpath='https://{.spec.host}')

curl -sk -X POST "${BILLING_API}/api/v1/entities" \
  -H 'Content-Type: application/json' \
  -d '{
    "display_name": "Alice",
    "member_type": "user",
    "member_ref": "admin",
    "monthly_budget_credits": 1000000
  }'
```

Mint keys with `subscription: "budget-admin"`.

---

## E2E test plan (entity → key → infer → OpenMeter)

Validates the full usage pipeline: gateway telemetry → Prometheus `authorized_hits` → `usage-reporter` → OpenMeter meter `maas_llm_tokens`.

### Prerequisites

| Check | Command |
|-------|---------|
| Phase 12 installed | `./scripts/verify-openmeter.sh` |
| Demo entity enrolled | `./scripts/install-openmeter-demo-entity.sh` |
| Tier templates reference a **Ready** model | `oc get maasmodelref -A \| grep Ready` — templates use `llm/gemma-4-e4b-it` by default |
| `budget-admin` subscription Ready | `oc get maassubscription budget-admin -n models-as-a-service` |
| Gateway telemetry (Phase 7) | `TelemetryPolicy/maas-telemetry` in `models-as-a-service` |

If enrollment used stale templates (`my-first-model/redhataigemma-…`), re-apply templates and patch the subscription:

```bash
oc apply -f manifests/12-openmeter/base/templates-configmap.yaml
oc patch maassubscription budget-admin -n models-as-a-service --type=merge -p \
  '{"spec":{"modelRefs":[{"name":"gemma-4-e4b-it","namespace":"llm","tokenRateLimits":[{"limit":100000,"window":"1m"}]}]}}'
oc patch maasauthpolicy budget-admin-access -n models-as-a-service --type=merge -p \
  '{"spec":{"modelRefs":[{"name":"gemma-4-e4b-it","namespace":"llm"}]}}'
```

### Automated run

```bash
./scripts/verify-openmeter-e2e.sh
```

Optional overrides:

```bash
SUBSCRIPTION=budget-admin OPENMETER_SUBJECT=be:admin \
MODEL_NAMESPACE=llm MODEL_NAME=gemma-4-e4b-it \
./scripts/verify-openmeter-e2e.sh
```

The script:

1. Records baseline OpenMeter meter total for `be:admin`
2. Mints an API key on `budget-admin` via native MaaS
3. Sends chat completions through `https://maas.<domain>/llm/gemma-4-e4b-it/v1/chat/completions`
4. Waits ~150s (reporter interval 120s)
5. Asserts meter total increased

### Manual steps

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MAAS_GW="https://maas.${CLUSTER_DOMAIN}"
OM="https://openmeter.${CLUSTER_DOMAIN}"

# 1. Baseline
curl -sk "${OM}/api/v1/meters/maas_llm_tokens/query?subject=be:admin&from=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)" | jq .

# 2. Mint key
KEY_JSON=$(curl -sk -X POST "${MAAS_GW}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"openmeter-manual","subscription":"budget-admin","expiresIn":"24h"}')
API_KEY=$(echo "$KEY_JSON" | jq -r '.key // .token')

# 3. Inference
curl -sk -X POST "${MAAS_GW}/llm/gemma-4-e4b-it/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-e4b-it","messages":[{"role":"user","content":"Hi"}],"max_tokens":16}' | jq .

# 4. After ~2 min — reporter + OpenMeter
curl -sk "${OM}/api/v1/meters/maas_llm_tokens/query?subject=be:admin&from=$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)" | jq .
oc logs deploy/usage-reporter -n maas-billing --tail=20
```

### Expected results

| Stage | Success signal |
|-------|----------------|
| Key mint | HTTP 201, `"key"` in JSON |
| Inference | HTTP 200, `"choices"` in body |
| Prometheus | `authorized_hits{subscription="budget-admin"}` > 0 |
| usage-reporter | Log line `reported N tokens for budget-admin` |
| OpenMeter | `maas_llm_tokens` query value increases |

---

## Repository layout (implemented)

```text
manifests/12-openmeter/
  README.md
  openmeter/values-openshift.yaml
  base/                      # namespace, tier templates, RBAC
  maas-billing-api/
  usage-reporter/
  budget-enforcer/

manifests/11-lago/maas-billing/   # shared Python image (both backends)

scripts/
  install-openmeter-platform.sh
  install-openmeter-catalog.sh
  install-openmeter-billing.sh
  verify-openmeter.sh
  verify-openmeter-e2e.sh
  build-maas-billing-image.sh
```

---

## MVP vs V1 vs V2

### MVP (demo / internal chargeback)

- [x] OpenMeter single-tenant on cluster (Helm scaffold)
- [ ] Admin-only enrollment UI (API + curl works)
- [x] Solo + company entities (API)
- [x] One catalog profile (`standard`)
- [x] usage-reporter batch 2 min
- [x] Enforcer: 95% / 99% / 100% patch (90% = log only)
- [ ] Manual grant top-up API

### V1 (pilot)

- [ ] Email/Slack at 90%
- [ ] Entity detail usage charts
- [ ] Multiple catalog profiles
- [ ] `verify-openmeter.sh` in CI
- [ ] Strict mode: no free-tier bypass for enrolled users

### V2

- [ ] Self-service entity request + approval
- [ ] Per-user usage breakdown inside company (OpenMeter event `user` dimension)
- [ ] Compact MaaS integration (optional subscribe gate)
- [ ] OpenMeter billing + Stripe (when OSS stable)

---

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Async lag overshoots budget | Shorter reporter interval; act at 93%/97%; optional sync check at high tiers |
| Phase 7 missing token metrics | Spike before 12e; fallback to request-count meter |
| Patch race (two enforcer replicas) | Leader election or state row with CAS in DB |
| User bypasses via `*-free` key | Policy + narrow free sub ownership |
| OpenMeter infra weight | Start with minimal Helm profile; document resource reqs |
| API beta churn | Pin version; entitlements customer API v2 only |

---

## Relationship to other guide phases

| Phase | Role |
|-------|------|
| 1–4 | MaaS platform — prerequisite |
| 5 / 8 | Model catalog — defines `modelRefs` in templates |
| 6 | Base verification |
| 7 | **Prerequisite** for usage-reporter |
| 9 LiteMaaS | Out of scope |
| 10 Compact MaaS | Optional later; enrollment UI is standalone for MVP |
| 11 Lago | **Same enforcement model** — Lago for invoices/Stripe; pick one backend per deployment |

---

## Open decisions (confirm before 12c)

1. **Exhausted mode:** empty `modelRefs` vs zero limits? (recommend empty)
2. **Free tier bypass:** allow global `*-free` for enrolled users?
3. **Entity ID format:** `be:<slug>` vs `ocp:user:<uid>` for solo?
4. **100% action:** patch only (no revoke) — confirmed
5. **Notification channel:** email, Slack webhook, or OpenShift event?

---

## References

- [Capacity planning: 1M subscribers](./13-capacity-planning.md) — multi-cell OpenShift scale (hyperscaler-agnostic)
- [OpenMeter](https://github.com/openmeterio/openmeter) — Apache-2.0 metering and entitlements
- [Phase 7: Observability](./07-observability.md) — gateway telemetry labels
- [Phase 8: Architecture](./08-architecture.md) — request flow, subscription binding on keys
- [Phase 11: Lago (aligned enforcement)](./11-lago-billing.md) — same budget entities + tier patching; Lago owns commercial UI
- [Phase 5: Models](./05-maas-models.md) — `MaaSSubscription` / `MaaSAuthPolicy` patterns
