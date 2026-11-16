# Keycloak (sign-in accounts)

Keeps the homelab's accounts and checks their passwords. Its login page is `https://<HOMELAB_DOMAIN>:8443/`, served by [Caddy](../caddy/README.md); every web tool uses this one sign-in (Grafana directly, the others through oauth2-proxy). Each account can change its password and see its sessions at `https://<HOMELAB_DOMAIN>:8443/realms/homelab/account`.

## Where accounts and passwords live

| What | Where | Form |
|---|---|---|
| Accounts | PostgreSQL, database `keycloak` (separate from the homelab database) | Username, email and name as plain rows |
| Passwords | Same database, one credential row per password | **Argon2id** hash (Keycloak's default since version 25: 5 iterations, about 7 MB of memory per hash), with a random salt stored next to the hash and the hashing settings beside them. The password itself is never stored |
| Failed sign-ins | Same database | 5 wrong passwords lock the account; the wait grows by 1 minute each time up to 15 minutes, and the count resets after 12 hours |
| Admin used by the `make user-*` commands | Kubernetes Secret `keycloak-admin` (created by `make secrets`, encrypted on disk) | Read inside the keycloak pod only; the web admin console is blocked at the gateway |

Password rules (realm `homelab`): at least 12 characters, not one of the last 5, and **valid 90 days** — after that the next sign-in asks for a new password before letting you in. Nobody can register from the web, and there is no "forgot password" link: accounts are managed only from the server's terminal.

## Managing accounts

```bash
make user-add ACCOUNT=toufik        # asks email, first and last name, then the password (hidden)
make user-password ACCOUNT=toufik   # set a new password
make user-disable ACCOUNT=toufik    # disable and end its Keycloak sessions
make user-enable ACCOUNT=toufik
make user-unlock ACCOUNT=toufik     # clear a lock after too many wrong passwords
make user-admin ACCOUNT=toufik      # give the 'admin' role
make users                          # list accounts
make sessions-revoke                # sign every account out now
```

Accounts can also be managed from homelab-ui's **People** pages by an account with the `admin` role: add a person (with a temporary password generated in the browser, shown once, which Keycloak makes them change at their first sign-in), give and take pages, disable, sign out, reset a password. Removing an account stays here, because it may also delete its Tasker data.

## Pages a person may open

Each homelab-ui page has a realm role, listed in [`pages.txt`](pages.txt): `agent:kitchen`, `agent:travel`, `app:tasker`, `page:metrics`… A person sees and opens only the pages whose roles they have; `admin` opens everything. The gateway checks the same roles ([Caddy](../caddy/README.md#session)).

```bash
make user-grant ACCOUNT=dora PAGE=agent:kitchen
make user-revoke ACCOUNT=dora PAGE=agent:kitchen
```

A new page is added to `pages.txt`, then `make apply R=keycloak` creates its role.

Passwords are piped to the keycloak pod on stdin, never put on a command line, so they don't appear in the server's process list or in shell history.

## Configuration

The realm is configuration as code: **`sync.sh`** runs in the `keycloak-sync` job after every install and upgrade of the keycloak release, once Keycloak is ready ([`values.yaml.gotmpl`](values.yaml.gotmpl)). It creates the `homelab` realm and the `admin` role if they are missing, and resets everything else to what the file says:

- the password policy, lockout and session settings above, registration and "forgot password" off;
- a role per page in `pages.txt`, and realm-management's `view-users`, `query-users` and `manage-users` inside the `admin` role (for homelab-ui's People pages);
- the user profile's `unmanagedAttributePolicy` set to `ENABLED`, so each person can save their homelab-ui theme on their account;
- the `oauth2-proxy` client (the sign-in check for homelab-ui and the tools) and the `grafana` client (Grafana's own Keycloak sign-in, with a `roles` claim so the `admin` role becomes Grafana Admin), with their secrets from the Kubernetes Secrets `oauth2-proxy` and `grafana-oidc`.

So a change to `sync.sh` is applied by the next `make apply R=keycloak`, and a client secret rotated with `make secret-rotate` by `make sync R=keycloak`. Accounts are never touched by the sync.

- The realm's sessions last 8 hours, matching the gateway's session cookie.
- `make verify` checks the realm: 90-day expiry, password rules, lockout, registration off, admin console blocked, Grafana client present.
