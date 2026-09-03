# Phase 2: Platform Configuration

This phase configures the platform prerequisites for MaaS: Kuadrant/Authorino (auth and rate limiting), User Workload Monitoring, the GatewayClass, and the MaaS Gateway.

Apply each step in order and wait for the status gates before proceeding to the next step. The ordering matters because later resources depend on earlier ones (e.g. the Authorino CR references the TLS cert created by the Service annotation, and the Gateway requires the GatewayClass to exist).

> **Tip:** All file paths and `oc apply` commands in this guide are relative to the [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide) repository root. Make sure you have cloned it and are working from its root directory (see [Getting Started](./index.md#getting-started)).

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

## Prerequisites

- OpenShift 4.19+ cluster with `oc` CLI authenticated as cluster-admin
- Red Hat Connectivity Link (RHCL) operator already installed (see [RHCL docs](https://docs.redhat.com/en/documentation/red_hat_connectivity_link))
- [Phase 1](./01-prerequisites.md) (operators) completed
## Step 1: Kuadrant and Authorino

Kuadrant provides authentication (Authorino) and rate limiting (Limitador) for MaaS API endpoints. These three configurations:

- Create the `kuadrant-system` namespace
- Pre-configure the Authorino Service with a service-ca annotation to auto-generate a TLS certificate (`authorino-server-cert`) for secure Gateway-to-Authorino communication
- Deploy the Kuadrant CR with observability enabled, which triggers the Kuadrant operator to install Authorino and Limitador components. The `observability.enable: true` setting ensures
these components expose metrics that User Workload Monitoring can scrape, which is essential for the optional observability dashboards in Phase 7.

The Kuadrant operator auto-creates an Authorino instance when reconciling the Kuadrant resource. You'll enable TLS on that Authorino instance in the next step.

> **Note:**
> Apply the namespace, service annotation, and Kuadrant CR. Do **not** apply the full kustomization in one shot. The Kuadrant operator auto-creates an Authorino CR when it reconciles the Kuadrant resource, so the Authorino CR must be configured separately via `oc patch` after Kuadrant is ready.

```bash
oc apply -f manifests/02-platform-config/kuadrant/namespace.yaml
oc apply -f manifests/02-platform-config/kuadrant/service-annotation.yaml
oc apply -f manifests/02-platform-config/kuadrant/kuadrant.yaml
```

Wait for Kuadrant to become ready:

```bash
oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=120s
```

> **Note:**
> **Troubleshooting:** If Kuadrant reports `MissingDependency` (Istio race condition), restart the Kuadrant operator pod and wait again:
>
> ```bash
> oc delete pod -n openshift-operators \
>   $(oc get pods -n openshift-operators --no-headers | grep kuadrant-operator | awk '{print $1}')
> oc wait --for=condition=Ready kuadrant/kuadrant -n kuadrant-system --timeout=180s
> ```

## Step 2: Configure TLS for Models-as-a-Service

Now that Kuadrant is deployed, we need to update the Authorino CR to enable TLS. (Detailed documentation for this step is available in the [RHOAI 3.4 docs section 1.4](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/deploy-and-manage-models-as-a-service_maas#configure-tls-for-maas_maas-deploy). ) Follow the four steps below to enable TLS between the Gateway and Authorino.

**Step 2a:** The service annotation (already applied above) triggered the service-ca operator to generate the `authorino-server-cert` TLS Secret:

```bash
oc get secret authorino-server-cert -n kuadrant-system
```

**Step 2b:** Patch the Authorino CR to enable the TLS listener:

```bash
oc patch authorino authorino -n kuadrant-system --type=merge --patch '{
  "spec": {
    "listener": {
      "tls": {
        "enabled": true,
        "certSecretRef": {
          "name": "authorino-server-cert"
        }
      }
    }
  }
}'
```

**Step 2c:** Configure Authorino deployment with TLS certificate env vars:

```bash
oc -n kuadrant-system set env deployment/authorino \
  SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt \
  REQUESTS_CA_BUNDLE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt
```

Wait for the Authorino deployment to become available:

```bash
oc wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s
```

## Step 3: User Workload Monitoring (UWM)

Enable User Workload Monitoring so that Prometheus scrapes MaaS and Kuadrant metrics from user namespaces.

```bash
oc apply -k manifests/02-platform-config/uwm/
```

Wait for the user-workload monitoring stack to start:

> **Tip:** The `prometheus-operator` deployment may take 10-20 seconds to appear after applying the ConfigMap. If the wait command returns "not found", retry after a few seconds.

```bash
oc wait --for=condition=Available deployment/prometheus-operator \
  -n openshift-user-workload-monitoring --timeout=300s
```

Verify the Prometheus pods are running:

```bash
oc get pods -n openshift-user-workload-monitoring
```

You should see `prometheus-user-workload-0` and `thanos-ruler-user-workload-0` pods in Running state.

Expected output:

```
NAME                                   READY   STATUS    RESTARTS   AGE
prometheus-operator-76b9c6d5dc-rrvn8   2/2     Running   0          23m
prometheus-user-workload-0             6/6     Running   0          23m
thanos-ruler-user-workload-0           4/4     Running   0          23m
```

## Step 4: GatewayClass

Apply the GatewayClass that initializes OpenShift's built-in Gateway API controller:

```bash
oc apply -f manifests/02-platform-config/gatewayclass.yaml
```

Wait for the GatewayClass to be accepted:

```bash
oc wait --for=condition=Accepted gatewayclass/openshift-default --timeout=120s
```

Verify:

```bash
oc get gatewayclass openshift-default
```

Expected output:

```
NAME                CONTROLLER                           ACCEPTED   AGE
openshift-default   openshift.io/gateway-controller/v1   True       ...
```

## Step 5: MaaS Gateway

The Gateway uses cluster-specific values (domain and TLS cert name), so it is provided as an `envsubst` template. Here we will extract the values, render the template, and apply them.

**Step 5a:** Check Your Platform Type

Before creating the Gateway, determine if your cluster requires additional configuration for non-cloud platforms:

```bash
oc get infrastructure cluster -o jsonpath='{.status.platform}'
```

| Platform output | What to do |
| --- | --- |
| `AWS`, `Azure`, `GCP` (cloud) | **Skip to Step 5b** — create the Gateway directly. |
| `None`, `BareMetal`, `OpenStack` | **Continue to Step 5a.1** — verify MetalLB is installed first. |

**Step 5a.1:** Verify MetalLB is Installed (Non-Cloud Platforms Only)

Check if MetalLB is installed:

```bash
oc get deployment metallb-operator-controller-manager -n metallb-system 2>/dev/null
```

If you see "NotFound" or "Error":

> **Warning:**
> MetalLB is not installed. Without it, the Gateway will never reach `Programmed=True` because there is no cloud load balancer to assign an external IP.
>
> You must go back and complete: [Phase 1: MetalLB for Non-Cloud Clusters](./01-prerequisites.md#optional-metallb-operator-non-cloud-clusters)
>
> After installing MetalLB and configuring an IPAddressPool, return to this step.

If MetalLB is installed: Continue to the next step.

**Step 5b:** Create the MaaS Gateway

First, apply the Gateway resource overrides ConfigMap. This sets the gateway proxy memory limit to `2Gi` (the Istio default of `1Gi` is insufficient when Kuadrant Wasm extensions are loaded):

```bash
oc apply -f manifests/02-platform-config/gateway-resources.yaml
```

Now create the Gateway. The Gateway template includes `spec.infrastructure.parametersRef` pointing to the ConfigMap above, so Istio applies the `2Gi` limit to the generated Deployment and preserves it across reconciliations.

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')
echo $CLUSTER_DOMAIN
```

```bash
export CERT_NAME=$(oc get ingresscontroller default \
  -n openshift-ingress-operator \
  -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null)
export CERT_NAME="${CERT_NAME:-router-certs-default}"
echo $CERT_NAME
```

```bash
envsubst '${CLUSTER_DOMAIN} ${CERT_NAME}' < manifests/02-platform-config/gateway.yaml.tmpl | oc apply -f -
```

**Step 5c:** Annotate the Gateway for Authorino TLS bootstrap:

```bash
oc annotate gateway maas-default-gateway -n openshift-ingress \
  security.opendatahub.io/authorino-tls-bootstrap="true" --overwrite
```

Wait for the Gateway to be programmed:

```bash
oc wait --for=condition=Programmed gateway/maas-default-gateway \
  -n openshift-ingress --timeout=120s
```

> **Note:**
> **Gateway Pod OOMKill Prevention**
>
> The ConfigMap applied in Step 5b overrides the Istio default `1Gi` memory limit to `2Gi` via `spec.infrastructure.parametersRef`. This prevents the gateway pod from being OOMKilled when Kuadrant Wasm extensions (Authorino auth, Limitador rate limiting) are compiled at startup. Unlike `oc patch deployment`, this approach survives Istio reconciliation.
>
> If you deployed the Gateway **without** the ConfigMap (e.g. from an older version of this guide), apply the fix retroactively:
>
> ```bash
> oc apply -f manifests/02-platform-config/gateway-resources.yaml
>
> oc patch gateway maas-default-gateway -n openshift-ingress --type=merge -p '{
>   "spec": {
>     "infrastructure": {
>       "parametersRef": {
>         "group": "",
>         "kind": "ConfigMap",
>         "name": "maas-gateway-options"
>       }
>     }
>   }
> }'
> ```
>
> This is tracked in [RHOAIENG-68589](https://redhat.atlassian.net/browse/RHOAIENG-68589).
>
> **RHOAI-managed Gateways (RHOAI 3.5+)**
>
> RHOAI also creates `data-science-gateway` and `openshift-ai-inference` Gateways in `openshift-ingress`. They use the same Istio proxy and the same 1Gi default, so they can OOMKill independently of `maas-default-gateway`. The DataScienceCluster CR may still show `Ready` while these gateway pods are in `CrashLoopBackOff`.
>
> `setup-maas.sh` applies `manifests/02-platform-config/rhoai-gateway-resources.yaml` and patches `data-science-gateway-config` after Phase 4. To apply manually:
>
> ```bash
> oc apply -f manifests/02-platform-config/rhoai-gateway-resources.yaml
>
> oc patch gateway openshift-ai-inference -n openshift-ingress --type=merge -p '{
>   "spec": {"infrastructure": {"parametersRef": {
>     "group": "", "kind": "ConfigMap", "name": "openshift-ai-inference-gateway-options"
>   }}}
> }'
>
> oc patch configmap data-science-gateway-config -n openshift-ingress --type=merge -p '{
>   "data": {
>     "deployment": "spec:\n  template:\n    spec:\n      containers:\n      - name: istio-proxy\n        resources:\n          requests:\n            cpu: 100m\n            memory: 256Mi\n          limits:\n            cpu: \"2\"\n            memory: 2Gi\n"
>   }
> }'
>
> oc delete pod -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=data-science-gateway
> oc delete pod -n openshift-ingress -l gateway.networking.k8s.io/gateway-name=openshift-ai-inference
> ```
>
> **External inference TLS (`default-gateway-tls`)**
>
> RHOAI's `openshift-ai-inference` Gateway expects a secret named `default-gateway-tls` in `openshift-ingress`. Clusters using cert-manager ingress often have only `cert-manager-ingress-cert` (or `router-certs-default`). Without `default-gateway-tls`, the HTTPS listener may not program and external inference routes fail.
>
> `setup-maas.sh` runs `ensure_default_gateway_tls()` after Phases 2 and 4. To create it manually (adjust `SOURCE` if your ingress cert secret differs):
>
> ```bash
> SOURCE=cert-manager-ingress-cert   # or router-certs-default
> oc get secret "$SOURCE" -n openshift-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/tls.crt
> oc get secret "$SOURCE" -n openshift-ingress -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/tls.key
> oc create secret tls default-gateway-tls --cert=/tmp/tls.crt --key=/tmp/tls.key \
>   -n openshift-ingress --dry-run=client -o yaml | oc apply -f -
> rm -f /tmp/tls.crt /tmp/tls.key
> ```

**Step 5d:** Label namespaces for Gateway route binding

The Gateway restricts HTTPRoute attachment to namespaces explicitly labeled with `maas.opendatahub.io/gateway-access=true`. This follows the principle of least privilege - only namespaces that are designated to expose services through the Gateway can create routes.

> **Important:**
> Any namespace that needs to serve models through the MaaS Gateway must be labeled with `maas.opendatahub.io/gateway-access=true`. Without this label, HTTPRoutes created in that namespace will not be accepted by the Gateway and the model will not be reachable.
>
> If you create additional namespaces for model serving, remember to apply this label:
>
> ```bash
> oc label namespace <your-namespace> \
>   maas.opendatahub.io/gateway-access=true --overwrite
> ```

Label the `redhat-ods-applications` namespace where the MaaS API route is created:

```bash
oc label namespace redhat-ods-applications \
  maas.opendatahub.io/gateway-access=true --overwrite
```

> **Note:** Model namespaces (`llm`, `external-models`) are labeled in their respective deployment phases.

**Step 5e:** Create Passthrough Route (Non-Cloud Platforms Only)

If your platform type from Step 5a was `None`, `BareMetal`, or `OpenStack`, you must create a passthrough Route. This routes external traffic through the OpenShift ingress controller to the Gateway's LoadBalancer service.

> **Note:** If your platform type from Step 5a was `AWS`, `Azure`, `GCP`, or another cloud provider, you can skip this step.

```bash
export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}')

envsubst '${CLUSTER_DOMAIN}' < manifests/03-maas-platform/openshift-gateway-setup/route.yaml.tmpl | oc apply -f -
```

> **Note:**
> **Why is this needed?**
>
> On non-cloud platforms, the Gateway's LoadBalancer service receives an IP from MetalLB (e.g., 10.10.10.11), but that IP is only routable within the cluster network. External traffic cannot reach it directly.
>
> The passthrough Route bridges external requests (via the OpenShift router at your cluster's public DNS) to the internal LoadBalancer IP, allowing the Gateway to be accessible from outside the cluster.

Verify the Route was created:

```bash
oc get route maas-default-gateway-https -n openshift-ingress
```

Expected output:

```
NAME                         HOST/PORT                              PATH   SERVICES                                 PORT    TERMINATION            WILDCARD
maas-default-gateway-https   maas.apps.<cluster-domain>                    maas-default-gateway-openshift-default   https   passthrough/Redirect   None
```

## Verification

After completing all steps, confirm the full platform state:

> **Tip:** On macOS, the local DNS resolver may cache negative lookups for `maas.apps.<cluster-domain>`. If `curl` reports "Could not resolve host" but `dig` or `nslookup` resolves the address correctly, either flush your DNS cache (`sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`) or use the `--resolve` flag: `curl -vsk --resolve "maas.${CLUSTER_DOMAIN}:443:$(dig +short maas.${CLUSTER_DOMAIN} | head -1)" https://maas.${CLUSTER_DOMAIN}`.

```bash
# Kuadrant ready
oc get kuadrant -n kuadrant-system

# Authorino running with TLS
oc get deployment authorino -n kuadrant-system
oc get secret authorino-server-cert -n kuadrant-system

# UWM running
oc get pods -n openshift-user-workload-monitoring

# GatewayClass accepted
oc get gatewayclass openshift-default

# Gateway programmed
oc get gateway maas-default-gateway -n openshift-ingress

# Check passthrough route exists (bare metal, Open Stack or None platform type)
oc get route maas-default-gateway-https -n openshift-ingress -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}'

# Verify TLS connection to the Gateway
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
echo $CLUSTER_DOMAIN
curl -vsk https://maas.${CLUSTER_DOMAIN} 2>&1 | grep -E "SSL connection|Connected"
```

Expected output:

```
$ oc get kuadrant -n kuadrant-system
NAME       MTLS AUTHORINO   MTLS LIMITADOR   AGE
kuadrant   false            false            49m

$ oc get deployment authorino -n kuadrant-system
oc get secret authorino-server-cert -n kuadrant-system
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
authorino   1/1     1            1           49m
NAME                    TYPE                DATA   AGE
authorino-server-cert   kubernetes.io/tls   2      49m

$ oc get pods -n openshift-user-workload-monitoring
NAME                                   READY   STATUS    RESTARTS   AGE
prometheus-operator-76b9c6d5dc-rrvn8   2/2     Running   0          23m
prometheus-user-workload-0             6/6     Running   0          23m
thanos-ruler-user-workload-0           4/4     Running   0          23m

$ oc get gatewayclass openshift-default
NAME                CONTROLLER                           ACCEPTED   AGE
openshift-default   openshift.io/gateway-controller/v1   True       23m

$ oc get gateway maas-default-gateway -n openshift-ingress
NAME                   CLASS               ADDRESS       PROGRAMMED   AGE
maas-default-gateway   openshift-default   10.10.10.11   True         13m

# (If you created a passthrough route in Step 5e)
$ oc get route maas-default-gateway-https -n openshift-ingress -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}'
True

$ CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
$ echo $CLUSTER_DOMAIN
apps.`<your cluster name>`.`<your domain>`
curl -vsk https://maas.${CLUSTER_DOMAIN} 2>&1 | grep -E "SSL connection|Connected"
* Connected to maas.apps.<cluster-domain> (...) port 443
* SSL connection using TLSv1.3 / ...    <-- exact cipher varies by client
```

## Appendix

### Directory Structure

```
manifests/02-platform-config/
  gateway-resources.yaml         # ConfigMap: maas-default-gateway proxy overrides (2Gi memory)
  rhoai-gateway-resources.yaml   # ConfigMap: openshift-ai-inference proxy overrides (2Gi memory)
  gateway.yaml.tmpl              # Gateway template (envsubst, references ConfigMap via parametersRef)
  gatewayclass.yaml              # GatewayClass resource
  kustomization.yaml             # Aggregates all subdirectories
  kuadrant/
    namespace.yaml               # kuadrant-system namespace
    service-annotation.yaml      # TLS cert annotation for Authorino
    kuadrant.yaml                # Kuadrant CR
    authorino.yaml               # Authorino TLS patch
    kustomization.yaml
  uwm/
    cluster-monitoring-config.yaml   # User Workload Monitoring ConfigMap
    kustomization.yaml
```

## References

- [MaaS Platform Setup (upstream)](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/platform-setup.md)
- [MaaS Gateway Setup (upstream)](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/maas-setup.md)
- [Red Hat Connectivity Link documentation](https://docs.redhat.com/en/documentation/red_hat_connectivity_link)
- [OpenShift User Workload Monitoring](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/monitoring/enabling-monitoring-for-user-defined-projects)
- [Gateway API on OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/networking/gateway-api)
## Next step

Proceed to [Phase 3: MaaS Platform](./03-maas-platform.md).
