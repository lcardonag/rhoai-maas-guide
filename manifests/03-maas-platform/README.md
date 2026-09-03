# Phase 3: MaaS Platform Infrastructure

PostgreSQL database and `maas-db-config` secret for the MaaS API.

Full documentation: https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/03-maas-platform.html

## Apply

```bash
# Create secrets (see Phase 3 docs), then:
oc apply -k manifests/03-maas-platform/
```

PostgreSQL runs in `redhat-ods-applications`. After Phase 4, `maas-api` may deploy to `redhat-ai-gateway-infra` on RHOAI 3.5+ (health URL unchanged: `https://maas.<domain>/maas-api/health`).
