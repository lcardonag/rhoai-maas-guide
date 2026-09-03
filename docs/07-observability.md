# Phase 7: Observability (Optional)

> **Note:** User Workload Monitoring (UWM) was already configured in [Phase 2](./02-platform-config.md) as a **required** component. UWM provides the foundational Prometheus scraping infrastructure that all other monitoring features depend on.

This phase adds **optional** observability enhancements on top of UWM:

1. **Tempo Operator** - provides the `TempoStack` CRD that the RHOAI operator's Monitoring controller requires for distributed tracing. Without this operator, the Monitoring CR cannot provision tracing infrastructure.
1. **Red Hat build of OpenTelemetry Operator** - provides the `OpenTelemetryCollector` CRD that the RHOAI operator's Monitoring controller requires. Without this operator, the Monitoring CR fails with: _"OpenTelemetryCollector operator must be installed for OpenTelemetry configuration"_. This blocks the full observability chain: MonitoringStack, ThanosQuerier, Perses, and PrometheusDatasource.
1. **Cluster Observability Operator (COO)** - required for the Observability Dashboard tab in the Red Hat OpenShift AI UI. COO provides the Perses CRDs (`Perses`, `PersesDatasource`, `PersesDashboard`) that the RHOAI operator uses to deploy the dashboard backend.
1. **Gateway Telemetry** - per-model, per-user, per-subscription usage metrics on the MaaS gateway. Adds fine-grained labels (`model`, `user`, `subscription`, `organization_id`, `cost_center`) to gateway metrics for usage attribution and billing.
> **Tip:** All file paths and `oc apply` commands in this guide are relative to the [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide) repository root. Make sure you have cloned it and are working from its root directory (see [Getting Started](./index.md#getting-started)).

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

## Step 1: Install the Tempo Operator

```bash
oc apply -k manifests/07-observability/tempo/
```

Wait for the operator CSV to reach `Succeeded`:

```bash
oc wait csv -n openshift-tempo-operator \
  -l operators.coreos.com/tempo-product.openshift-tempo-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

## Step 2: Install the Red Hat build of OpenTelemetry Operator

```bash
oc apply -k manifests/07-observability/opentelemetry/
```

Wait for the operator CSV to reach `Succeeded`:

```bash
oc wait csv -n openshift-opentelemetry-operator \
  -l operators.coreos.com/opentelemetry-product.openshift-opentelemetry-operator="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

## Step 3: Install the Cluster Observability Operator

> **Note:** COO is pinned to **v1.4.0** with Manual install plan approval. This avoids potential regressions in newer versions. The pin will be removed once upstream validation completes.

```bash
oc apply -k manifests/07-observability/coo/
```

Approve the install plan (required because of Manual approval):

```bash
sleep 10
oc get installplan -n openshift-cluster-observability-operator --no-headers \
  -o custom-columns='NAME:.metadata.name,APPROVED:.spec.approved' | \
  grep false | awk '{print $1}' | \
  xargs -I{} oc patch installplan {} -n openshift-cluster-observability-operator \
    --type=merge -p '{"spec":{"approved":true}}'
```

Wait for the operator CSV to reach `Succeeded`:

```bash
oc wait csv -n openshift-cluster-observability-operator \
  -l operators.coreos.com/cluster-observability-operator.openshift-cluster-observability="" \
  --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
```

## Step 4: Enable DSCI Monitoring

Now that all three observability operators are installed, configure the DSCI monitoring section to trigger the operator's observability cascade (MonitoringStack, ThanosQuerier, Perses, tracing):

```bash
oc patch dsci default-dsci --type=merge -p '{
  "spec": {
    "monitoring": {
      "namespace": "redhat-ods-monitoring",
      "metrics": {
        "replicas": 1,
        "storage": {
          "size": "5Gi",
          "retention": "90d"
        }
      },
      "traces": {
        "sampleRatio": "0.1",
        "storage": {
          "backend": "pv",
          "retention": "2160h"
        }
      }
    }
  }
}'
```

> **Important:** This step is required for the Observability Dashboard tab in the RHOAI UI to show metrics. Without it, the DSCI monitoring section remains empty (`metrics: {}`) and the dashboard has no data source.

Wait for the DSCI to reconcile:

```bash
oc wait --for=jsonpath='{.status.phase}'=Ready dsci/default-dsci --timeout=300s
```

## Step 5: Apply Gateway Telemetry

Once COO is installed and the MaaS gateway is running:

```bash
oc apply -k manifests/07-observability/telemetry/
```

## Verification

Check all three observability operators are installed:

```bash
oc get csv -n openshift-tempo-operator | grep tempo
# Expected: tempo-operator   Succeeded

oc get csv -n openshift-opentelemetry-operator | grep opentelemetry
# Expected: opentelemetry-operator   Succeeded

oc get csv -n openshift-cluster-observability-operator | grep cluster-observability-operator
# Expected: cluster-observability-operator   Succeeded
```

Check the required CRDs are registered:

```bash
# Tempo
oc get crd tempostacks.tempo.grafana.com

# OpenTelemetry
oc get crd opentelemetrycollectors.opentelemetry.io

# COO / Perses
oc get crd perses.perses.dev
```

Check the TelemetryPolicy exists:

```bash
oc get telemetrypolicies.extensions.kuadrant.io maas-telemetry -n openshift-ingress
```

Check the Istio Telemetry exists:

```bash
oc get telemetry.telemetry.istio.io latency-per-subscription -n openshift-ingress
```

## Appendix

### Directory Structure

```
manifests/07-observability/
  tempo/
    kustomization.yaml           # Tempo operator subscription
    namespace.yaml               # openshift-tempo-operator namespace
    operatorgroup.yaml           # Tempo OperatorGroup
    subscription.yaml            # Tempo Subscription
  opentelemetry/
    kustomization.yaml           # OpenTelemetry operator subscription
    namespace.yaml               # openshift-opentelemetry-operator namespace
    operatorgroup.yaml           # OpenTelemetry OperatorGroup
    subscription.yaml            # OpenTelemetry Subscription
  coo/
    kustomization.yaml           # COO operator subscription
    namespace.yaml               # COO namespace
    operatorgroup.yaml           # COO OperatorGroup
    subscription.yaml            # COO Subscription
  telemetry/
    gateway-telemetry-policy.yaml    # Kuadrant TelemetryPolicy
    istio-gateway-telemetry.yaml     # Istio Telemetry CR
    kustomization.yaml
```

## References

- [RHOAI 3.4 - Enabling the observability stack](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/managing_openshift_ai/managing-observability_managing-rhoai#enabling-the-observability-stack_managing-rhoai)
- [RHOAI 3.5 - Enabling the observability stack](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_openshift_ai/managing-observability_managing-rhoai#enabling-the-observability-stack_managing-rhoai)
- [Cluster Observability Operator documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest)
- [RHOAI Observability dashboard](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index#maas-observability_maas-deploy)
- [Kuadrant TelemetryPolicy](https://docs.kuadrant.io/dev/kuadrant-operator/doc/reference/telemetrypolicy/)
## Next step

Proceed to [Phase 8: External Models](https://github.com/rh-aiservices-bu/rhoai-maas-guide/blob/main/docs/08-external-models.md).
