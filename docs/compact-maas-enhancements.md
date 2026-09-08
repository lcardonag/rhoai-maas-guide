# Compact MaaS — enhancement plan

> **Status:** **Track 1 in progress** (guide: verify + fix scripts, product docs). **Track 2+** (BFF `gateway-root`, console BBR fix) in `rhoai-maas-console`.  
> **Product vision:** LiteMaaS-shaped **external MaaS portal** — enroll, subscribe, mint/list/revoke keys without OpenShift AI — plus admin ExternalModel. Native MaaS stays the data plane.  
> **Target repo (BFF/UI):** [`rhoai-maas-console`](https://github.com/rh-aiservices-bu/rhoai-maas-console) (Compact MaaS BFF + UI).  
> **Constraint:** [ADR 0001 — thin BFF, no LiteLLM](https://github.com/rh-aiservices-bu/rhoai-maas-console/blob/main/docs/adr/0001-thin-bff-no-litellm.md) remains in force unless superseded by a new ADR.

## Track 1 — delivered in `rhoai-maas-guide` (native-safe product core)

| Item | Artifact |
|------|----------|
| Product role (vs Gen AI Studio / governance) | [09-optional-guis.md](./09-optional-guis.md#product-role-compact-maas-vs-rhoai-35-dashboard) |
| Native key mint regression | `./scripts/verify-guis.sh --compact-maas` |
| BBR anchor with maas-api bypass | `./scripts/fix-compact-maas-native-maas.sh --apply-fix` (re-applies console manifest; Phase 10 auto-runs if verify fails) |
| OAuth / gateway / enrollment sync | `./scripts/fix-compact-maas-config.sh --apply-fix` (Phase 10 auto-runs; console `deploy.sh` retries Helm on verify fail) |
| Model id table (sub name vs catalog `id`) | [09-optional-guis.md](./09-optional-guis.md#native-maas-regression-after-compact-maas) |

**P0 upstream (console):** `compact-maas-bbr-anchor` must disable `ext_proc.bbr` on `/maas-api/*` routes — fixed in `deploy/envoyfilter/compact-maas-bbr-anchor.yaml`; applied by `deploy.sh` via `fix-payload-processing-envoyfilter.sh`.

This plan also captures two related gaps for **Track 2+** in the console:

1. **Native-style single gateway endpoint** — `POST https://maas.<domain>/v1/chat/completions` with `model` in the JSON body (OpenAI SDK default).
2. **One API key → multiple models** — already supported by MaaS when a single `MaaSSubscription` lists multiple `modelRefs`; Compact MaaS needs clearer admin + user UX and root-URL examples.

See also: [GAP-LITEMAAS.md](https://github.com/rh-aiservices-bu/rhoai-maas-console/blob/main/docs/phase-0/GAP-LITEMAAS.md) (honest gaps vs LiteMaaS).

---

## Current behavior (baseline)

| Area | Native MaaS | Compact MaaS today |
|------|-------------|-------------------|
| Inference URL | Gateway root: `/v1/chat/completions` | Per-model catalog URL: `/llm/<model>/v1/chat/completions` |
| Model selection | `model` field in request body | Chat + curl examples use `model.url` from catalog |
| API keys | One `subscription` per key | Same — UI enforces one subscription per mint |
| Multi-model key | Yes if subscription has multiple `modelRefs` | Partial — multi-select on Keys when models share a sub; examples still per-model URL |
| BFF chat proxy | N/A | `POST /api/v1/chat/completions` → upstream uses `modelUrl` or falls back to `/llm/<model>` |

**Reference (BFF):** `backend/src/maas/client.ts` — `chatCompletions()` builds URL from `modelUrl` or `` `${gateway}/llm/${model}` ``.

**Reference (UI):** `frontend/src/components/ApiKeyUsageExamples.tsx` — documents per-model gateway base only.

---

## Goals

### G1 — Native gateway root URL mode (primary)

End users and SDKs can use **one base URL** for all models on a subscription:

```text
POST https://maas.<domain>/v1/chat/completions
Authorization: Bearer sk-oai-…
{ "model": "<id from GET /v1/models>", "messages": [...] }
```

Compact MaaS should **document, generate, and optionally use** this pattern without LiteLLM.

### G2 — Multi-model keys (clarity + admin ergonomics)

Make it obvious how to get **one key** that works for **several models**:

- Admin: one `MaaSSubscription` with multiple `modelRefs` + aligned `MaaSAuthPolicy` per model.
- User: Keys page multi-select → single subscription → one minted key.
- Examples: show that the **same key** works for each `model` id at the **same root URL** (G1).

### G3 — No regression

- Per-model `/llm/<name>/v1/...` URLs remain valid (catalog `url`, ExternalModel rewrites, chat when user picks a model).
- No second enforcement plane; no LiteLLM in path.

---

## Non-goals

- Virtual keys, dollar budgets, key-level TPM/RPM (LiteLLM / proxy — see GAP-LITEMAAS).
- One key spanning **multiple** `MaaSSubscription` CRs without admin merging `modelRefs`.
- Replacing Limitador token windows with a spend ledger.

---

## Proposed enhancements

### E1 — Gateway URL mode (user + developer preference)

**Description:** Configurable inference URL style for examples, Chat, and docs inside the console.

| Mode | Base URL | `model` in body |
|------|----------|-----------------|
| `per-model` (default, today) | `{catalog.url}` → `/llm/<name>` | Required; must match route |
| `gateway-root` (new) | `{MAAS_GATEWAY_URL}` | Required; id from `GET /v1/models` |

**Implementation sketch:**

| Layer | Change |
|-------|--------|
| **Config** | `INFERENCE_URL_MODE=per-model\|gateway-root` (Helm value + `GET /api/v1/config` exposure). Default `per-model` for backward compatibility. |
| **BFF `chatCompletions`** | When `gateway-root`: ignore `modelUrl`; POST to `${MAAS_GATEWAY_URL}/v1/chat/completions`. When `per-model`: current behavior. |
| **ApiKeyUsageExamples** | Generate curl/Python for root URL + `model` id when mode is `gateway-root`. |
| **ChatPage** | Optional: omit `modelUrl` in BFF body when `gateway-root`; show endpoint hint in UI. |
| **Model detail / Catalog** | Secondary tab or callout: “OpenAI SDK base URL” = `MAAS_GATEWAY_URL` when mode enabled. |

**Acceptance criteria:**

- [ ] With `gateway-root`, curl example uses `https://maas.<domain>/v1/chat/completions` only.
- [ ] Same `sk-oai-…` key can call model A and model B by changing `model` in JSON (subscription covers both).
- [ ] Chat playground works in `gateway-root` mode for subscribed models.
- [ ] `per-model` mode unchanged for existing deployments.

---

### E2 — Multi-model subscription admin assistant

**Description:** Reduce “keys work for one model only” support burden when admins created one subscription per model.

**Implementation sketch:**

| Layer | Change |
|-------|--------|
| **Admin → Subscriptions** | “Add model to subscription” — append `modelRef` to existing CR (with validation: same namespace patterns as today). |
| **Admin health banner** | Warn when catalog shows N models but keys require N separate subscriptions where a bundle is intended. |
| **Docs in console** | Link from Keys blocked-state message to admin doc section (already partially in `subscriptions-and-enrollment.md`). |

**Acceptance criteria:**

- [ ] Admin can attach a second `modelRef` to an existing subscription without raw YAML.
- [ ] Keys page allows multi-select models on that subscription → **one** key.
- [ ] AuthPolicy alignment checklist (or one-click “sync subjects from subscription”) documented or automated.

---

### E3 — “Native MaaS quick start” panel on API keys success

**Description:** After minting a key, show **both** URL styles when useful:

1. **Gateway root** (recommended for OpenAI SDK): `base_url = MAAS_GATEWAY_URL`, `api_key = sk-oai-…`.
2. **Per-model** (legacy / debugging): `{model.url}/v1/chat/completions`.

Include `GET /v1/models` one-liner to resolve `model` ids.

**Acceptance criteria:**

- [ ] Success modal includes root-URL snippet even when default mode is `per-model`.
- [ ] Copy clearly labels which pattern matches OpenAI Python/Node clients.

---

### E4 — Catalog `id` vs URL clarity

**Description:** `GET /maas-api/v1/models` returns `id` (often `publishers/.../models/...`) and `url` (often `/llm/...`). Examples must use **`id` in JSON** and **gateway host in URL** for root mode.

**Implementation sketch:**

- Usage examples use `selected.id` for `model` field (already mostly true).
- Tooltip: “Model id for API body; gateway path is separate in root URL mode.”

---

## Implementation phases

### Phase A — Documentation only (low risk)

- Update `rhoai-maas-console` admin doc: multi-model subscription recipe + native curl at gateway root.
- Update `rhoai-maas-guide` Phase 10 README + [09-optional-guis.md](./09-optional-guis.md) with link to this plan.
- Keys page: static callout linking to native MaaS pattern (no BFF change).

**Effort:** S  
**Depends on:** nothing

### Phase B — BFF + examples (`gateway-root` mode)

- E1 backend + config flag.
- E3 success modal snippets.
- Unit tests in `backend/src/maas/client.ts` for URL selection.

**Effort:** M  
**Depends on:** Phase A copy reviewed

### Phase C — Chat + admin UX

- E1 ChatPage respects mode.
- E2 admin “add model to subscription” (if not already sufficient via JSON form).

**Effort:** M–L  
**Depends on:** Phase B

### Phase D — Optional polish

- User preference persisted in browser localStorage (override cluster default).
- OpenAI SDK code sample (Node + Python) on Keys page.

**Effort:** S

---

## Test plan (when implemented)

1. **Admin:** Create `sandbox-multi` subscription with `modelRefs: [granite, tinyllama]`; AuthPolicies for both; token limits optional.
2. **User:** Subscribe → mint one key with both models selected.
3. **Root URL:**  
   `curl POST $MAAS_URL/v1/chat/completions` with `model=<granite-id>` → 200.  
   Same key, `model=<tinyllama-id>` → 200.
4. **Per-model URL:** Existing `/llm/<name>/v1/chat/completions` still 200.
5. **Negative:** Key on sub A only → root URL with model B id → 403.
6. **Compact MaaS UI:** Examples and Chat pass in both modes.

---

## Configuration reference (proposed)

```yaml
# deploy/helm/compact-maas/values.yaml (illustrative)
console:
  inferenceUrlMode: per-model   # or gateway-root
  maasGatewayUrl: https://maas.apps.example.com
```

```bash
# End-user native MaaS (works today, outside console examples)
export MAAS_URL="https://maas.${CLUSTER_DOMAIN}"
export API_KEY="sk-oai-…"
export MODEL_ID="$(curl -sk "${MAAS_URL}/v1/models" \
  -H "Authorization: Bearer ${API_KEY}" | jq -r '.data[0].id')"
curl -sk "${MAAS_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"
```

---

## Relationship to LiteMaaS / Lago

| Approach | When |
|----------|------|
| **This plan (E1–E4)** | Stay on native MaaS; OpenAI SDK `base_url` = gateway; no proxy |
| **LiteMaaS + LiteLLM** | Need proxy virtual keys, $ budgets, or single LiteLLM URL with different semantics |
| **Lago** ([11-lago-billing.md](./11-lago-billing.md)) | Commercial billing; orthogonal to URL shape |

---

## Tracking

| ID | Title | Phase | Priority |
|----|-------|-------|----------|
| E1 | Gateway root URL mode | B | P0 |
| E2 | Multi-model subscription admin UX | C | P1 |
| E3 | Dual quick-start on key mint | B | P1 |
| E4 | Model id vs URL clarity | B | P2 |

**Upstream backlog:** merge into `rhoai-maas-console/docs/phase-0/BACKLOG.md` when implementation starts.

---

## References

- [Phase 9–10: Optional GUIs](./09-optional-guis.md)
- [Phase 6: Verification](./06-verification.md) — native inference curl
- [08-architecture](./08-architecture.md) — request flow
- Compact MaaS: [ADR 0001](https://github.com/rh-aiservices-bu/rhoai-maas-console/blob/main/docs/adr/0001-thin-bff-no-litellm.md), [GAP-LITEMAAS](https://github.com/rh-aiservices-bu/rhoai-maas-console/blob/main/docs/phase-0/GAP-LITEMAAS.md), [subscriptions-and-enrollment](https://github.com/rh-aiservices-bu/rhoai-maas-console/blob/main/docs/admin/subscriptions-and-enrollment.md)
