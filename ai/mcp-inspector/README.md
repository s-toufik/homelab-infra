# MCP Inspector

The [MCP Inspector](https://github.com/modelcontextprotocol/inspector) web page, on `https://<HOMELAB_DOMAIN>:6274` behind the sign-in: lists agent-toolbox's tools and runs them by hand, from any browser on the tailnet.

```text
Browser ── HTTPS, signed in ──► caddy :6274 ──► mcp-inspector:6274 ── MCP (HTTP) ──► agent-toolbox:8001/mcp
                                                 └──────────── network `agents` ────────────┘
```

- `servers.json` is its server list, read-only: agent-toolbox only. The page can't add servers.
- It lives on the `agents` network only, like agent-toolbox: it can start processes, so it reaches no database, Kafka or LLM. It publishes no port: Caddy serves it.
- It checks the `Host` header against its own name (Caddy rewrites it to `mcp-inspector:6274`) and the browser's `Origin` against `https://<HOMELAB_DOMAIN>:6274` (`ALLOWED_ORIGINS`). Its API token is generated at each start and handed to the page it serves.
- Version: `MCP_INSPECTOR_TAG` in `.env`.
