# Phase 9 — LiteMaaS + LiteLLM (optional)

Optional **PoC GUI** that sits beside native RHOAI MaaS. Deploys into namespace `litemaas` and includes the **LiteLLM** proxy (virtual keys, $ budgets, single OpenAI-compatible base URL).

This guide does **not** vendor LiteMaaS charts. Orchestration calls a sibling checkout:

```bash
# From the guide root (after phases 1–6)
./scripts/setup-maas.sh --from-phase 9 --with-litemaas

# Optional: wire LiteLLM backends to the MaaS gateway
export MAAS_API_KEY=sk-oai-...   # mint via MaaS / Compact MaaS
./scripts/setup-maas.sh --from-phase 9 --with-litemaas
# (wire runs automatically when MAAS_API_KEY is set)
```

## Sibling repo

| Env | Default |
|-----|---------|
| `LITEMAAS_RHOAI_DIR` | `../litemaas-rhoai` (next to this guide) |

Must contain `scripts/install.sh` and optionally `scripts/wire-maas-models.sh`.

## Product path note

Prefer **Phase 10 (Compact MaaS)** for native MaaS UX without LiteLLM. Use LiteMaaS when you need proxy-only features for demos or comparison.

## License

The `litemaas-rhoai` deploy wrapper is **AGPL-3.0-only**; upstream LiteMaaS keeps its own license. See `litemaas-rhoai/README.md`.
