# Homelab Q&A

Short answers to everyday questions. Run commands on the server, in the `homelab-infra` folder. Each `make` command is followed by the raw command it runs. The step-by-step scenarios are in [devops_guide.md](devops_guide.md).

- [How do I deploy a dev image of the agent?](#how-do-i-deploy-a-dev-image-of-the-agent)
- [Where are the passwords stored?](#where-are-the-passwords-stored)
- [Where are the Secrets stored, and how do I read a password?](#where-are-the-secrets-stored-and-how-do-i-read-a-password)
- [How do I see every password on the server?](#how-do-i-see-every-password-on-the-server)
- [Where are the usernames set?](#where-are-the-usernames-set)
- [How do I connect pgAdmin 4 to PostgreSQL?](#how-do-i-connect-pgadmin-4-to-postgresql)
- [Which PostgreSQL user should my app use?](#which-postgresql-user-should-my-app-use)
- [How do I connect to MongoDB?](#how-do-i-connect-to-mongodb)
- [How do I see the logs?](#how-do-i-see-the-logs)
- [How do I stop everything?](#how-do-i-stop-everything)
- [How do I restart everything?](#how-do-i-restart-everything)
- [How do I redeploy, reinstall or scale an app?](#how-do-i-redeploy-reinstall-or-scale-an-app)
- [I rebuilt a release under the same tag: how does the server pick it up?](#i-rebuilt-a-release-under-the-same-tag-how-does-the-server-pick-it-up)
- [How do I change a pod's settings and redeploy it?](#how-do-i-change-a-pods-settings-and-redeploy-it)

---

## How do I deploy a dev image of the agent?

Every push to `develop` of agent-runtime (or agent-toolbox) publishes the image `toufik142/agent-runtime:dev-<commit sha>`. The homelab normally runs the version tagged `vX.Y.Z`; you can point it at a dev image instead.

1. Find the commit's full sha: the green **PUBLISH** run in the repository's **Actions**, or on your Mac `git rev-parse origin/develop`.
2. Pick how long it should stay:
   - **Just to try it** (undone by the next `make apply`):
     ```bash
     helmfile -l name=agent-runtime apply --set image.tag=dev-<sha>
     ```
   - **Until you remove it**: on your Mac, in `apps/agent-runtime/values.yaml.gotmpl`, add
     ```yaml
     image:
       tag: dev-<sha>
     ```
     commit, push; on the server `git pull`, `make apply R=agent-runtime` — raw: `helmfile -l name=agent-runtime apply`.
3. Check: `kubectl -n homelab get deploy agent-runtime -o jsonpath='{.spec.template.spec.containers[0].image}'; echo` → `toufik142/agent-runtime:dev-<sha>`; `make logs R=agent-runtime`.
4. Back to the release: remove the `image:` lines (or just `make apply R=agent-runtime` for the "just to try it" way).

- Use `dev-<sha>`, not `dev`: the server keeps an image it already has, so `:dev` would not pick up a newer push.
- Only the image changes. The chart, with the repository's `devops/helm/values.yml` (env variables, Secrets, probes), stays the one of the release. A dev build that needs a new env variable needs it in `apps/agent-runtime/values.yaml.gotmpl` too, under `env:`.
- Same for agent-toolbox: `name=agent-toolbox`, `apps/agent-toolbox/values.yaml.gotmpl`, image `toufik142/agent-toolbox:dev-<sha>`.

## Where are the passwords stored?

| Password | Stored | Can I read it? |
|---|---|---|
| Sign-in accounts (yours, other people's) | Keycloak, in PostgreSQL's `keycloak` database, as Argon2id hashes | No, only replace it: `make user-password ACCOUNT=<name>` — raw: `./scripts/users.sh password <name>` |
| Services' passwords and keys (database roles, Keycloak and Grafana admins, MongoDB root, gateway keys, the agent's LLM key) | Kubernetes Secrets in namespace `homelab` ([next question](#where-are-the-secrets-stored-and-how-do-i-read-a-password)) | Yes, with kubectl |
| PostgreSQL's `postgres` superuser and the `homelab` database owner | Secrets `postgres-superuser` and `postgres-app`, created by the PostgreSQL operator | Yes, with kubectl |

Nothing is in git: not the passwords, not `environments/local.yaml` (only the server's name and address).

## Where are the Secrets stored, and how do I read a password?

**Where.** Kubernetes Secrets in namespace `homelab`. k3s keeps them in its database, `/var/lib/rancher/k3s/server/db/state.db`, encrypted; the key is `/var/lib/rancher/k3s/server/cred/encryption-config.json` (root only). Anyone in the group `k3s-admin` can read them through kubectl.

**Which ones.** `make secrets-list` — raw: `./scripts/secrets.sh list` (every Secret and its keys, no values). With their values: `make show-secrets` — raw: `./scripts/secrets.sh show`. The list the homelab creates is `SPECS` in [`scripts/secrets.sh`](scripts/secrets.sh):

| Secret | Keys | Used by |
|---|---|---|
| `keycloak-admin` | `username`, `password` | Keycloak's admin (the `make user-*` commands use it) |
| `grafana-admin` | `username`, `password` | Grafana's local admin |
| `mongodb` | `username`, `password` | MongoDB's root |
| `pg-role-postgrest`, `pg-role-keycloak` | `username`, `password` | PostgreSQL roles |
| `oauth2-proxy` | `client-secret`, `cookie-secret` | the sign-in |
| `grafana-oidc` | `client-secret` | Grafana's sign-in with Keycloak |
| `tasker-gateway` | `secret` | Caddy → PostgREST |
| `llm-gateway` | `api-key` | the LLM API on `:8090` |
| `agent-runtime` | `llm-api-key` | the agent's LLM provider (typed by you) |
| `mongodb-mcp` | `username`, `password` | MongoDB's MCP server (user `mcp`) |
| `pg-role-mcp` | `username`, `password` | PostgreSQL's MCP server (role `mcp`) |
| `grafana-mcp` | `token` | Grafana's MCP server: a Grafana service-account token (typed by you) |

**Read one value:**
```bash
kubectl -n homelab get secret grafana-admin -o jsonpath='{.data.password}' | base64 -d; echo
```
Replace `grafana-admin` and `password` with the Secret and key.

**Read every key of a Secret:**
```bash
kubectl -n homelab get secret mongodb -o json | jq -r '.data | map_values(@base64d)'
```

- The value is printed in your terminal: copy it where it's needed, never into git or a chat.
- Change one: `make secret-rotate SECRET=<secret> KEY=<key>` (generated) or `make secret-set SECRET=<secret> KEY=<key>` (typed) — raw: `./scripts/secrets.sh rotate|set <secret> <key>`. The pods using it restart by themselves.

## How do I see every password on the server?

`make show-secrets` — raw: `./scripts/secrets.sh show`

It prints one line per value, `<secret>/<key>: <value>`: every Secret `make secrets` creates (MongoDB, Keycloak and Grafana admins, PostgreSQL roles, sign-in and gateway keys, the LLM key) and PostgreSQL's `postgres-superuser` and `postgres-app` (with their connection strings).

- The sign-in accounts' passwords aren't there: Keycloak keeps only their hashes. Replace one with `make user-password ACCOUNT=<name>` — raw: `./scripts/users.sh password <name>`.
- The values are in your terminal: clear it after (`clear`), and never paste them into git or a chat.
- One Secret only: [Read every key of a Secret](#where-are-the-secrets-stored-and-how-do-i-read-a-password).

## Where are the usernames set?

| User | Set in | Created | Password in |
|---|---|---|---|
| MongoDB `root`, Keycloak `admin`, Grafana `admin` | `SPECS` in [`scripts/secrets.sh`](scripts/secrets.sh) (`username=<name>`) | by the service, at its first start on an empty volume | Secrets `mongodb`, `keycloak-admin`, `grafana-admin` |
| PostgreSQL roles `postgrest`, `keycloak`, `mcp` | `SPECS` in `scripts/secrets.sh` and `roles:` in [`repository/postgres/values.yaml.gotmpl`](repository/postgres/values.yaml.gotmpl) (the two names must match) | by the PostgreSQL operator, kept as declared | Secrets `pg-role-postgrest`, `pg-role-keycloak`, `pg-role-mcp` |
| MongoDB user `mcp` (MongoDB's MCP server) | `SPECS` in `scripts/secrets.sh` (`mongodb-mcp`) | by the `mongodb` release's job, at every deploy (its role follows `mcp.mongodb.write`) | Secret `mongodb-mcp` |
| PostgreSQL `postgres` (superuser) | PostgreSQL itself | at the cluster's first start | Secret `postgres-superuser`, written by the operator |
| PostgreSQL `homelab` (owner of the `homelab` database) | `owner: homelab` in the pg-cluster chart (`kube-charts/charts/pg-cluster/values.yaml`); `repository/postgres/values.yaml.gotmpl` doesn't override it | at the cluster's first start only | Secret `postgres-app`, written by the operator |
| Sign-in accounts | you: `make user-add ACCOUNT=<name>` — raw: `./scripts/users.sh add <name>` | in Keycloak, by that command | Keycloak (hashes only) |

- Editing a username afterwards changes nothing: `make secrets` keeps a Secret's stored values, and the services and the operator read them at their first start only.
- Who owns what in PostgreSQL: `homelab` owns the database `homelab` but none of its tables; the schema `tasker` and its tables belong to `postgres` (the migrations run as `postgres`); `keycloak` owns the database `keycloak` and its tables. Nothing logs in as `homelab`.

## How do I connect pgAdmin 4 to PostgreSQL?

Use `postgres`: it sees every table. PostgreSQL isn't open to the tailnet, so pgAdmin goes through SSH to the server.

1. **Get the password.** On the server: `make show-secrets` — raw: `./scripts/secrets.sh show`. The line `postgres-superuser/password` is it.
2. **Get PostgreSQL's address inside the cluster.** On the server:
   ```bash
   kubectl -n homelab get svc postgres-rw -o jsonpath='{.spec.clusterIP}'; echo
   ```
   It prints `10.43.x.x`. It stays the same unless the `postgres` release is removed.
3. **In pgAdmin 4: Object Explorer → right-click Servers → Register → Server.** General tab: a name, e.g. `homelab`. Then the **SSH Tunnel** tab: Use SSH tunneling on, Tunnel host `<HOMELAB_DOMAIN>`, port `22`, Username your user on the server, Authentication Identity file (your SSH key).
4. **Connection tab.** Host name the `10.43.x.x` address, Port `5432`, Maintenance database `homelab`, Username `postgres`, Password from step 1, Save password on.
5. **Save.** pgAdmin lists the databases `homelab` and `keycloak`; the Tasker tables are in homelab → Schemas → tasker → Tables.

- `postgres` can change and drop anything: use it to look and for admin work, never in an app.
- pgAdmin says `connection timed out`: Tailscale isn't on on your Mac, or the address changed (step 2 again).

## Which PostgreSQL user should my app use?

Its own: one user per app, which can only touch its own schema and what you grant it. Never `postgres` (everything) or `homelab` (owns the whole database). For an app `myapi`:

1. **Add its Secret to `SPECS` in [`scripts/secrets.sh`](scripts/secrets.sh)**, and `pg-role-myapi/password` to `ROTATABLE`:
   ```
   "pg-role-myapi|kubernetes.io/basic-auth|username=myapi password:24"
   ```
   Then `make secrets` — raw: `./scripts/secrets.sh`. Secret `pg-role-myapi` is created with a generated password.
2. **Declare the user under `roles:` in [`repository/postgres/values.yaml.gotmpl`](repository/postgres/values.yaml.gotmpl):**
   ```yaml
   - name: myapi
     login: true
     passwordSecret: { name: pg-role-myapi }
   ```
   Then `make apply R=postgres` — raw: `helmfile -l name=postgres apply`. The operator creates `myapi` with that password.
3. **Give it its schema in a migration.** `make migration-new NAME=create_myapi_schema`, write in the new file:
   ```sql
   -- migrate:up
   CREATE SCHEMA myapi AUTHORIZATION myapi;

   -- migrate:down
   DROP SCHEMA myapi CASCADE;
   ```
   Then `make migrate` — raw: `helmfile -l name=db-migrate sync`. `myapi` reads and writes everything in schema `myapi`, nothing else. To let it use other tables, grant them in the same migration, e.g. `GRANT SELECT ON tasker.workflows TO myapi;`.
4. **Point the app at it** in its repository's `devops/helm/values.yml`:
   ```yaml
   env:
     DB_HOST: postgres-rw
     DB_PORT: "5432"
     DB_NAME: homelab
   secretEnv:
     DB_USER: { secret: pg-role-myapi, key: username }
     DB_PASSWORD: { secret: pg-role-myapi, key: password }
   ```
   Use the env variable names your app reads. Release the app; it connects as `myapi`.

| Who | Username | Password in | Can |
|---|---|---|---|
| You, in pgAdmin | `postgres` | `postgres-superuser` | everything |
| Each app or API | its own (`myapi`) | `pg-role-myapi` | its schema and what you grant it |
| PostgREST (Tasker) | `postgrest` | `pg-role-postgrest` | the Tasker tables, only the signed-in user's rows |
| Keycloak | `keycloak` | `pg-role-keycloak` | the database `keycloak` |
| `homelab` | `homelab` | `postgres-app` | owns the database `homelab`; unused |

## How do I connect to MongoDB?

MongoDB answers on the server's port 27017, from the tailnet only. The account is MongoDB's root: username `root`, password in Secret `mongodb`.

**From Compass, on your Mac**

1. **Copy the password to your Mac's clipboard.** On your Mac:
   ```bash
   ssh <user>@<HOMELAB_DOMAIN> 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n homelab get secret mongodb -o jsonpath={.data.password} | base64 -d' | pbcopy
   ```
   Nothing is printed; the password is in the clipboard.
2. **In Compass, click Add new connection** and set the URI to `mongodb://<HOMELAB_DOMAIN>:27017/?authSource=admin`, without the password.
3. **Open Advanced Connection Options → Authentication → Username/Password.** Username `root`, paste the password, Authentication Database `admin`.
4. **Save & Connect.** Compass lists the databases (`agent_runtime` is the agent's). It keeps the password on your Mac, so you do this once.

**From mongosh, on your Mac**

```bash
mongosh "mongodb://root@<HOMELAB_DOMAIN>:27017/?authSource=admin"
```
It asks for the password: paste it (step 1 above).

**From the server**

`make mongosh` — raw: `kubectl -n homelab exec -it mongodb-0 -- sh -c 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'`. No password to type.

**From an app in the cluster**

Host `mongodb`, port `27017`, authentication database `admin`, the user and password from Secret `mongodb`, as agent-runtime does in its `devops/helm/values.yml`:
```yaml
env:
  DB_MONGO_CHECKPOINT_HOST: mongodb
  DB_MONGO_CHECKPOINT_PORT: "27017"
secretEnv:
  DB_MONGO_CHECKPOINT_USERNAME: { secret: mongodb, key: username }
  DB_MONGO_CHECKPOINT_PASSWORD: { secret: mongodb, key: password }
```
Your app uses the env variable names it reads.

- `connection timed out`: Tailscale isn't on on your Mac, or MongoDB isn't running (`make status` on the server).
- `Authentication failed`: the password was rotated or mistyped; copy it again (step 1).
- A connection string with the password in it (`mongodb://root:<password>@…`) stays out of git and chats.

## How do I see the logs?

| To see | Command |
|---|---|
| One release, live | `make logs R=<release>` — raw: `kubectl -n homelab logs -f --tail=200 -l app.kubernetes.io/instance=<release> --all-containers --prefix` |
| PostgreSQL | `make logs R=postgres` — raw: `kubectl -n homelab logs -f --tail=200 -l cnpg.io/cluster=postgres --all-containers --prefix` |
| More history | `make logs R=<release> TAIL=2000` |
| Why a pod crashed (the run before the restart) | `kubectl -n homelab logs deploy/<release> --previous` (`statefulset/<release>` for mongodb, kafka, prometheus, loki, tempo) |
| A job (migrations, realm sync, a backup) | `kubectl -n homelab logs job/<job>`; the jobs: `kubectl -n homelab get jobs` |
| Why a pod doesn't start | `make events` — raw: `kubectl -n homelab get events --sort-by=.lastTimestamp \| tail -n 40` |
| Everything, searchable, kept 30 days | Grafana `https://<HOMELAB_DOMAIN>:3000/explore` → **Loki** → `{service_name="<release>"}` |

- In Grafana, the label browser lists every `service_name`. agent-runtime and agent-toolbox send their logs over OTLP, under their own service names; a log line with a `trace_id` links to its trace in Tempo.

## How do I stop everything?

**The whole cluster** (every pod, until you start it again; data is kept):
```bash
sudo systemctl stop k3s
sudo /usr/local/bin/k3s-killall.sh
```
- `systemctl stop k3s` alone leaves the pods running; `k3s-killall.sh` stops them.
- k3s starts again at the next boot. To keep it off: `sudo systemctl disable k3s`.
- Check: `sudo crictl ps` → nothing, or `crictl` can't connect.

**Only the homelab** (Kubernetes keeps running):
```bash
kubectl -n homelab annotate clusters.postgresql.cnpg.io postgres cnpg.io/hibernation=on --overwrite
kubectl -n homelab scale deploy,statefulset --all --replicas=0
```
- PostgreSQL is run by its operator, so it is stopped by hibernation, not by scale.
- The 03:00 backups fail while it is stopped.
- Check: `make status` → `No resources found` (wait a minute for PostgreSQL).

**Only the LLM** (frees 26 GiB): `make llm-down` — raw: `kubectl -n homelab scale deploy/llm --replicas=0`.

## How do I restart everything?

**After stopping the whole cluster:**
```bash
sudo systemctl enable --now k3s
```
Every pod comes back by itself in a few minutes; `make status`, then `make verify`.

**After stopping only the homelab:**
```bash
kubectl -n homelab annotate clusters.postgresql.cnpg.io postgres cnpg.io/hibernation=off --overwrite
kubectl -n homelab scale deploy,statefulset --all --replicas=1
```
Pods that need PostgreSQL restart until it is ready; after a few minutes `make status` shows them all `Running`, then `make verify`. The LLM: `make llm-up`.

**Restart every running pod** (new pods, same settings):
```bash
kubectl -n homelab rollout restart deploy,statefulset
kubectl -n homelab delete pod -l cnpg.io/cluster=postgres      # PostgreSQL: its operator starts a new one
```

**Restart the server:** `sudo reboot`. Everything comes back on its own; `make verify` after.

- `sudo systemctl restart k3s` restarts Kubernetes but not the pods.

## How do I redeploy, reinstall or scale an app?

| To | Command | What happens |
|---|---|---|
| Deploy what changed | `make apply R=<release>` — raw: `helmfile -l name=<release> apply` | Only if its files or version changed |
| Redeploy even without a change | `make sync R=<release>` — raw: `helmfile -l name=<release> sync` | Re-applies it and re-runs its jobs; brings back what was deleted by hand; pods restart only if something changed |
| Restart its pods | `make restart R=<release>` — raw: `kubectl -n homelab rollout restart deploy/<release>` (`statefulset/<release>` for a database), then `kubectl -n homelab rollout status …` | New pods, same settings; waits until they're ready |
| Reinstall it | `helm -n homelab uninstall <release>`, then `make apply R=<release>` | Everything is recreated; its volumes are kept and taken back, its data with them |
| Go back to the previous revision | `make rollback R=<release>` — raw: `helm -n homelab rollback <release>` | Then set the old version in `environments/versions.yaml`, or the next `make apply` upgrades again |
| See its revisions | `helm -n homelab history <release>` | |

**Scale it (change the number of pods):**
- Your apps (homelab-ui, agent-runtime, agent-toolbox): `replicas:` in the app repository's `devops/helm/values.yml`, shipped with its next tag (`vX.Y.Z`, then `apps.<app>` in `environments/versions.yaml`, `make apply R=<app>`). To change it before the next tag, set `replicas:` in `apps/<app>/values.yaml.gotmpl`: it wins over the app's own file.
- The other releases, for good: in their values file (`<group>/<release>/values.yaml.gotmpl`), add `replicas: 2`, commit, push; on the server `git pull`, `make apply R=<release>`.
- For a moment: `kubectl -n homelab scale deploy/<release> --replicas=2`; back with `--replicas=1`. git doesn't know about it, so set it back yourself.
- `replicas: 0` stops a release without uninstalling it.
- More than one pod works only for releases without a volume or a published port: homelab-ui, postgrest, oauth2-proxy, kafka-ui. The others (databases, Kafka, Caddy, the agent, the LLM…) run one pod.

## I rebuilt a release under the same tag: how does the server pick it up?

GitHub has the new build under the old version (`1.1.2` here), but the server keeps the old one in two caches: helmfile's chart cache (`Skipping refresh for chart … shared cache` in `make apply`), and k3s's images (pods pull an image only if it isn't there yet, `imagePullPolicy: IfNotPresent`). On the server, in `homelab-infra`:

1. **Forget the cached chart:** `helmfile cache cleanup`. The next deploy downloads the chart again.
2. **Remove the cached image:** `sudo k3s crictl rmi docker.io/toufik142/homelab-ui:1.1.2`. It prints `Deleted: …`; if the image is in use, do step 4, then this step and step 4 again.
3. **Deploy the downloaded chart:** `make sync R=homelab-ui` — raw: `helmfile -l name=homelab-ui sync`. It ends with `UPDATED RELEASES: homelab-ui`.
4. **Replace the pods, so they pull the image:** `make restart R=homelab-ui` — raw: `kubectl -n homelab rollout restart deploy/homelab-ui`. `make ps` shows a new homelab-ui pod.
5. **Check the pod runs the new build:**
   ```bash
   kubectl -n homelab get pod -l app.kubernetes.io/name=homelab-ui -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'; echo
   ```
   The `sha256:…` digest matches the one of tag `1.1.2` on Docker Hub, or in the GitHub Actions PUBLISH log.
6. **Reload the page with Cmd+Shift+R**, so the browser drops the old UI.

- Only the code changed: steps 2, 4, 5 are enough. The chart changed too (`devops/helm/values.yml`): all of them.
- Same for agent-runtime and agent-toolbox: their release name and image (`toufik142/agent-runtime`, `toufik142/agent-toolbox`).
- Next time, tag a new version instead (`v1.1.3`, then `apps.homelabUi: 1.1.3` in `environments/versions.yaml`, `make apply R=homelab-ui`): a new number skips both caches, and `make rollback` still knows the previous build.

## How do I change a pod's settings and redeploy it?

A pod's settings are its release's values. Change the file, never the pod: a change made with `kubectl edit` is lost at the next deploy.

1. On your Mac, edit the release's values file, `<group>/<release>/values.yaml.gotmpl`. For example `apps/agent-runtime/values.yaml.gotmpl`:
   ```yaml
   env:
     LOG_LEVEL: DEBUG
   resources:
     limits: { memory: 1Gi }
   ```
2. Commit, push.
3. On the server: `git pull`.
4. `make diff R=<release>` — raw: `helmfile -l name=<release> diff` → shows exactly what changes.
5. `make apply R=<release>` — raw: `helmfile -l name=<release> apply` → the pod restarts with the new settings.
6. Check: `make status`, `make logs R=<release>`.

- What you can set: kube-charts' app chart, `charts/app/values.yaml` (env, secretEnv, resources, probes, ports, persistence, configFiles, replicas…).
- Maps (`env`, `resources`) merge with what the chart already has; lists (`args`, `ports`) replace the whole list.
- A config file next to the values (`Caddyfile`, `prometheus.yml`, `llm/llm/config.yml`…) works the same way: edit it, then steps 2–6.
- For your own apps, a setting that belongs to the app itself goes in its repository's `devops/helm/values.yml` and ships with its next tag; `apps/<app>/values.yaml.gotmpl` is for this server's choices.
