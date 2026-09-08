# AI-Assisted Installation

This repository includes a skill definition that provides AI-assisted MaaS installation. The `/install-maas` skill wraps the same `setup-maas.sh` script used in the [Automated Setup](./quick-start.md), letting your AI coding agent handle cluster detection, error diagnosis, and interactive troubleshooting.

The skill works with any AI coding tool that supports skill definitions:

- [Claude Code](https://claude.ai/code) / [Open Code](https://opencode.ai)
- [Cursor](https://cursor.com)
- [Roo Code](https://roosoft.com)
- Other AI coding agents with skill support
> **Tip:** All file paths and `oc apply` commands in this guide are relative to the [rhoai-maas-guide](https://github.com/rh-aiservices-bu/rhoai-maas-guide) repository root. Make sure you have cloned it and are working from its root directory (see [Getting Started](./index.md#getting-started)).

> **Important:** This guide is not a replacement for the [official Red Hat OpenShift AI Models as a Service documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html/govern_llm_access_with_models-as-a-service/index). It is a companion resource with opinionated Kustomize manifests and automation scripts to accelerate deployment.

## Prerequisites

- An AI coding tool installed (see list above)
- `oc` CLI authenticated as cluster-admin
- This repository cloned locally
## Usage

Open the repository in your AI coding tool and invoke the skill:

```
/install-maas
```

### Arguments

All arguments from `setup-maas.sh` are supported:

```
/install-maas --model simulator
/install-maas --from-phase 4
/install-maas --with-observability
/install-maas --skip-models --skip-verify
```

| Option | Description |
| --- | --- |
| `--model <name>` | Model to deploy: `simulator` (CPU), `granite-tiny-gpu`, `gpt-oss-20b`, `auto` |
| `--from-phase <N>` | Start from phase N (0–11; Phases 9–11 are optional) |
| `--skip-models` | Skip Phase 5 (platform-only; use before GUI deploy or custom catalog models) |
| `--skip-verify` | Skip Phase 6 (verification) |
| `--with-observability` | Also run Phase 7 (COO + telemetry) |
| `--with-compact-maas` | Also run Phase 10 (Compact MaaS GUI) |
| `--with-lago-billing` | Also run Phase 11 (Lago billing; auto Phase 7 if telemetry missing) |
| `--with-litemaas` | Also run Phase 9 (LiteMaaS PoC) |

## What the Skill Does

The skill runs `./scripts/setup-maas.sh` from the repository root with the provided arguments. Your AI coding agent monitors the output, detects failures, and can help diagnose issues interactively.

The skill has access to `oc`, `envsubst`, `curl`, `jq`, and other CLI tools needed for MaaS deployment.

## Skill Definition

The skill is defined in `.claude/skills/install-maas/SKILL.md` within this repository. It is automatically discovered when you open the repo in a compatible AI coding tool.
