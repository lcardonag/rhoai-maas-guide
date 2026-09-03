# Phase 4: RHOAI Configuration

Configure the RHOAI operator instances to enable Models-as-a-Service. Because the PostgreSQL database and `maas-db-config` secret already exist ([Phase 3](./03-maas-platform.md)), the `maas-api` deployment will start healthy immediately.

> **Tip:** All file paths and `oc apply` commands in this guide are relative to the [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide) repository root. Make sure you have cloned it and are working from its root directory (see [Getting Started](./index.md#getting-started)).

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

## Prerequisites

- RHOAI operator is installed and CSV is in `Succeeded` state
- [Phase 3](./03-maas-platform.md) (MaaS platform) is completed — PostgreSQL is running and `maas-db-config` secret exists
Verify the operator is ready before proceeding:

```bash
oc get csv -n redhat-ods-operator | grep rhods-operator
```

Expected output (version varies — 3.4.0 or 3.5.0):

```
NAME                     DISPLAY                 VERSION   REPLACES               PHASE
rhods-operator.3.5.0     Red Hat OpenShift AI    3.5.0     rhods-operator.3.4.0   Succeeded
```

## Apply

On a fresh install, apply in two stages. The `OdhDashboardConfig` CRD does not exist until the RHOAI operator has reconciled the DataScienceCluster, so applying the full kustomization in one shot will fail the first time.

> **Note:** The RHOAI operator auto-creates a `default-dsci` and `odh-dashboard-config` during installation. When you `oc apply` over these auto-created resources, you will see a warning: _"resource is missing the kubectl.kubernetes.io/last-applied-configuration annotation"_. This is harmless — the annotation is patched automatically and subsequent applies will be clean.

```bash
# Stage 1: DSC and DSCI (triggers operator reconciliation)
oc apply -f manifests/04-rhoai-config/dscinitialization.yaml
```

Wait until the DSCI is created (this step must complete before creating the DSC):

```bash
oc wait --for=jsonpath='{.status.phase}'=Ready \
  dscinitialization/default-dsci --timeout=600s
```

Create the Data Science Cluster:

```bash
oc apply -f manifests/04-rhoai-config/datasciencecluster.yaml
```

The DataScienceCluster reconciles multiple components. Wait for `KServe` and the `Model Controller` (MaaS) to reach Ready:

```bash
oc wait --for=jsonpath='{.status.phase}'=Ready \
  datasciencecluster/default-dsc --timeout=600s
```

With the Data Science Cluster created we can now apply the dashboard configuration:

```bash
# Stage 2: Dashboard config (requires OdhDashboardConfig CRD to exist)
oc apply -f manifests/04-rhoai-config/odh-dashboard-config.yaml
```

> **Note:** On subsequent runs (CRDs already exist), `oc apply -k manifests/04-rhoai-config/` works in one shot.

## Verify

### Check MaaS CRDs are installed

The operator installs MaaS CRDs when `modelsAsService` is set to Managed:

```bash
oc get crd | grep maas.opendatahub.io
```

Expected CRDs:

- externalmodels.maas.opendatahub.io
- maasauthpolicies.maas.opendatahub.io
- maasmodelrefs.maas.opendatahub.io
- maassubscriptions.maas.opendatahub.io
- tenants.maas.opendatahub.io
### Check maas-api deployment

Since PostgreSQL and the `maas-db-config` secret were created in Phase 3, the `maas-api` deployment should start healthy. On **RHOAI 3.4** it runs in `redhat-ods-applications`; on **RHOAI 3.5+** it may run in `redhat-ai-gateway-infra`. The external health URL is unchanged.

```bash
# Try 3.5+ namespace first, then 3.4
for NS in redhat-ai-gateway-infra redhat-ods-applications; do
  if oc get deployment maas-api -n "$NS" &>/dev/null; then
    echo "maas-api in $NS"
    oc rollout status deployment/maas-api -n "$NS" --timeout=120s
    break
  fi
done
```

> **Tip:** The `maas-api` deployment may take 30-60 seconds to appear after the DSC is applied. If it is not found, wait and retry.

### Check Tenant CR

The maas-controller auto-creates a `default-tenant` CR in the `models-as-a-service` namespace:

```bash
oc get tenant default-tenant -n models-as-a-service
```

> **Note:** The `default-tenant` CR may show either `Ready=True` (reason `Reconciled`) or `Ready=False` (reason `DeploymentsNotReady`) at this stage. Both are normal — if it shows `Ready=False`, it will become `Ready=True` after a model is deployed in [Phase 5](./05-maas-models.md).

### MaaS health endpoint

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
curl -sk "https://maas.${CLUSTER_DOMAIN}/maas-api/health"
# Expected: {"status":"healthy"}
```

### Check OdhDashboardConfig flags

```bash
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
  -o jsonpath='{.spec.dashboardConfig}' | jq .
```

Verify the following flags are set:

- `modelAsService: true` - enables MaaS admin features in the dashboard
- `genAiStudio: true` - enables Gen AI Studio (required for MaaS user-facing UI in RHOAI 3.5+)
- `maasAuthPolicies: true` - (optional) MaaS governance admin UI
- `observabilityDashboard: true` - (optional) Observability tab (requires COO)
Also verify `spec.components.ogx.managementState` is `Managed` on the DataScienceCluster (required for MaaS dashboard features in RHOAI 3.5).

### Deploy models after MaaS is ready

Phases 1–4 enable the MaaS platform; they do not register models. If you deploy a model from the OpenShift AI dashboard **before** `maas-api` is healthy, the **Publish as MaaS** advanced option is not shown. Complete Phase 4 (or run `./scripts/setup-maas.sh --skip-models`) first, confirm:

```bash
curl -sk "https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')/maas-api/health"
# Expected: {"status":"healthy"}
```

Then deploy with **Publish as MaaS**, or use [Phase 5](./05-maas-models.md) for bundled models only (`simulator`, `granite-tiny-gpu`, `gpt-oss-20b`).

### MaaS in the dashboard (RHOAI 3.5+)

- **Gen AI Studio → AI asset endpoints** — Models tab (MaaS-published models show a **Model as a Service** badge) and MCP Server tab
- **Gen AI Studio → API keys** — create MaaS API keys and view subscriptions (separate menu item, not inside AI asset endpoints)
### Script post-steps (Phases 2 & 4)

`setup-maas.sh` also runs after platform configuration:

- `ensure_default_gateway_tls` — creates `default-gateway-tls` from the ingress cert when missing (required for `openshift-ai-inference` HTTPS listener)
- `ensure_rhoai_gateway_proxy_memory` — applies 2Gi Istio proxy limits on all three gateways in `openshift-ingress` (see [Phase 2](./02-platform-config.md))
### Troubleshooting

#### Duplicate OperatorGroup (TooManyOperatorGroups)

If the OpenShift AI operator was installed from the **dashboard** and you also run `setup-maas.sh` Phase 1, OLM may create a second `OperatorGroup` in `redhat-ods-operator` and the `rhods-operator` CSV fails with `TooManyOperatorGroups`.

Keep a single OperatorGroup (`redhat-ods-operator-og` from the GUI install is typical). Delete any duplicate `OperatorGroup` created by the script, then reconcile the subscription:

```bash
oc get operatorgroup -n redhat-ods-operator
# Delete duplicate if present, e.g.:
# oc delete operatorgroup redhat-ods-operator -n redhat-ods-operator

oc patch subscription rhods-operator -n redhat-ods-operator --type merge \
  -p '{"spec":{"installPlanApproval":"Automatic"}}'
```

## What this creates

| Resource | Purpose |
| --- | --- |
| `DSCInitialization/default-dsci` | Configures applications namespace, monitoring, and trusted CA bundle |
| `DataScienceCluster/default-dsc` | Enables all RHOAI components including KServe with modelsAsService Managed |
| `OdhDashboardConfig/odh-dashboard-config` | Enables MaaS, GenAI Studio, Auth Policies, and Observability UI tabs |

## Troubleshooting

If components do not become ready:

```bash
# Inspect DSC conditions and events
oc describe datasciencecluster default-dsc

# Check operator logs
oc logs -n redhat-ods-operator deployment/rhods-operator --tail=100

# Check pods in the applications namespace
oc get pods -n redhat-ods-applications
```

## Appendix

### Directory Structure

```
manifests/04-rhoai-config/
  kustomization.yaml             # Aggregates all RHOAI config resources
  dscinitialization.yaml         # DSCInitialization CR
  datasciencecluster.yaml        # DataScienceCluster CR
  odh-dashboard-config.yaml      # OdhDashboardConfig CR
```

## References

- [RHOAI 3.4 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index)
- [RHOAI 3.4 Installation Guide](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/installing_and_uninstalling_openshift_ai_self-managed/index)
- [Upstream MaaS Documentation](https://opendatahub-io.github.io/models-as-a-service/latest/)
## Next step

Proceed to [Phase 5: Model Deployment](./05-maas-models.md).
