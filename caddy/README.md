# Caddy (gateway) and oauth2-proxy

Caddy is the only entry point for browsers: HTTPS with a Tailscale certificate on every web port, and a sign-in check on every request. oauth2-proxy answers that check from the session cookie and handles sign-in and sign-out with [Keycloak](../keycloak/README.md). Grafana signs in with Keycloak itself, so Caddy only adds HTTPS in front of it.

```text
Browser ── HTTPS ──► caddy ── "signed in?" ──► oauth2-proxy ◄── sign-in ──► keycloak
                       │      yes: Remote-User = account
                       │      no:  pages → https://<HOMELAB_DOMAIN>/oauth2/sign_in, then back; APIs → 401
                       │
  :443   /healthz           answered by Caddy ("OK", no sign-in): HTTPS and certificate check
         /                  homelab-ui
         /api/agent/…       agent-runtime   (/v1/*, /actuator/health/* only; streaming on)
         /api/prometheus/…  prometheus      (/api/v1/query, /api/v1/query_range only)
         /api/tasker/…      postgrest       (+ X-Gateway-Secret)
         /api/health/<svc>  grafana, prometheus, alloy, kafka-ui, llm health endpoints
         /oauth2/…          oauth2-proxy    (sign in, sign out, /oauth2/userinfo)
  :8443                     keycloak        (sign-in pages; /admin blocked)
  :3000                     grafana         (its own Keycloak sign-in)
  :9090                     prometheus      (signed in; /-/quit and /-/reload blocked)
  :8080 :12345 :3100 :3200 :9308
                            kafka-ui, alloy, loki, tempo, kafka-exporter (signed in)
  :8090                     llm             (signed in, or `Authorization: Bearer <LLM_GATEWAY_API_KEY>`)
  :8002                     redirect to :443
```

## Certificate

`HOMELAB_DOMAIN` must be this machine's Tailscale name (`<machine>.<tailnet>.ts.net`), with MagicDNS and HTTPS certificates turned on in the Tailscale admin console. Caddy gets the certificate from the host's Tailscale daemon through `/var/run/tailscale/tailscaled.sock`, at the first HTTPS connection. Devices need Tailscale to open the homelab.

Inside Docker, Caddy also answers to `HOMELAB_DOMAIN`, so oauth2-proxy and Grafana reach Keycloak's public address through Caddy with the same valid certificate.

## Session

- Cookie `__Host-homelab`: encrypted and signed with `OAUTH2_PROXY_COOKIE_SECRET`, `HttpOnly`, `Secure`, `SameSite=Lax`, valid 8 hours, shared by every port of `HOMELAB_DOMAIN` (browsers don't scope cookies by port), so one sign-in covers every tool. It holds no password.
- Disabling an account ends its Keycloak sessions at once, and its homelab session at the latest when the 8 hours are up. `make sessions-revoke` changes the cookie key, so every session ends immediately.
- Caddy deletes `Remote-User`, `X-Gateway-Secret` and the `X-Auth-Request-*` headers from every incoming request before adding its own, and drops the browser's cookies before proxying to anything but Grafana and Keycloak.

## Adding a route or a tool

- An API for homelab-ui: a `handle_path /api/<name>/*` block inside `handle /api/*` (it is then behind the sign-in check), limited to the paths the UI needs, and an `api` path for the service in homelab-ui.
- A web tool: a site `{$HOMELAB_DOMAIN}:<port> { import signed_in_tool <service>:<port> }`, the port in `compose.yml`, and remove the service's own `ports:`.

`make validate` runs `caddy validate`; apply an edited `Caddyfile` with `make recreate S=caddy`.
