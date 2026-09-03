# Phase 6: MaaS Verification

End-to-end verification: API keys, inference, auth enforcement, rate limits.

Full documentation: https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/06-verification.html

## Run

```bash
./manifests/06-verification/verify.sh
# or:
./scripts/verify-maas.sh
```

## Notes

- Deploys a **temporary** simulator if needed; use `--no-cleanup` to keep resources.
- **Skips** deploying a simulator if any `LLMInferenceService` already exists (tests against existing models).
- Warns if RHOAI gateway pods (`data-science-gateway`, `openshift-ai-inference`) are still at 1Gi or not ready.
- Inference test uses `MODEL_ID` from `GET /v1/models` and `POST /v1/chat/completions` at the gateway root.

## Manual inference test

```bash
HOST="https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
API_KEY=$(curl -sk -X POST "${HOST}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"test","subscription":"<your-subscription>","expiresIn":"1h"}' \
  | jq -r '.key')
MODEL_ID=$(curl -sk "${HOST}/v1/models" -H "Authorization: Bearer ${API_KEY}" | jq -r '.data[0].id')
curl -sk "${HOST}/v1/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":20}"
```
