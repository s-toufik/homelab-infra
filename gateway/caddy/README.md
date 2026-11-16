# Caddy (gateway) and oauth2-proxy

Caddy is the only entry point for browsers: HTTPS with a Tailscale certificate on every web port, and a sign-in check on every request. oauth2-proxy answers that check from the session cookie and handles sign-in and sign-out with [Keycloak](../keycloak/README.md). Grafana signs in with Keycloak itself, so Caddy only adds HTTPS in front of it.

```text
Browser ── HTTPS ──► caddy ── "signed in?" ──► oauth2-proxy ◄── sign-in ──► keycloak
                       │      yes: Remote-User = account
                       │      no:  pages → https://<HOMELAB_DOMAIN>/oauth2/sign_in, then back; APIs → 401
                       │
  :443   /healthz           answered by Caddy ("OK", no sign-in): HTTPS and certificate check
         /                  homelab-ui
         /api/agent/…       agent-supervisor      (/v1/*, /actuator/health/* only; streaming on)
         /api/agents/<n>/…  agent-<n>             (the same, for each agent)
         /api/people/…      keycloak        (/admin/realms/homelab/users*, with the admin's access token; admin only)
         /api/prometheus/…  prometheus      (queries, labels, targets, rules, alerts; GET only)
         /api/loki/…        loki            (queries, labels, series; GET only)
         /api/tempo/…       tempo           (search, tags, traces; GET only)
         /api/alloy/…       alloy           (/api/v0/web/components; GET only)
         /api/kafka/…       kafka-ui        (/api/clusters/*; changes: admin only)
         /api/llm/…         llm             (/v1/models, /v1/chat/completions, /running, /logs*; unload: admin only)
         /api/toolbox/…     agent-toolbox   (/mcp; Host rewritten to agent-toolbox:8001, Origin dropped)
         /api/account/…     keycloak        (/realms/homelab/account/*, with the session's access token)
         /api/kube/…        kube-api        (the Kubernetes API; admin only)
         /api/tasker/…      postgrest       (+ X-Gateway-Secret)
         /api/health/<svc>  every container's health endpoint (homelab-ui's Status page)
         /oauth2/…          oauth2-proxy    (sign in, sign out, /oauth2/userinfo)
  :8443                     keycloak        (sign-in pages; /admin blocked)
  :3000                     grafana         (its own Keycloak sign-in)
  :9090                     prometheus      (signed in; /-/quit and /-/reload blocked)
  :8080 :12345 :3100 :3200 :9308
                            kafka-ui, alloy, loki, tempo, kafka-exporter (signed in)
  :8090                     llm             (signed in, or `Authorization: Bearer <LLM_GATEWAY_API_KEY>`)
  :6274                     mcp-inspector   (signed in; Host rewritten to mcp-inspector:6274) ─► agent-toolbox
  :4466                     headlamp        (signed in, admin only) ─► kube-api ─► Kubernetes API
  :8100                     agent-supervisor      (signed in; its API and /docs over HTTPS, :8000 stays plain HTTP for tailnet clients)
```

## Certificate

`HOMELAB_DOMAIN` is this machine's Tailscale name (`<machine>.<tailnet>.ts.net`, `domain` in `environments/local.yaml`), with MagicDNS and HTTPS certificates turned on in the Tailscale admin console. Caddy gets the certificate from the server's Tailscale daemon through its socket, at the first HTTPS connection. The pod mounts the folder `/run/tailscale`, not the socket file: tailscaled makes a new socket each time it restarts, and a file mount would keep the old one (`connection refused`, then `tlsv1 alert internal error` in browsers). The folder itself stays across restarts thanks to `RuntimeDirectoryPreserve=restart` in tailscaled's drop-in ([DevOps guide](../../devops_guide.md#8-start-tailscale-and-ssh-at-boot)). Devices need Tailscale to open the homelab.

Inside the cluster, DNS answers `HOMELAB_DOMAIN` with Caddy's Service (the `coredns-custom` ConfigMap this release adds to `kube-system`), so oauth2-proxy and Grafana reach Keycloak's public address through Caddy with the same valid certificate.

Caddy's ports are host ports bound to the Tailscale address only: the tailnet's devices reach them, nothing else on the network does.

## Session

- Cookie `__Host-homelab`: encrypted and signed with `OAUTH2_PROXY_COOKIE_SECRET`, `HttpOnly`, `Secure`, `SameSite=Lax`, valid 8 hours, shared by every port of `HOMELAB_DOMAIN` (browsers don't scope cookies by port), so one sign-in covers every tool. It holds no password.
- Disabling an account ends its Keycloak sessions at once, and its homelab session at the latest when the 8 hours are up. `make sessions-revoke` changes the cookie key, so every session ends immediately.
- The homelab-ui APIs added for its tool pages refuse a change (anything but GET, HEAD, OPTIONS) without the header `X-Homelab-Request: 1`, which a page on another site can't send. Changes to Kafka, unloading a model and the whole Kubernetes API also need the realm role `admin` (`/oauth2/auth?allowed_groups=role:admin`, else 403).
- Each API also needs the page that uses it (`(page_access)`, else 403): the realm role `admin`, or the page's own role. homelab-ui shows only the pages a person was given, and these rules refuse the rest, so hiding a page is never the only lock.

  | API | Roles that open it (besides `admin`) |
  |---|---|
  | `/api/agents/<n>/v1/*`, `/api/agent/v1/*` | `agent:<n>` (`agent:supervisor` for `/api/agent`); `/v1/agents` and health stay open to every signed-in person |
  | `/api/tasker/` | `app:tasker` |
  | `/api/prometheus/` | `page:metrics`, `page:dashboards`, `page:status` |
  | `/api/loki/` | `page:logs`, `page:dashboards` |
  | `/api/tempo/` | `page:traces`, `page:logs` |
  | `/api/alloy/` | `page:pipeline` |
  | `/api/kafka/` | `page:kafka` |
  | `/api/llm/` | `page:models` |
  | `/api/toolbox/` | `page:tools` |
  | `/api/people/`, `/api/kube/` | none: admin only |

  The page roles come from [`../keycloak/pages.txt`](../keycloak/pages.txt). A role given or taken counts from the person's next session refresh, at most 4 minutes.
- `/api/people/` lets homelab-ui's People pages create and delete accounts, give and take page roles, disable, sign out and reset a password. Only `/users`, `/users/<id>`, `/users/<id>/role-mappings/realm` (and `/available`, to find a role's id: Keycloak wants the id with the name when giving a role), `/users/<id>/reset-password` and `/users/<id>/logout` pass. It sends Keycloak the admin's own access token, and Keycloak checks it too: the `admin` role carries realm-management's `view-users`, `query-users` and `manage-users`. The Keycloak admin console stays blocked.
- `/api/account/` sends Keycloak the session's access token (`--pass-access-token`); oauth2-proxy refreshes it every 4 minutes (`--cookie-refresh=4m`), before Keycloak's 5-minute lifetime ends.
- Caddy deletes `Remote-User`, `X-Gateway-Secret` and the `X-Auth-Request-*` headers from every incoming request before adding its own, and drops the browser's cookies before proxying to anything but Grafana and Keycloak.

## Adding a route or a tool

- An API for homelab-ui: a `handle_path /api/<name>/*` block inside `handle /api/*` (it is then behind the sign-in check), limited to the paths the UI needs, and an `api` path for the service in homelab-ui.
- A web tool: a site `{$HOMELAB_DOMAIN}:<port> { import signed_in_tool <service>:<port> }`, and the port in [`values.yaml.gotmpl`](values.yaml.gotmpl) with `hostPort`.

`make validate` runs `caddy validate`; apply an edited `Caddyfile` with `make apply R=caddy` (the pod restarts with it).

Caddy runs the directives of a block in its own order, not the written one: `rewrite` comes before `respond`, `forward_auth` and `reverse_proxy`. A route that checks the path the browser asked for and then rewrites it (`/api/people`) wraps its directives in `route { }`, which keeps the written order; otherwise the check sees the rewritten path and refuses everything with 404.
