# OpenAI-compatible + upstream path prefix (IBM RHAI / Inference as a Service)

IBM RHAI chat URLs look like:

```
https://us-east.rhai.ibm.com/v1/projects/<uuid>/inference/v1/chat/completions
```

`ExternalModel.spec.endpoint` is FQDN-only. Put the project base path in annotation
`compact-maas/upstream-path-prefix` and heal HTTPRoute `URLRewrite` plus `x-ibm-rhai-prefix` on all rules (BBR often matches the header-match rule, not PathPrefix).

Replace placeholders before apply. Prefer **Compact MaaS → Admin → Model refs → ExternalModel** (Test connection + automatic URLRewrite), or `scripts/import-external-models.sh --path-prefix /v1/projects/<uuid>/inference ...` to bulk-register every model the project exposes without templating each file by hand. These YAMLs are for GitOps / `oc` operators.

## Required: EnvoyFilter (BBR drops the prefix)

BBR/payload-processing rewrites upstream `:path` to `/v1/chat/completions`, so gateway calls can return an **empty 404** even when URLRewrite and the IBM key are correct. Apply:

```bash
oc apply -f ibm-rhai-upstream-path-prefix-envoyfilter.yaml
```

Lua runs after `ext_proc.bbr` on Gateway `maas-default-gateway` (`openshift-ingress`). Edit the hardcoded project UUID and model list in that file when your IBM project changes. See Antora **Phase 8** → *IBM RHAI: durable upstream path prefix*.

Test with a MaaS `*-free` subscription key (not the IBM key), prefer `--http1.1`. IBM may return HTTP **202** with completed choices — that is success.

| Placeholder | Example |
|-------------|---------|
| `REPLACE-PROJECT-UUID` | IBM project UUID |
| `REPLACE-TARGET-MODEL-ID` | Provider model id |
| `REPLACE-FQDN` | `us-east.rhai.ibm.com` |

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
# Heal HTTPRoute URLRewrite to /v1/projects/<uuid>/inference (Compact MaaS does this)
oc apply -f ibm-rhai-upstream-path-prefix-envoyfilter.yaml
```

See Antora page **Phase 8: External Models** (`08-external-models.adoc`).

## Removing a model

Deleting these resources is not a plain `oc delete -f` of the same files (order matters, and the credential Secret is often shared across models on the same endpoint). See the **Removing an external model** section on the `08-external-models.adoc` Antora page for the ordered teardown and copy-paste `oc delete` examples.
