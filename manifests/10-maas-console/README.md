# Phase 10 — RHOAI MaaS Console (optional)

Optional **thin UI/BFF** over native RHOAI MaaS (maas-api, Kuadrant/Limitador, OpenShift Groups). Namespace: `rhoai-maas-console`. **No LiteLLM** in the path.

```bash
./scripts/setup-maas.sh --from-phase 10 --with-maas-console
```

## Sibling repo

| Env | Default |
|-----|---------|
| `MAAS_CONSOLE_DIR` | `../rhoai-maas-console` (next to this guide) |

Must contain `scripts/deploy.sh`. Phase 10 also runs `scripts/apply-phase2-rbac.sh` when present, then deploy with:

```bash
export MAAS_GATEWAY_URL=https://maas.<cluster-domain>
```

## Coexistence

Safe to install together with Phase 9 (`litemaas`). The console never modifies the `litemaas` namespace.
