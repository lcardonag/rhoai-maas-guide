# Phase 12: OpenMeter billing

Apache-2.0 metering + **MaaS budget entities** (graduated throttling by patching one `MaaSSubscription` per entity — no API key rotation).

> **Status:** **MVP in progress** — OpenMeter Helm + `maas-billing` services (shared image with Phase 11, `BILLING_BACKEND=openmeter`). Enrollment UI planned.

> **Pick one backend:** do not install Lago and OpenMeter on the same cluster (`maas-billing` namespace). `setup-maas.sh` aborts if Lago is already installed and prints removal steps.

## What is installed

| Component | Namespace | Status |
|-----------|-----------|--------|
| OpenMeter platform (Helm) | `openmeter` | `scripts/install-openmeter-platform.sh` |
| Tier templates + RBAC | `maas-billing` | `manifests/12-openmeter/base/` |
| maas-billing-api | `maas-billing` | `manifests/12-openmeter/maas-billing-api/` |
| usage-reporter | `maas-billing` | `manifests/12-openmeter/usage-reporter/` |
| budget-enforcer | `maas-billing` | `manifests/12-openmeter/budget-enforcer/` |
| enrollment-ui | `maas-billing` | Planned |

## Prerequisites

- Phases **1–4** (MaaS platform healthy)
- At least one model registered (Phase 5, GUI, or Phase 8)
- **Phase 7 gateway telemetry** — auto-installed by Phase 12 if missing

## Install

```bash
# Standalone
./scripts/setup-maas.sh --from-phase 12 --with-openmeter-billing

# Shorthand
./scripts/install-openmeter-billing.sh

# With Compact MaaS
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas --with-openmeter-billing

# External OpenMeter (skip Helm)
./scripts/setup-maas.sh --from-phase 12 --with-openmeter-billing --skip-openmeter-platform
```

### Manual steps

```bash
./scripts/setup-maas.sh --from-phase 7 --with-observability --skip-models --skip-verify
./scripts/install-openmeter-platform.sh
./scripts/install-openmeter-catalog.sh      # meter maas_llm_tokens + feature llm_tokens
./scripts/install-openmeter-demo-entity.sh  # optional: enroll admin budget entity
oc apply -k manifests/12-openmeter/base/
oc apply -k manifests/12-openmeter/maas-billing-api/
MAAS_BILLING_SRC=manifests/11-lago/maas-billing ./scripts/build-maas-billing-image.sh
./scripts/install-openmeter-catalog.sh
oc apply -k manifests/12-openmeter/usage-reporter/
oc apply -k manifests/12-openmeter/budget-enforcer/
```

Optional API key (OSS often allows unauthenticated in-cluster access):

```bash
oc create secret generic maas-billing-secrets -n maas-billing \
  --from-literal=OPENMETER_API_KEY='your-key'
```

### Enroll an entity

```bash
BILLING_API=$(oc -n maas-billing get route maas-billing-api -o jsonpath='https://{.spec.host}')

curl -sk -X POST "${BILLING_API}/api/v1/entities" \
  -H 'Content-Type: application/json' \
  -d '{
    "display_name": "Admin",
    "member_type": "user",
    "member_ref": "admin",
    "monthly_budget_credits": 1000000
  }'
```

Mint keys with `subscription: "budget-admin"`.

## OpenShift quirks (Helm upgrade safe)

The upstream chart is not OpenShift-ready out of the box. **`install-openmeter-platform.sh` always runs post-Helm fixes** so upgrades do not leave the API in CrashLoopBackOff:

| Issue | Symptom | Fix |
|-------|---------|-----|
| Postgres SSL | `pq: SSL is not enabled on the server` | Append `?sslmode=disable` to `ConfigMap/openmeter` |
| Privileged port | `bind: permission denied` on port 80 | `openmeter-api` listens on **8080** |

If you run `helm upgrade` directly (without the install script), re-apply fixes:

```bash
./scripts/fix-openmeter-openshift.sh
```

## Verify

```bash
./scripts/verify-openmeter.sh
./scripts/verify-openmeter-e2e.sh
```

## Shared billing image

Python source lives in `manifests/11-lago/maas-billing/` (used by both Phase 11 and 12). Set `BILLING_BACKEND` via ConfigMap.

## License

- This guide: Apache-2.0
- **OpenMeter:** Apache-2.0 ([openmeterio/openmeter](https://github.com/openmeterio/openmeter))

## References

- [docs/12-openmeter-billing.md](../../docs/12-openmeter-billing.md)
- [docs/11-lago-billing.md](../../docs/11-lago-billing.md) — Lago alternative (invoices/Stripe)
