# Phase 6: MaaS Verification

End-to-end verification of a MaaS (Models as a Service) deployment on OpenShift.

> **Tip:** All file paths and `oc apply` commands in this guide are relative to the [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide) repository root. Make sure you have cloned it and are working from its root directory (see [Getting Started](./index.md#getting-started)).

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

## What it tests

The `verify.sh` script runs 6 phases:

1. **Infrastructure health** - checks Gateway, PostgreSQL, maas-api, maas-controller, Authorino, DSC readiness, and the `/maas-api/health` endpoint.
1. **Deploy simulator model** - creates a temporary CPU-only simulator (LLMInferenceService, MaaSModelRef, MaaSAuthPolicy, MaaSSubscription) and waits for it to become Ready.
1. **API verification** - creates an API key, lists available models, and sends a chat completion inference request.
1. **Auth enforcement** - sends requests with no token and an invalid token, verifying both are rejected (HTTP 401/403).
1. **Rate limiting** - fires 16 rapid requests to trigger the 100 tokens/min rate limit and confirms HTTP 429 responses.
1. **Cleanup** - removes all temporary test resources (API key, MaaS CRs, simulator pods, namespaces if empty).
## Prerequisites

- MaaS platform installed on the cluster
- `oc` logged into the cluster (`oc whoami` succeeds)
- `curl`, `jq`, and `dig` available on PATH
## Usage

> **Warning:** The verification script deploys its own temporary simulator model and cleans up **all** test resources during the cleanup phase — including any simulator you deployed in [Phase 5](./05-maas-models.md). Use `--no-cleanup` to keep resources, or re-deploy your model after running verification.

```bash
# Full verification (deploy, test, cleanup)
./manifests/06-verification/verify.sh

# Keep test resources after verification
./manifests/06-verification/verify.sh --no-cleanup

# Remove leftover test resources from a previous run
./manifests/06-verification/verify.sh --cleanup-only
```

## Expected output

When all checks pass, the script prints:

```
=========================================
MaaS Verification Summary
=========================================
MaaS API URL:  https://maas.<cluster-domain>
Passed:        15
Failed:        0
Status:        ALL CHECKS PASSED
=========================================
```

The exit code is 0 on success and 1 if any check failed.

## Manual verification commands

If you prefer to verify each phase manually:

### Phase 1: Infrastructure health

```bash
# Gateway
oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'

# Core deployments (maas-api namespace varies by RHOAI version)
for NS in redhat-ai-gateway-infra redhat-ods-applications; do
  oc get deployment postgres maas-api maas-controller -n "$NS" 2>/dev/null && break
done

# Authorino
oc get deployment authorino -n kuadrant-system

# DSC condition
oc get datasciencecluster default-dsc \
  -o jsonpath='{.status.conditions[?(@.type=="ModelsAsServiceReady")].status}'

# Health endpoint
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
curl -sk "https://maas.${DOMAIN}/maas-api/health"
```

### Phase 2: Deploy simulator model

```bash
oc get llminferenceservice -n llm
oc get maasmodelref -n llm -o wide
oc get maasauthpolicy -n models-as-a-service
oc get maassubscription -n models-as-a-service
oc get pods -n llm
```

### Phase 3: API verification

```bash
DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
HOST="https://maas.${DOMAIN}"

# Create API key (save the key and model URL for subsequent phases)
API_KEY=$(curl -sk -X POST \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"test","expiresIn":"1h","subscription":"simulator-free"}' \
  "${HOST}/maas-api/v1/api-keys" | jq -r '.key')
echo "API_KEY=${API_KEY}"

# List models and resolve id for inference
curl -sk -H "Authorization: Bearer ${API_KEY}" "${HOST}/v1/models"

MODEL_ID=$(curl -sk -H "Authorization: Bearer ${API_KEY}" \
  "${HOST}/v1/models" | jq -r '.data[0].id')
echo "MODEL_ID=${MODEL_ID}"

# Chat completion (gateway root — not /namespace/model/...)
curl -sk -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":50}" \
  "${HOST}/v1/chat/completions"
```

### Phase 4: Auth enforcement

```bash
# Should return 401 or 403 (no API key)
curl -sk -o /dev/null -w '%{http_code}' \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}" \
  "${HOST}/v1/chat/completions"
```

### Phase 5: Rate limiting

```bash
# Send rapid requests and watch for 429
for i in $(seq 1 16); do
  curl -sk -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello, write a long essay\"}],\"max_tokens\":50}" \
    "${HOST}/v1/chat/completions"
done
```

## Troubleshooting

### Gateway pod OOMKilled (CrashLoopBackOff)

Kuadrant Wasm extensions can exceed the default `1Gi` Istio proxy memory limit. This affects **three** Gateways in `openshift-ingress`:

- `maas-default-gateway` — MaaS API / `/llm/...` routes
- `data-science-gateway` — RHOAI data-science routes (`rh-ai.apps...`)
- `openshift-ai-inference` — GUI model inference (`inference-gateway.apps...`)
The `DataScienceCluster` can show `Ready` while RHOAI gateway pods are in `CrashLoopBackOff` (last state `OOMKilled`, exit 137).

Check all gateway pods:

```bash
oc get pods -n openshift-ingress | grep -E 'maas-default|data-science-gateway|openshift-ai-inference'
```

Apply the 2Gi fixes from [Phase 2 Step 5b](./02-platform-config.md#gateway-pod-oomkill-prevention) (`maas-default-gateway`) and the **RHOAI-managed Gateways** note in the same section (`data-science-gateway` + `openshift-ai-inference`). Or re-run:

```bash
./scripts/setup-maas.sh --from-phase 4
```

### Wrong subscription name in API key creation

If the API key creation returns `{"code":"invalid_subscription","error":"Unable to resolve a subscription for this API key"}`, ensure the subscription name matches an existing `MaaSSubscription` resource:

```bash
oc get maassubscription -n models-as-a-service
```

The Kustomize-deployed simulator uses `simulator-free` and `simulator-premium`. The verification script creates its own `simulator-subscription`.

## Appendix

### Directory Structure

```
manifests/06-verification/
  verify.sh                      # End-to-end MaaS verification script
```

## References

- [MaaS upstream documentation](https://github.com/opendatahub-io/models-as-a-service)
- [MaaS verification in rhoai-nightly](https://github.com/rh-aiservices-bu/rhoai-nightly/blob/main/scripts/verify-maas.sh)
## Next step

Proceed to [Phase 7: Observability](./07-observability.md).
