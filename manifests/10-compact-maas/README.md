# Phase 10 — Compact MaaS (optional)

Optional **thin UI/BFF** over native RHOAI MaaS (maas-api, Kuadrant/Limitador, OpenShift Groups). Namespace: `compact-maas`. **No LiteLLM** in the path.

**Product role:** External **MaaS portal** (LiteMaaS-shaped) — enroll, subscribe, mint/list/revoke API keys without OpenShift AI. Admin: ExternalModel + enrollment. Does **not** replace native MaaS or Gen AI Studio Playground.

Full guide: [docs/09-optional-guis.md](../../docs/09-optional-guis.md).

## Prerequisites

- Phases **1–4** complete; `https://maas.<cluster-domain>/maas-api/health` returns healthy
- `oc` (cluster-admin or project create + build), `helm`
- Sibling repo cloned next to this guide (see below)

## Install

```bash
# After MaaS platform is up (GUI-only resume — typical)
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas

# Fresh cluster: platform + Compact MaaS, skip bundled Phase 5 models
./scripts/setup-maas.sh --skip-models --with-compact-maas
```

Expect **10–25 minutes** for Phase 10: `deploy.sh` runs OpenShift binary builds for backend and frontend, then Helm.

## Verify (including native MaaS regression)

```bash
./scripts/verify-guis.sh --compact-maas
```

Fails if gateway `POST /maas-api/v1/api-keys` breaks after deploy (common when `compact-maas-bbr-anchor` strips Authorino headers).

```bash
./scripts/fix-compact-maas-native-maas.sh          # diagnose
./scripts/fix-compact-maas-native-maas.sh --apply-fix   # remove anchor workaround
oc -n compact-maas get route compact-maas -o jsonpath='https://{.spec.host}{"\n"}'
```

## Sibling repo

| Env | Default |
|-----|---------|
| `COMPACT_MAAS_DIR` | `../compact-maas`, then fall back to `../rhoai-maas-console` (next to this guide) |
| `MAAS_CONSOLE_DIR` | Deprecated alias for `COMPACT_MAAS_DIR` |

Clone (pick one name; same codebase today):

```bash
git clone https://github.com/rh-aiservices-bu/rhoai-maas-console.git ../rhoai-maas-console
# or
git clone https://github.com/rh-aiservices-bu/compact-maas.git ../compact-maas
```

Must contain `scripts/deploy.sh`.

## Manual deploy

```bash
export MAAS_GATEWAY_URL="https://maas.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
cd "${COMPACT_MAAS_DIR:-../rhoai-maas-console}"
./scripts/apply-phase2-rbac.sh   # mass-admins + compact-maas-admin
./scripts/deploy.sh              # builds, Helm, RBAC, BBR EnvoyFilter
./scripts/verify-guis.sh --compact-maas
```

## Fix OAuth / enrollment URLs

Wrong cluster domain, `DNS_PROBE_FINISHED_NXDOMAIN` on login:

```bash
./scripts/fix-compact-maas-config.sh --apply-fix
```

Phase 10 and console `deploy.sh` run this path automatically when config verify fails.

## What Phase 10 runs

1. `apply-phase2-rbac.sh` — admin groups + `compact-maas-admin` ClusterRoleBinding
2. `deploy.sh` — ImageStreams, binary builds, Helm install, rollout, ExternalModel/BBR RBAC, enrollment + metrics RBAC; auto re-Helm if OAuth/gateway verify fails
3. `fix-compact-maas-config.sh --apply-fix` — if deployment env still mismatches cluster
4. `fix-compact-maas-native-maas.sh --apply-fix` — if gateway key mint fails (BBR anchor)
5. `verify-guis.sh --compact-maas` — includes OAuth config + native key mint regression

## Coexistence

Safe to install together with Phase 9 (`litemaas`). Compact MaaS never modifies the `litemaas` namespace.

## Enhancements

Track 1 (guide): verify/fix scripts + product docs. Track 2+ (console): gateway-root URL mode, BFF fixes — [docs/compact-maas-enhancements.md](../../docs/compact-maas-enhancements.md).

## License

Compact MaaS (`compact-maas` / `rhoai-maas-console`) is **AGPL-3.0-only**. See `rhoai-maas-console/README.md`.
