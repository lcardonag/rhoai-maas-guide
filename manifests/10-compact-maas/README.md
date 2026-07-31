# Phase 10 — Compact MaaS (optional)

Optional **thin UI/BFF** over native RHOAI MaaS (maas-api, Kuadrant/Limitador, OpenShift Groups). Namespace: `compact-maas`. **No LiteLLM** in the path.

```bash
./scripts/setup-maas.sh --from-phase 10 --with-compact-maas
```

## Sibling repo

| Env | Default |
|-----|---------|
| `COMPACT_MAAS_DIR` | `../compact-maas`, then fall back to `../rhoai-maas-console` (next to this guide) |
| `MAAS_CONSOLE_DIR` | Deprecated alias for `COMPACT_MAAS_DIR` |

Must contain `scripts/deploy.sh`. Phase 10 also runs `scripts/apply-phase2-rbac.sh` when present, then deploy with:

```bash
export MAAS_GATEWAY_URL=https://maas.<cluster-domain>
```

## Coexistence

Safe to install together with Phase 9 (`litemaas`). Compact MaaS never modifies the `litemaas` namespace.
