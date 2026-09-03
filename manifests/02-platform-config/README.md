# Phase 2: Platform Configuration

Configure Kuadrant/Authorino, User Workload Monitoring, GatewayClass, and Gateways.

Full documentation: https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/02-platform-config.html

## Gateway proxy memory (2Gi)

| File | Gateway |
|------|---------|
| `gateway-resources.yaml` | `maas-default-gateway` |
| `gateway-resources.yaml` | `maas-default-gateway` |
| `rhoai-gateway-resources.yaml` | `openshift-ai-inference` (+ patch `data-science-gateway-config` via script) |

All three Istio gateway deployments in `openshift-ingress` need **2Gi** memory limits when Kuadrant Wasm loads. The default **1Gi** causes `OOMKilled` / `CrashLoopBackOff`.

`setup-maas.sh` applies both ConfigMaps, patches RHOAI gateways, and syncs **`default-gateway-tls`** from the ingress cert (required for `openshift-ai-inference` HTTPS listener) after Phases 2 and 4.
