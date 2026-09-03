# Phase 3: MaaS Platform Infrastructure

Deploy the PostgreSQL database required by the MaaS API for key lifecycle management.

> **Tip:** All file paths and `oc apply` commands in this guide are relative to the [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide) repository root. Make sure you have cloned it and are working from its root directory (see [Getting Started](./index.md#getting-started)).

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

## Prerequisites

- [Phase 2](./02-platform-config.md) (platform configuration) is completed
- Kuadrant, User Workload Monitoring, GatewayClass, and Gateway are configured
- `redhat-ods-applications` namespace exists (created by the RHOAI operator in Phase 1)
## Overview

The MaaS platform requires a PostgreSQL database before the RHOAI operator can fully enable Models-as-a-Service. Deploying PostgreSQL and creating the `maas-db-config` secret **before** enabling `modelsAsService` in the DataScienceCluster (Phase 4) ensures the `maas-api` deployment starts without crash-looping.

1. **PostgreSQL database** - stores API key metadata (hashed tokens, subscription bindings, expiration, revocation state).
1. **PostgreSQL secrets** - `postgres-creds` (DB credentials) and `maas-db-config` (connection URL consumed by maas-api).
> **Note:** PostgreSQL and `maas-db-config` live in `redhat-ods-applications` on all versions. After Phase 4, the `maas-api` **deployment** may appear in `redhat-ods-applications` (RHOAI 3.4) or `redhat-ai-gateway-infra` (RHOAI 3.5+). The public health endpoint remains `https://maas.<cluster-domain>/maas-api/health`.

> **Tip:** If you prefer the fully automated path, see [Automated Setup](./quick-start.md). To run only this phase automatically: `./scripts/setup-maas.sh --from-phase 3`

## Manual setup

### Step 1: Create PostgreSQL secrets

These secrets cannot be stored in git. Create them imperatively:

```bash
# Generate a random password
POSTGRES_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/')

# Create postgres-creds (consumed by the PostgreSQL deployment)
oc create secret generic postgres-creds \
  -n redhat-ods-applications \
  --from-literal=POSTGRES_USER=maas \
  --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  --from-literal=POSTGRES_DB=maas

# Create maas-db-config (consumed by maas-api)
oc create secret generic maas-db-config \
  -n redhat-ods-applications \
  --from-literal=DB_CONNECTION_URL="postgresql://maas:${POSTGRES_PASSWORD}@postgres:5432/maas?sslmode=disable"
```

### Step 2: Deploy PostgreSQL

Apply the PostgreSQL manifests using Kustomize:

```bash
oc apply -k manifests/03-maas-platform/
```

Or apply individually:

```bash
oc apply -f manifests/03-maas-platform/postgres-pvc.yaml
oc apply -f manifests/03-maas-platform/postgres-service.yaml
oc apply -f manifests/03-maas-platform/postgres-deployment.yaml
```

## Verify

### PostgreSQL

```bash
# Wait for PostgreSQL pod to be ready
oc wait --for=condition=Available deployment/postgres \
  -n redhat-ods-applications --timeout=120s

# Confirm the pod is running
oc get pods -n redhat-ods-applications -l app=postgres
```

### PostgreSQL secrets

```bash
# Verify both secrets exist
oc get secret postgres-creds -n redhat-ods-applications
oc get secret maas-db-config -n redhat-ods-applications
```

### Gateway

```bash
oc wait --for=condition=Programmed gateway/maas-default-gateway \
  -n openshift-ingress --timeout=60s
```

## What this creates

| Resource | Namespace | Purpose |
| --- | --- | --- |
| `PVC/postgres-data` | redhat-ods-applications | 20Gi storage for PostgreSQL data |
| `Service/postgres` | redhat-ods-applications | ClusterIP service for PostgreSQL |
| `Deployment/postgres` | redhat-ods-applications | PostgreSQL 16 instance (RHEL 9 based) |
| `Secret/postgres-creds` | redhat-ods-applications | DB user, password, database name (imperative) |
| `Secret/maas-db-config` | redhat-ods-applications | Connection URL for maas-api (imperative) |

## Troubleshooting

### PostgreSQL pod not starting

```bash
oc describe pod -n redhat-ods-applications -l app=postgres
oc logs -n redhat-ods-applications -l app=postgres
```

Common causes:

- `postgres-creds` secret does not exist (create it per Step 1)
- PVC cannot be bound (check StorageClass availability)
### Gateway stuck in Pending

On baremetal/OpenStack clusters without a cloud LB controller:

- See `openshift-gateway-setup/` for MetalLB configuration
- On cloud clusters, the LB provisions automatically
## Appendix

### Directory Structure

```
manifests/03-maas-platform/
  kustomization.yaml             # Aggregates PostgreSQL resources
  postgres-deployment.yaml       # PostgreSQL 16 Deployment
  postgres-pvc.yaml              # 20Gi PersistentVolumeClaim
  postgres-service.yaml          # ClusterIP Service
  openshift-gateway-setup/
    gateway.yaml.tmpl            # Gateway template (envsubst)
    route.yaml.tmpl              # Passthrough Route (non-cloud)
    metallb-config.yaml          # IPAddressPool + L2Advertisement
    cleanup.yaml                 # Cleanup resources
    kustomization.yaml
```

## References

- [MaaS Setup (upstream)](https://github.com/opendatahub-io/models-as-a-service/blob/main/docs/content/install/maas-setup.md)
- [RHOAI 3.4 MaaS Official Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index)
## Next step

Proceed to [Phase 4: RHOAI Configuration](./04-rhoai-config.md).
