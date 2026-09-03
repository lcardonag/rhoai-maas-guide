# Phase 4: RHOAI Configuration

Enable `modelsAsService: Managed` on the DataScienceCluster and dashboard flags for MaaS.

Full documentation: https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/04-rhoai-config.html

## Verify MaaS is ready

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
curl -sk "https://maas.${CLUSTER_DOMAIN}/maas-api/health"
# Expected: {"status":"healthy"}
```

## `maas-api` namespace

| RHOAI | `maas-api` deployment namespace |
|-------|----------------------------------|
| 3.4   | `redhat-ods-applications`        |
| 3.5+  | `redhat-ai-gateway-infra`      |

PostgreSQL stays in `redhat-ods-applications`. The external health URL is unchanged.

## After Phase 4

- Deploy models via Phase 5 (bundled only), **Publish as MaaS** in the GUI, or manual `MaaSModelRef` YAML.
- `setup-maas.sh` also syncs `default-gateway-tls` and applies 2Gi gateway proxy memory (see `manifests/02-platform-config/`).

## Troubleshooting

**Duplicate OperatorGroup:** if the GUI and script both installed RHOAI, keep one `OperatorGroup` in `redhat-ods-operator`. See Phase 4 docs.
