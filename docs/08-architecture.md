# Architecture & Request Flow

This page explains how Red Hat OpenShift AI Models as a Service works under the hood — what each component does and how a request travels from a user's laptop to a model and back.

> **Tip:** All file paths and `oc apply` commands in this guide are relative to the [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide) repository root. Make sure you have cloned it and are working from its root directory (see [Getting Started](./index.md#getting-started)).

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

## Component Overview

Models as a Service is built from four layers, each with a distinct responsibility:

| Layer | Components | Role |
| --- | --- | --- |
| **Gateway** | Gateway API, Istio | Entry point for all traffic. HTTPRoutes direct requests to the right model endpoint. |
| **Policy** | Kuadrant, Authorino, Limitador | Enforce authentication, authorization, and rate limiting at the edge — before requests reach any model. |
| **API & Token** | maas-api, PostgreSQL | API key lifecycle: mint, validate, and revoke `sk-oai-*` keys. Stores hashed keys and subscription bindings. |
| **Model Serving** | KServe (`LLMInferenceService`), vLLM, ExternalModel | Run inference. Internal models run as vLLM pods on-cluster; external models proxy to third-party APIs (Anthropic, OpenAI, etc.). |

## Request Flow: Step by Step

Here is what happens when a user makes an inference request, from their laptop to the model and back.

<img src="https://mermaid.ink/svg/Z3JhcGggVEIKICAgIHN1YmdyYXBoIFVzZXJMYXllclsiVXNlciJdCiAgICAgICAgVVtVc2VyXQogICAgZW5kCgogICAgc3ViZ3JhcGggR2F0ZXdheUxheWVyWyJHYXRld2F5ICYgUG9saWN5Il0KICAgICAgICBHW0dhdGV3YXldCiAgICAgICAgTUFQW01hYVNBdXRoUG9saWN5PGJyLz5BdXRob3Jpbm9dCiAgICAgICAgTVNbTWFhU1N1YnNjcmlwdGlvbjxici8+TGltaXRhZG9yXQogICAgZW5kCgogICAgc3ViZ3JhcGggTWFhU0xheWVyWyJUb2tlbiBNYW5hZ2VtZW50Il0KICAgICAgICBBUElbTWFhUyBBUEldCiAgICBlbmQKCiAgICBzdWJncmFwaCBNb2RlbExheWVyWyJNb2RlbCBTZXJ2aW5nIl0KICAgICAgICBJTlZbSW5mZXJlbmNlIFNlcnZpY2VdCiAgICAgICAgTExNW0xMTV0KICAgIGVuZAoKICAgIFUgLS0-fCIxLiBJbmZlcmVuY2UgKyBBUEkga2V5InwgRwogICAgRyAtLT58IjIuIFZhbGlkYXRlIGlkZW50aXR5InwgTUFQCiAgICBNQVAgLS4tPnwiMy4gVmFsaWRhdGUga2V5InwgQVBJCiAgICBNQVAgLS0-fCI0LiBDaGVjayBsaW1pdHMifCBNUwogICAgTVMgLS0-fCI1LiBXaXRoaW4gbGltaXRzInwgSU5WCiAgICBJTlYgLS0-fCI2LiBGb3J3YXJkInwgTExNCiAgICBMTE0gLS0-fCI3LiBDb21wbGV0aW9uInwgVQoKICAgIE1BUCAtLi0-fCI0MDEvNDAzInwgVQogICAgTVMgLS4tPnwiNDI5InwgVQo=" alt="Inference request flow" style="display:block;margin:0 auto;max-width:100%;" />

_Diagram source: [Upstream MaaS Architecture^](https://opendatahub-io.github.io/models-as-a-service/latest/concepts/architecture/)_

### 1. Create an API Key

The user authenticates with their OpenShift token (or an external IdP token) and requests an API key:

```bash
curl -sk -X POST "https://maas.${CLUSTER_DOMAIN}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer <identity-token>" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-key", "subscription": "my-subscription-free", "expiresIn": "24h"}' \
  | jq -r '.key'
```

Authorino validates the identity token. If valid, maas-api generates a random `sk-oai-*` key, hashes it with SHA-256, stores the hash and subscription binding in PostgreSQL, and returns the plaintext key in the `key` field **once**.

### 2. List models and send an inference request

Resolve the model `id` from the MaaS catalog, then call chat completions at the gateway root:

```bash
API_KEY="sk-oai-..."   # from step 1

MODEL_ID=$(curl -sk "https://maas.${CLUSTER_DOMAIN}/v1/models" \
  -H "Authorization: Bearer ${API_KEY}" | jq -r '.data[0].id')

curl -sk "https://maas.${CLUSTER_DOMAIN}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"${MODEL_ID}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}"
```

### 3. Gateway Receives the Request

The request hits the `maas-default-gateway` in the `openshift-ingress` namespace. The Gateway API controller (backed by Istio) matches the request against HTTPRoutes to determine which backend to forward to.

### 4. Authorino Validates the API Key

Before the request reaches any model, Authorino intercepts it (via `MaaSAuthPolicy`) and calls the maas-api internal validate endpoint (`/internal/v1/api-keys/validate`):

- Looks up the salted hash in PostgreSQL
- Returns the user identity (username, groups, key ID) and the subscription name bound to that key
- Rejects unknown, revoked, expired, or malformed keys with `401 Unauthorized`
### 5. Subscription Access Check

Using the subscription name from the key record (not from client headers), Authorino checks:

- Is the user/group allowed to use this subscription?
- Is the requested model included in the subscription?
If either check fails, the request is rejected with `403 Forbidden`.

### 6. Rate Limiting

Limitador checks the request against the rate limits defined in the `MaaSSubscription` CR:

- Requests per minute/hour
- Token budgets per time window
If the user has exceeded their limits, the request is rejected with `429 Too Many Requests`.

### 7. Forward to Model

If all checks pass, the request is forwarded to the model backend:

- **Internal model** (`LLMInferenceService`): routed to a vLLM pod running on-cluster via KServe / InferencePool
- **External model** (ExternalModel): proxied to a third-party API (e.g., Anthropic Claude, OpenAI GPT)
The model processes the request and returns a completion response.

### 8. Response Returns to User

The response flows back through the Gateway to the user. Limitador updates usage counters (tokens consumed, requests made) for the subscription.

### Sequence Diagram

The full inference flow as a sequence diagram, showing every component interaction:

<img src="https://mermaid.ink/svg/c2VxdWVuY2VEaWFncmFtCiAgICBwYXJ0aWNpcGFudCBDbGllbnQKICAgIHBhcnRpY2lwYW50IEdhdGV3YXlBUEkKICAgIHBhcnRpY2lwYW50IEF1dGhvcmlubwogICAgcGFydGljaXBhbnQgTWFhUyBhcyBNYWFTIEFQSQogICAgcGFydGljaXBhbnQgTGltaXRhZG9yCiAgICBwYXJ0aWNpcGFudCBMTE1JbmZlcmVuY2VTZXJ2aWNlCgogICAgQ2xpZW50LT4-R2F0ZXdheUFQSTogSW5mZXJlbmNlICsgQVBJIEtleQogICAgR2F0ZXdheUFQSS0-PkF1dGhvcmlubzogVmFsaWRhdGUgY3JlZGVudGlhbHMKCiAgICBhbHQgQVBJIGtleSAoc2stb2FpLSopCiAgICAgICAgQXV0aG9yaW5vLT4-TWFhUzogUE9TVCAvaW50ZXJuYWwvdjEvYXBpLWtleXMvdmFsaWRhdGUKICAgICAgICBNYWFTLT4-TWFhUzogTG9va3VwIGhhc2ggaW4gUG9zdGdyZVNRTAogICAgICAgIE1hYVMtLT4-QXV0aG9yaW5vOiB7IHZhbGlkLCB1c2VySWQsIGdyb3Vwcywgc3Vic2NyaXB0aW9uIH0KICAgIGVuZAoKICAgIEF1dGhvcmluby0-Pk1hYVM6IFBPU1QgL2ludGVybmFsL3YxL3N1YnNjcmlwdGlvbnMvc2VsZWN0IChzdWJzY3JpcHRpb24gY2hlY2spCiAgICBNYWFTLS0-PkF1dGhvcmlubzogU2VsZWN0ZWQgc3Vic2NyaXB0aW9uCgogICAgQXV0aG9yaW5vLT4-R2F0ZXdheUFQSTogQXV0aCBzdWNjZXNzIChjYWNoZWQpCiAgICBHYXRld2F5QVBJLT4-TGltaXRhZG9yOiBDaGVjayBUb2tlblJhdGVMaW1pdFBvbGljeQogICAgTGltaXRhZG9yLS0-PkdhdGV3YXlBUEk6IFdpdGhpbiBsaW1pdHMKICAgIEdhdGV3YXlBUEktPj5MTE1JbmZlcmVuY2VTZXJ2aWNlOiBGb3J3YXJkIHJlcXVlc3QKICAgIExMTUluZmVyZW5jZVNlcnZpY2UtLT4-Q2xpZW50OiBSZXNwb25zZQo=" alt="Inference sequence diagram" style="display:block;margin:0 auto;max-width:100%;" />

## Interactive Flow Visualizer

To see all of the above in action, explore the interactive animated visualizer — it walks through 4 complete flows (including auth failures and rate limiting) step by step with clickable components and a request/response inspector.

> **Note:**
> [**Open the AI Inference Gateway Flow Visualizer**^](https://noyitz.github.io/ai-gateway-docs/ai-gateway-flow.html) (opens in a new tab)
>
> _4 Flows | 5 Providers | 35 Steps | 30+ Components_ + Built by [Noy Itzikowitz^](https://github.com/noyitz)

## References

- [Upstream MaaS Architecture](https://opendatahub-io.github.io/models-as-a-service/latest/concepts/architecture/)
- [AI Gateway Flow Visualizer](https://noyitz.github.io/ai-gateway-docs/ai-gateway-flow.html)
- [RHOAI 3.4 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index)
