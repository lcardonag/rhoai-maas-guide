# Phase 11: Lago billing

Lago commercial metering + **MaaS budget entities** (graduated throttling by patching one `MaaSSubscription` per entity — no API key rotation).

> **Status:** **MVP in progress** — Lago Helm + `maas-billing` services (`maas-billing-api`, `usage-reporter`, `budget-enforcer`). Enrollment UI planned.

> **Pick one backend:** do not install Lago and OpenMeter on the same cluster (`maas-billing` namespace). Remove OpenMeter first: `./scripts/uninstall-openmeter-billing.sh`

## Switch from OpenMeter

```bash
./scripts/uninstall-openmeter-billing.sh
./scripts/setup-maas.sh --from-phase 11 --with-lago-billing
./scripts/verify-lago.sh
```

See [docs/11-lago-billing.md](../../docs/11-lago-billing.md#switch-from-openmeter-to-lago).

## What is installed today

| Component | Namespace | Status |
|-----------|-----------|--------|
| Lago platform (Helm) | `lago` | Installed via `scripts/install-lago-platform.sh` |
| Tier templates + RBAC | `maas-billing` | `manifests/11-lago/base/` |
| maas-billing-api | `maas-billing` | `manifests/11-lago/maas-billing-api/` |
| usage-reporter | `maas-billing` | `manifests/11-lago/usage-reporter/` |
| budget-enforcer | `maas-billing` | `manifests/11-lago/budget-enforcer/` |
| enrollment-ui | `maas-billing` | Planned |

## Prerequisites

- Phases **1–4** (MaaS platform healthy)
- At least one model registered (Phase 5, GUI, or Phase 8)
- **Phase 7 gateway telemetry** — required for `usage-reporter` (Prometheus labels: `subscription`, `user`, `model`). Phase 11 **auto-installs Phase 7** if `TelemetryPolicy/maas-telemetry` is missing.

**Optional:** [Compact MaaS](../10-compact-maas/README.md) for self-serve subscribe/key UX (not required for admin enrollment).

## Install

### Automated (recommended)

```bash
# Standalone billing stack (auto Phase 7 if needed)
./scripts/setup-maas.sh --from-phase 11 --with-lago-billing

# Or shorthand wrapper
./scripts/install-lago-billing.sh

# With Compact MaaS console (separate GUIs — both optional)
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas --with-lago-billing

# External Lago (skip Helm); still applies maas-billing base in-cluster
./scripts/setup-maas.sh --from-phase 11 --with-lago-billing --skip-lago-platform
```

### Manual steps

```bash
# 1. Observability (if not already present)
./scripts/setup-maas.sh --from-phase 7 --with-observability --skip-models --skip-verify

# 2. Lago platform
./scripts/install-lago-platform.sh

# 3. MaaS billing base + services
oc apply -k manifests/11-lago/base/
oc apply -k manifests/11-lago/maas-billing-api/
./scripts/build-maas-billing-image.sh
./scripts/install-lago-catalog.sh   # after LAGO_API_KEY is set in maas-billing-secrets
oc apply -k manifests/11-lago/usage-reporter/
oc apply -k manifests/11-lago/budget-enforcer/
```

### Environment

| Variable | Meaning |
|----------|---------|
| `LAGO_NAMESPACE` | Helm namespace (default `lago`) |
| `LAGO_HELM_RELEASE` | Helm release name (default `lago`) |
| `LAGO_DATABASE_URL` | External Postgres URL (optional; chart defaults for dev) |
| `LAGO_REDIS_URL` | External Redis URL (optional) |
| `LAGO_LICENSE` | Lago Premium license key (optional) |

**Required secret** (create once Lago is up — Developers → API keys in Lago UI):

```bash
oc create secret generic maas-billing-secrets -n maas-billing \
  --from-literal=LAGO_API_KEY='your-lago-organization-api-key'
```

Helm values template: `manifests/11-lago/lago/values-openshift.yaml`

## Verify

```bash
./scripts/verify-lago.sh
```

## License

- This guide: Apache-2.0
- **Lago platform:** AGPL-3.0 ([getlago/lago](https://github.com/getlago/lago))

## References

- [docs/11-lago-billing.md](../../docs/11-lago-billing.md) — full architecture and MVP checklist
- [docs/12-openmeter-billing.md](../../docs/12-openmeter-billing.md) — aligned enforcement model (Apache alternative)
- [docs/07-observability.md](../../docs/07-observability.md) — gateway telemetry
