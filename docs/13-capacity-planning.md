# Capacity planning: 1M subscribers on OpenShift (hyperscaler-agnostic)

> **Status:** Design reference — not implemented.  
> **Audience:** Platform architects sizing RHOAI MaaS + optional LiteLLM + billing for large-scale API products on **OpenShift** (Oracle OKE/ACM, IBM Cloud ROKS, Azure ARO, AWS ROSA, on-prem).

**Related:** [Phase 12 OpenMeter](./12-openmeter-billing.md) · [Phase 11 Lago](./11-lago-billing.md) · [Phase 8 External models](./08-external-models.md) · [Phase 9–10 GUIs](./09-optional-guis.md)

---

## Executive summary

| Question | Answer |
|----------|--------|
| Can 1M subscribers run on OpenShift without on-cluster GPU inference? | **Yes** — use **Connectivity Link / ExternalModel** for inference; scale the **control and edge planes**. |
| Is the current guide PoC (single namespace, 1 replica) sufficient? | **No** — plan **2–3 orders of magnitude** more capacity and **multi-cell** topology. |
| Peak load (this doc’s baseline) | **100k concurrent** requests (10:1 oversubscription on 1M subs) → **~3k–20k sustained RPS** at peak hour depending on latency. |
| Dominant limits | **Upstream provider quotas**, then **gateway auth + Redis (Limitador)**, then **optional LiteLLM spend DB**, then **metering ingest**. |
| Recommended product split at scale | **Native MaaS gateway** per cell + **OpenMeter/Lago** metering/enforcement; **LiteLLM** only if OpenRouter UX is required — **sharded**, not monolithic. |

---

## Baseline traffic model

### Subscriber assumptions

| Parameter | Value | Notes |
|-----------|-------|-------|
| Registered subscribers | **1,000,000** | API product accounts (solo + company members) |
| Oversubscription (concurrency ratio) | **10:1** | 10 subscribers per 1 concurrent slot |
| **Peak concurrent in-flight** | **100,000** | Design target for gateway connection pools |
| Business-hours window | **12 h active / 24 h** | Peak within business day |
| Peak-hour concentration | **20%** of daily requests | Tunable per product analytics |
| Daily active users (DAU) | **20%** of subs → **200k** | Conservative API product assumption |
| Requests per DAU per day | **30** | Mid-range dev API usage |
| **Daily request volume** | **~6M requests/day** | For metering / log storage sizing |

### Peak RPS from concurrency

```text
RPS_sustained ≈ concurrent_in_flight / avg_request_duration_seconds
```

| Avg request duration (chat / streaming) | Sustained RPS @ 100k concurrent |
|---------------------------------------|--------------------------------|
| 5 s (fast models, short prompts) | **~20,000** |
| 15 s (typical) | **~6,700** |
| 30 s (long context / slow provider) | **~3,300** |

**Planning envelope (single geography, peak hour):**

- **Sustained:** 5k–15k RPS (use **10k RPS** as default planning figure)
- **Burst (2–3×):** 20k–45k RPS for 1–5 minutes
- **Connections:** 100k+ long-lived HTTP/2 streams if clients hold connections open

### Business-hours shaping

```text
Off-peak (12 h night)     ≈ 10–15% of peak RPS
Shoulder (2 h)            ≈ 40–60% of peak RPS
Peak business hour (2 h)  ≈ 100% (design point)
```

Size **autoscaling max** for peak hour; size **metering/storage** for **daily integral** (6M–50M events/day depending on DAU and calls).

---

## Inference is not the cluster bottleneck

With **Connectivity Link** and **ExternalModel** ([Phase 8](./08-external-models.md)), inference runs **outside** the OpenShift data plane:

```text
Client → MaaS gateway (policy) → external provider API
```

Cluster GPU / vLLM capacity is **out of scope** for this sizing doc. Plan instead:

| External dependency | Planning action |
|---------------------|-----------------|
| Provider TPM/RPM | Multi-account pools, model routing, queue + 429 to clients |
| Egress bandwidth | **10k RPS × payload size** — dedicated egress nodes / NAT gateways per hyperscaler |
| Provider latency | Drives **concurrent** count at fixed RPS — not OpenShift CPU |

**Rule:** Run a **provider capacity spreadsheet** in parallel with OpenShift sizing; providers often cap before the cluster does.

---

## Target architecture: multi-cell on OpenShift

A single OpenShift cluster (or single LiteMaaS Helm release) is **not** the unit of scale. Use **cells**:

```text
                         Global DNS / Anycast / Geo LB
                    (subscriber_id or region → cell)
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
   Cell 1 (e.g. us-east)      Cell 2 (eu-west)           Cell 3 (ap-south)
   OpenShift cluster          OpenShift cluster            OpenShift cluster
        │                           │                           │
   MaaS gateway pool            MaaS gateway pool            MaaS gateway pool
   Authorino + Limitador        (same)                       (same)
   maas-api (regional)          maas-api                     maas-api
   optional LiteLLM shard       optional LiteLLM shard         optional LiteLLM shard
        │                           │                           │
        └───────────────────────────┴───────────────────────────┘
                                    │
                         External model provider pool
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
           Control plane (1–3 regions)      Metering plane (central)
           enrollment, billing API          Kafka + ClickHouse / Lago
           budget-enforcer (per cell)       OpenMeter / Lago
```

### Cell sizing (per cell, planning target)

Assume **3 active cells** at full scale → **~3k–5k sustained RPS per cell** (10k RPS global ÷ 3, with N+1 headroom).

| Per cell | Count / size (indicative) |
|----------|---------------------------|
| OpenShift worker nodes (gateway-heavy) | **15–40** nodes (8–16 vCPU, 32–64 GiB) — depends on Istio/gateway tuning |
| MaaS gateway / ingress proxy pods | **20–60** replicas (HPA on CPU + connection count) |
| Authorino | **6–15** replicas; **auth response cache** mandatory |
| Limitador | **3–6** replicas; **Redis Cluster** 3+ nodes (16–64 GiB each) |
| `maas-api` | **4–12** replicas; **PgBouncer** in front of Postgres |
| Postgres (`maas-api` DB) | **Managed** or **Crunchy/CloudNative-PG**: 4–8 vCPU, 32–64 GiB RAM, HA + read replicas |
| LiteLLM (if used) | **10–40** pods/cell; see [LiteLLM production sizing](https://docs.litellm.ai/docs/proxy/db_sizing) |
| LiteMaaS backend/UI | **2–6** replicas (portal only; not on inference path) |

**Cells per geography:** start with **1 cell / region**; split into **2 cells / region** when a single cluster approaches **~5k sustained RPS** or **~50k concurrent** per cell.

---

## Hyperscaler deployment (OpenShift variants)

The **logical architecture is identical**; swap managed services per cloud:

| Layer | Oracle OCI | IBM Cloud | Azure | AWS (ROSA) |
|-------|------------|-----------|-------|------------|
| OpenShift | OKE + ACM / OCI OpenShift | **ROKS** | **ARO** | **ROSA** |
| Ingress / LB | OCI LB / NGINX on OCP | Cloud Load Balancer | Azure Front Door / App Gateway | ALB / NLB |
| Postgres (`maas-api`, LiteLLM) | OCI PostgreSQL | IBM Databases for PostgreSQL | Azure Database for PostgreSQL Flexible | RDS PostgreSQL |
| Redis (Limitador, LiteLLM) | OCI Cache / self-hosted | IBM Databases for Redis | Azure Cache for Redis (Premium cluster) | ElastiCache |
| Object storage (logs, backups) | OCI Object Storage | IBM COS | Azure Blob | S3 |
| Kafka (metering) | OCI Streaming / Red Hat AMQ | Event Streams | Event Hubs / Confluent | MSK / Confluent |
| Observability | OCI Monitoring + UWM | IBM Cloud Monitoring + UWM | Azure Monitor + UWM | CloudWatch + UWM |

**OpenShift-specific:**

- Use **multiple worker pools**: `gateway` (network-optimized), `platform` (operators), `data` (if self-hosting Kafka/ClickHouse).
- Enable **User Workload Monitoring** ([Phase 7](./07-observability.md)) per cell — required for `usage-reporter` and SLOs.
- **Gateway API / Istio**: raise proxy memory (guide already uses 2Gi for MaaS gateway); at scale, tune `max_connections`, H2 stream limits, and outlier detection.
- **Certificates:** cert-manager + public CA per cell; provider egress via cluster egress IPs or NAT gateways.

---

## Component deep dive and re-engineering

What must change from the **current rhoai-maas-guide PoC** to reach this volume.

### 1. MaaS gateway + Connectivity Link (hot path)

| Today (PoC) | At 1M scale |
|-------------|-------------|
| Single gateway, default Istio resources | **HPA** on gateway pods; **multi-AZ**; connection limits tuned |
| Authorino → `maas-api` validate every request | **Cache** validated key metadata (TTL 30–120s); optional local JWT from short-lived token exchange |
| Limitador + small Redis | **Redis Cluster**; pre-aggregate limits; subscription-level sharding |
| Per-model HTTPRoutes | Same; **external models** via ExternalModel — no GPU routes |

**Re-engineering:**

- [ ] **Auth cache layer** (Envoy ext-authz cache or Authorino policy cache) — largest win on RPS.
- [ ] **Separate read path** for key validation (`maas-api` read replicas + PgBouncer).
- [ ] **Cell-aware DNS** — `maas-<cell>.<domain>` or global LB with consistent hash on API key.
- [ ] **429/503 storm protection** — queue at gateway when providers throttle; circuit breakers per provider.

### 2. `maas-api` + PostgreSQL

| Metric | Scale |
|--------|-------|
| API keys | **1M–5M** rows (multiple keys per subscriber) |
| Validate QPS | **5k–15k/cell** with caching → **500–2k** DB reads/s effective |
| Writes | Key mint/revoke — low vs inference |

**Re-engineering:**

- [ ] HA Postgres with **2+ read replicas**; PgBouncer `transaction` pooling for writers.
- [ ] Partition or archive expired keys; index on key hash prefix.
- [ ] **Do not** put billing state in `maas-api` DB — keep in OpenMeter/Lago ([Phase 11/12](./11-lago-billing.md)).

### 3. LiteLLM / LiteMaaS (optional OpenRouter layer)

| Today | At 1M scale |
|-------|-------------|
| 1 LiteLLM pod, 512Mi–1Gi | **10–40 pods/cell**, HPA, 1 worker/pod |
| Embedded Postgres 512Mi | **Managed Postgres** 8–16+ vCPU; `proxy_batch_write_at: 60` |
| Redis 128Mi | **16–32 GiB Redis cluster**; `use_redis_transaction_buffer: true` above ~1k RPS/cell |
| Dual hop to MaaS | Evaluate **removing LiteLLM** from hot path for enterprise; keep for dev product only |

**Re-engineering:**

- [ ] **Shard LiteLLM by cell** — no global single LiteLLM.
- [ ] **Spend write batching** + Redis transaction buffer ([LiteLLM prod docs](https://docs.litellm.ai/docs/proxy/prod)).
- [ ] LiteMaaS portal: **CDN** for static assets; backend **horizontal** pods; **not** co-scaled with inference.

**Alternative (recommended for B2B at 1M):** **Native MaaS only** + Compact MaaS or custom portal; budgets via **budget-enforcer** on `MaaSSubscription` — one fewer hop, no LiteLLM spend DB.

### 4. Billing and metering (Lago / OpenMeter)

| Plane | Role at scale |
|-------|----------------|
| **Enrollment** | `maas-billing-api` — low QPS; 1M rows in entity registry |
| **usage-reporter** | **Per cell**; Prometheus → events; **1–2 min** batch OK at scale if enforcer tolerates lag |
| **budget-enforcer** | **Per cell**; patches local `MaaSSubscription`; idempotent state machine |
| **OpenMeter / Lago** | **Central** or **regional**; Kafka ingest for **millions–tens of millions events/day** |

**Daily event volume (baseline):**

```text
6M requests/day × ~1 event/request = 6M events/day  (~70 events/s average)
Peak hour: ~20% × 6M / 3600 ≈ 330 events/s (average); bursts higher
```

With heavier instrumentation (input + output token lines): **3×** → **~200–1000 events/s** peak — plan **Kafka 3–6 brokers**, **ClickHouse** or Lago's ClickHouse for analytics.

**Re-engineering:**

- [ ] **Never** call Lago/OpenMeter synchronously on inference ([principles in Phase 11/12](./11-lago-billing.md)).
- [ ] **Idempotent** event IDs; dead-letter queue for failed ingest.
- [ ] **Graduated tiers** (90/95/99%) via subscription patch — control-plane rate independent of inference RPS.

### 5. External providers

At **100k concurrent** / **10k RPS**, provider limits dominate:

- [ ] **Provider pool** — N API keys / accounts per model family; router in gateway or LiteLLM.
- [ ] **Token bucket** at edge when provider returns 429.
- [ ] **Model fallbacks** (cheaper model when premium saturated) — product decision.

---

## Reference topology (3 cells, 10k RPS global)

```text
Subscribers: 1,000,000
Peak concurrent: 100,000 (global)
Sustained RPS: ~10,000 (global peak hour)
Cells: 3 (us, eu, ap) → ~3,300 RPS/cell sustained

Per cell:
  Gateway pods:        30–40
  Authorino:           8–12
  Limitador:           4
  maas-api:            6–8
  Redis (Limitador):   3-node cluster, 32 GiB each
  Postgres (maas-api): 4 vCPU / 32 GiB HA + 2 read replicas
  LiteLLM (optional):  15–25 pods OR 0 (native-only path)
  Workers:             25–35 nodes (mixed pools)

Central:
  OpenMeter or Lago + Kafka + ClickHouse
  maas-billing-api + enrollment UI (HA, 2 regions)
  budget-enforcer:     1 deployment/cell (leader-elected)
  usage-reporter:      2–4 pods/cell
```

---

## Re-engineering checklist (PoC → production)

### Phase A — Foundation (100k subs, ~1k RPS)

- [ ] External models only via Connectivity Link / Phase 8
- [ ] Managed Postgres + Redis; PgBouncer for `maas-api`
- [ ] Phase 7 observability on every cell
- [ ] Auth caching on gateway
- [ ] HPA on gateway and `maas-api`
- [ ] OpenMeter or Lago + `usage-reporter` + `budget-enforcer` MVP

### Phase B — Growth (500k subs, ~5k RPS)

- [ ] Second cell + global traffic steering
- [ ] Redis Cluster for Limitador
- [ ] Postgres read replicas; key validation SLO monitoring
- [ ] Provider pool + circuit breakers
- [ ] Kafka-backed metering ingest

### Phase C — Target (1M subs, ~10k+ RPS)

- [ ] Third cell; cell-level blast radius
- [ ] Remove LiteLLM from hot path **or** full LiteLLM shard per cell with production Postgres/Redis tiers
- [ ] Multi-region enrollment API; entity → cell mapping
- [ ] Load test: 100k concurrent synthetic (gradual ramp); validate provider + gateway
- [ ] Runbooks: provider outage, Redis failover, enforcer stuck, metering backlog

---

## SLOs and validation

| SLO | Target |
|-----|--------|
| Gateway auth p99 | **< 50 ms** (with cache) |
| End-to-end inference p99 | Dominated by **provider** (1–30s) |
| Metering lag | **< 5 min** p95 (enforcer thresholds) |
| Availability (edge) | **99.9%** per cell |
| Budget enforcement correctness | No more than **X%** overshoot (define X, e.g. 2–5% with async metering) |

**Load testing:**

1. Synthetic `sk-oai-*` keys at **subscription** mix matching production.
2. Ramp to **cell-level** concurrent target before global.
3. Measure Authorino cache hit rate, Limitador Redis latency, `maas-api` pool wait, egress bandwidth.
4. Chaos: kill one gateway AZ, Redis primary failover, provider 429 storm.

---

## Cost drivers (order of magnitude)

On any hyperscaler, at this scale expect monthly **infrastructure** (excluding provider token spend) to be driven by:

1. **External API spend** — usually **largest** line item.
2. **OpenShift worker nodes** (gateway pool) — **second**.
3. **Managed Postgres + Redis** (× cells + central metering DB).
4. **Egress** to providers.
5. **Kafka / ClickHouse** for metering analytics.
6. **LiteLLM footprint** — significant if kept on hot path; **smaller** if native MaaS + billing only.

Use **3 cells × ~30 workers × $/node** as a rough floor before provider fees.

---

## Product path recommendation at 1M subscribers

| Persona | Stack |
|---------|--------|
| **Enterprise prepay/postpay, graduated MaaS tiers** | **Native MaaS** multi-cell + **Lago or OpenMeter** + **budget-enforcer** + Compact MaaS or custom portal |
| **OpenRouter-style developer API** | **Sharded LiteLLM per cell** + Lago for invoices **or** LiteLLM $ budgets only for MVP + native MaaS upstream |
| **Avoid** | Single-cluster PoC Helm defaults; sync billing on inference; one global LiteLLM without Redis cluster |

---

## Open decisions

1. **Cells:** 3 vs 6 at launch? (region coverage vs cost)
2. **LiteLLM:** hot path yes/no at 1M?
3. **Billing backend:** Lago (invoices) vs OpenMeter (Apache metering) vs both (avoid dual meter)
4. **Auth cache TTL:** security vs DB load tradeoff
5. **Overshoot budget:** acceptable % with async enforcer
6. **DAU / requests per day:** validate with product analytics — drives metering storage more than gateway

---

## References

- [RHOAI MaaS architecture](./08-architecture.md)
- [Phase 7 Observability](./07-observability.md) — gateway telemetry for `usage-reporter`
- [Phase 8 External models](./08-external-models.md) — Connectivity Link / ExternalModel
- [Phase 11 Lago + budget entities](./11-lago-billing.md)
- [Phase 12 OpenMeter + graduated throttling](./12-openmeter-billing.md)
- [Phase 9–10 GUIs](./09-optional-guis.md) — LiteMaaS vs Compact MaaS
- [LiteLLM production best practices](https://docs.litellm.ai/docs/proxy/prod)
- [LiteLLM database sizing](https://docs.litellm.ai/docs/proxy/db_sizing)
- [LiteLLM Redis sizing](https://docs.litellm.ai/docs/proxy/redis_sizing)
- [Red Hat Connectivity Link](https://docs.redhat.com/en/documentation/red_hat_connectivity_link)
