# Homelab Q&A

Short answers to everyday questions. Run commands on the server, in the `homelab-infra` folder. Each `make` command is followed by the raw command it runs. The step-by-step scenarios are in [devops_guide.md](devops_guide.md).

- [How do I deploy a dev image of the agent?](#how-do-i-deploy-a-dev-image-of-the-agent)
- [Where are the passwords stored?](#where-are-the-passwords-stored)
- [Where are the Secrets stored, and how do I read a password?](#where-are-the-secrets-stored-and-how-do-i-read-a-password)
- [How do I see the logs?](#how-do-i-see-the-logs)
- [How do I stop everything?](#how-do-i-stop-everything)
- [How do I restart everything?](#how-do-i-restart-everything)
- [How do I redeploy, reinstall or scale an app?](#how-do-i-redeploy-reinstall-or-scale-an-app)
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

**Which ones.** `make secrets-list` — raw: `./scripts/secrets.sh list` (every Secret and its keys, no values). The list the homelab creates is `SPECS` in [`scripts/secrets.sh`](scripts/secrets.sh):

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
| Restart its pods | `kubectl -n homelab rollout restart deploy/<release>` (`statefulset/<release>` for a database) | New pods, same settings |
| Reinstall it | `helm -n homelab uninstall <release>`, then `make apply R=<release>` | Everything is recreated; its volumes are kept and taken back, its data with them |
| Go back to the previous revision | `make rollback R=<release>` — raw: `helm -n homelab rollback <release>` | Then set the old version in `environments/versions.yaml`, or the next `make apply` upgrades again |
| See its revisions | `helm -n homelab history <release>` | |

**Scale it (change the number of pods):**
- For good: in its values file (`<group>/<release>/values.yaml.gotmpl`), add `replicas: 2`, commit, push; on the server `git pull`, `make apply R=<release>`.
- For a moment: `kubectl -n homelab scale deploy/<release> --replicas=2`; back with `--replicas=1`. git doesn't know about it, so set it back yourself.
- `replicas: 0` stops a release without uninstalling it.
- More than one pod works only for releases without a volume or a published port: homelab-ui, postgrest, oauth2-proxy, kafka-ui. The others (databases, Kafka, Caddy, the agent, the LLM…) run one pod.

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
