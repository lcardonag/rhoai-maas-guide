# Gen AI Studio — MCP server catalog

Optional manifests for **Gen AI Studio Playground** MCP integration (RHOAI 3.5+).

| File | Purpose |
|------|---------|
| `gen-ai-aa-mcp-servers.yaml` | ConfigMap listing MCP servers for the Playground MCP tab |

**Prerequisites:** OGX enabled on the DataScienceCluster (`spec.components.ogx.managementState: Managed`). See [docs/gen-ai-studio.md](../../docs/gen-ai-studio.md).

```bash
oc apply -f gen-ai-aa-mcp-servers.yaml
oc get configmap gen-ai-aa-mcp-servers -n redhat-ods-applications
```

Edit `data:` keys to add your own servers (each value is JSON with `url` and `description`).
