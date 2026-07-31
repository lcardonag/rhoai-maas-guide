# OpenAI-compatible + upstream path prefix (IBM RHAI / Inference as a Service)

Templates for external models whose OpenAI routes live under a **project base path**, e.g.:

```text
https://us-east.rhai.ibm.com/v1/projects/<uuid>/inference/v1/chat/completions
```

Replace placeholders before apply. Prefer **Compact MaaS → Admin → Model refs → ExternalModel** (Test connection + automatic URLRewrite), or `scripts/import-external-models.sh --path-prefix /v1/projects/<uuid>/inference ...` to bulk-register every model the project exposes without templating each file by hand. These YAMLs are for GitOps / `oc` operators.

## Placeholders

| Token | Example |
|-------|---------|
| `REPLACE-PROJECT-UUID` | `002d4a39-9d40-4c25-a9fa-a603eebdb574` |
| `REPLACE-TARGET-MODEL-ID` | Provider model id |
| `REPLACE-FQDN` | `us-east.rhai.ibm.com` |
| Secret data | Create imperatively — never commit keys |

## Apply (sketch)

```bash
NS=llm   # or external-models (must match ModelRef + gateway-access label)
oc apply -f namespace.yaml   # if using external-models
# create secret …-credentials with api-key + bbr-managed + ipp-managed labels
sed -e 's/REPLACE-PROJECT-UUID/…/' -e 's/REPLACE-TARGET-MODEL-ID/…/' \
    -e 's/REPLACE-FQDN/us-east.rhai.ibm.com/' \
  external-model.yaml | oc apply -f -
oc apply -f maas-modelref.yaml
oc apply -f maas-auth-policy.yaml
oc apply -f maas-subscription.yaml
# Then heal HTTPRoute URLRewrite to /v1/projects/<uuid>/inference (Compact MaaS does this)
```

See Antora page **Phase 8: External Models** (`08-external-models.adoc`).
