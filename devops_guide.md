# Homelab DevOps guide

Scenarios, as steps. Each `make` command is followed by the raw command it runs.

- Run commands on the server, in the `homelab-infra` folder, unless a step says otherwise.
- Before a raw command, load `.env` once per terminal: `set -a; . ./.env; set +a`
- `<HOMELAB_DOMAIN>` = the value in `.env` (`<machine>.<tailnet>.ts.net`). `<name>` = an account name. `<tailscale-ip>` = `tailscale ip -4`.

**Server**
[Prepare the server](#prepare-the-server) ·
[Protect it against freezes](#protect-the-server-against-freezes) ·
[Battery and power cuts](#battery-and-power-cuts) ·
[Get notified when the server is offline](#get-notified-when-the-server-is-offline) ·
[Measure the internet speed](#measure-the-internet-speed) ·
[Test the server](#test-the-server)

**Homelab**
[First start](#first-start) ·
[Start, stop, restart](#start-stop-restart) ·
[Check the stack](#check-the-stack) ·
[Update the stack](#update-the-stack) ·
[Accounts](#accounts) ·
[Secrets and passwords](#secrets-and-passwords) ·
[Database shells](#database-shells) ·
[Database migrations](#database-migrations) ·
[Backups and restores](#backups-and-restores) ·
[Gateway](#gateway) ·
[LLM and agent](#llm-and-agent) ·
[Kafka](#kafka) ·
[Observability](#observability) ·
[Publish and deploy homelab-ui](#publish-and-deploy-homelab-ui) ·
[Add a service](#add-a-service) ·
[Troubleshooting](#troubleshooting) ·
[Reset the homelab](#reset-the-homelab) ·
[Undo the server setup](#undo-the-server-setup) ·
[Every make command](#every-make-command)

---

## Prepare the server

Turn an Ubuntu laptop into an always-on server. Do it on the laptop itself (keyboard and screen), plugged into power.

### 1. Update and install the tools

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y curl jq lm-sensors openssh-server
```

### 2. Install Docker

1. Install Docker Engine and the Compose plugin: [docs.docker.com/engine/install/ubuntu](https://docs.docker.com/engine/install/ubuntu/).
2. Use Docker without `sudo`, then log out and back in:
   ```bash
   sudo usermod -aG docker "$USER"
   ```
3. Check: `docker compose version` → 2.20 or later.

### 3. Install and connect Tailscale

1. Install and log in (open the link it prints):
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   ```
2. In the [Tailscale admin console](https://login.tailscale.com/admin/machines): **Machines** → this laptop → **⋯ → Disable key expiry**.
3. In **DNS**: turn on **MagicDNS** and **HTTPS Certificates**.
4. Check:
   ```bash
   tailscale status                                # first line: this laptop
   tailscale ip -4                                 # note it: <tailscale-ip>
   tailscale status --json | jq -r .Self.DNSName   # note it without the final dot: <HOMELAB_DOMAIN>
   ```

### 4. Never sleep

1. ```bash
   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
   ```
2. Check: `systemctl status sleep.target` → `Loaded: masked`.

### 5. Keep running with the lid closed

1. ```bash
   sudo mkdir -p /etc/systemd/logind.conf.d
   sudo tee /etc/systemd/logind.conf.d/server.conf >/dev/null <<'EOF'
   [Login]
   HandleLidSwitch=ignore
   HandleLidSwitchExternalPower=ignore
   HandleLidSwitchDocked=ignore
   HandleSuspendKey=ignore
   HandleHibernateKey=ignore
   IdleAction=ignore
   EOF
   ```
2. Put the laptop on a hard surface with the vents clear.

### 6. Boot without the desktop

1. ```bash
   sudo systemctl set-default multi-user.target
   sudo reboot
   ```
2. Log in at the text prompt.
3. Check: `systemctl get-default` → `multi-user.target`.
4. Close the lid for one minute, open it: `uptime` shows no sleep.

### 7. Ethernet as the main network

1. Plug the cable into the router, then note the `ethernet` row's **CONNECTION** name:
   ```bash
   nmcli device status
   ```
2. Make it reconnect forever and win over Wi-Fi (replace `Wired connection 1`):
   ```bash
   sudo nmcli connection modify "Wired connection 1" \
     connection.autoconnect yes \
     connection.autoconnect-priority 100 \
     connection.autoconnect-retries 0 \
     ipv4.route-metric 100
   ```
3. On the router's admin page: add a **DHCP reservation** for the laptop's current IP.
4. Only with a USB Ethernet adapter:
   ```bash
   sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&usbcore.autosuspend=-1 /' /etc/default/grub
   sudo update-grub
   sudo reboot
   ```
5. Check:
   ```bash
   nmcli device status          # ethernet: connected
   ip route show default        # first line: the Ethernet device
   ping -c 3 1.1.1.1
   ```

### 8. Wi-Fi as the fallback network

1. Connect:
   ```bash
   nmcli device wifi list
   sudo nmcli device wifi connect "YOUR_WIFI_NAME" password "YOUR_WIFI_PASSWORD"
   ```
2. Make it the backup and turn off its power saving:
   ```bash
   sudo nmcli connection modify "YOUR_WIFI_NAME" \
     connection.autoconnect yes \
     connection.autoconnect-priority 10 \
     connection.autoconnect-retries 0 \
     ipv4.route-metric 600 \
     802-11-wireless.powersave 2
   sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf >/dev/null <<'EOF'
   [connection]
   wifi.powersave = 2
   EOF
   sudo systemctl restart NetworkManager
   ```
3. Check: unplug the Ethernet cable, wait 30 s, run `tailscale status` from another device → the laptop is online.

### 9. Start only Tailscale at boot

1. Tailscale starts at boot and always restarts:
   ```bash
   sudo systemctl enable tailscaled
   sudo mkdir -p /etc/systemd/system/tailscaled.service.d
   sudo tee /etc/systemd/system/tailscaled.service.d/restart.conf >/dev/null <<'EOF'
   [Unit]
   StartLimitIntervalSec=0

   [Service]
   Restart=always
   RestartSec=5
   EOF
   sudo systemctl daemon-reload
   ```
2. Docker starts on the first `docker` command instead of at boot:
   ```bash
   sudo systemctl disable docker.service containerd.service
   sudo systemctl enable docker.socket
   ```
3. SSH on:
   ```bash
   sudo systemctl enable ssh
   ```
4. Turn off what a server doesn't need (if listed by `systemctl list-unit-files --type=service --state=enabled`):
   ```bash
   sudo systemctl disable --now cups.service cups-browsed.service bluetooth.service ModemManager.service
   ```
5. Reboot, then check:
   ```bash
   systemctl is-active tailscaled     # active
   systemctl is-active docker         # inactive
   ```
6. From another tailnet device: `ssh <user>@<tailscale-ip>`.

## Protect the server against freezes

### 1. Reboot on a kernel crash or freeze

```bash
sudo tee /etc/sysctl.d/99-server-autoreboot.conf >/dev/null <<'EOF'
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.softlockup_panic = 1
kernel.nmi_watchdog = 1
kernel.hardlockup_panic = 1
kernel.hung_task_timeout_secs = 600
kernel.hung_task_panic = 1
EOF
sudo sysctl --system
sysctl kernel.panic kernel.softlockup_panic kernel.hung_task_panic    # check
```

### 2. Watchdog: reboot when everything is frozen

1. Load the hardware watchdog (Intel: `iTCO_wdt`, AMD: `sp5100_tco`):
   ```bash
   sudo modprobe iTCO_wdt
   sudo wdctl
   ```
2. If `wdctl` shows a device, keep that driver:
   ```bash
   echo iTCO_wdt | sudo tee /etc/modules-load.d/watchdog.conf
   ```
   If it says `No such file or directory`, use the software one:
   ```bash
   echo softdog | sudo tee /etc/modules-load.d/watchdog.conf
   sudo modprobe softdog
   sudo wdctl        # shows "softdog"
   ```
3. Let systemd feed it:
   ```bash
   sudo mkdir -p /etc/systemd/system.conf.d
   sudo tee /etc/systemd/system.conf.d/watchdog.conf >/dev/null <<'EOF'
   [Manager]
   RuntimeWatchdogSec=30s
   RebootWatchdogSec=10min
   EOF
   sudo systemctl daemon-reexec
   ```
4. Check:
   ```bash
   sudo wdctl | grep -i timeout
   systemctl show -p RuntimeWatchdogUSec
   ```

### 3. Tailscale watchdog: restart Tailscale, reboot as a last resort

Every 2 minutes: restarts Tailscale after ~4 minutes down; reboots after ~16 minutes, only if the internet works and the laptop has been up 30 minutes.

1. Create the script:
   ```bash
   sudo tee /usr/local/bin/tailscale-watchdog.sh >/dev/null <<'EOF'
   #!/usr/bin/env bash
   # Checks Tailscale health. Run every 2 minutes by tailscale-watchdog.timer.
   set -u

   FAIL_FILE=/run/tailscale-watchdog.failures   # reset at every boot
   RESTART_AFTER=2                              # failures before restarting tailscaled (~4 min)
   REBOOT_AFTER=8                               # failures before rebooting (~16 min)
   MIN_UPTIME=1800                              # never reboot in the first 30 minutes

   log() { logger -t tailscale-watchdog "$*"; }

   state=$(tailscale status --json 2>/dev/null \
     | python3 -c 'import sys,json; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null)

   if [ "$state" = "Running" ]; then
     rm -f "$FAIL_FILE"
     exit 0
   fi

   fails=$(( $(cat "$FAIL_FILE" 2>/dev/null || echo 0) + 1 ))
   echo "$fails" > "$FAIL_FILE"
   log "Tailscale not running (state='${state:-unknown}'), failure $fails"

   if [ "$state" = "NeedsLogin" ]; then
     log "Tailscale needs a manual login: run 'sudo tailscale up'. Not restarting."
     exit 0
   fi

   if [ "$fails" -eq "$RESTART_AFTER" ]; then
     log "Restarting tailscaled"
     systemctl restart tailscaled
   fi

   if [ "$fails" -ge "$REBOOT_AFTER" ]; then
     uptime_s=$(cut -d. -f1 /proc/uptime)
     if [ "$uptime_s" -lt "$MIN_UPTIME" ]; then
       log "Not rebooting: uptime ${uptime_s}s is below ${MIN_UPTIME}s"
     elif ! ping -c 3 -W 3 1.1.1.1 >/dev/null 2>&1 && ! ping -c 3 -W 3 8.8.8.8 >/dev/null 2>&1; then
       log "Not rebooting: internet is down (router or ISP problem)"
     else
       log "Internet works but Tailscale is still down: rebooting"
       systemctl reboot
     fi
   fi
   EOF
   sudo chmod +x /usr/local/bin/tailscale-watchdog.sh
   ```
2. Run it every 2 minutes:
   ```bash
   sudo tee /etc/systemd/system/tailscale-watchdog.service >/dev/null <<'EOF'
   [Unit]
   Description=Check Tailscale health and repair it
   After=network-online.target tailscaled.service

   [Service]
   Type=oneshot
   ExecStart=/usr/local/bin/tailscale-watchdog.sh
   EOF

   sudo tee /etc/systemd/system/tailscale-watchdog.timer >/dev/null <<'EOF'
   [Unit]
   Description=Run the Tailscale watchdog every 2 minutes

   [Timer]
   OnBootSec=5min
   OnUnitActiveSec=2min

   [Install]
   WantedBy=timers.target
   EOF

   sudo systemctl daemon-reload
   sudo systemctl enable --now tailscale-watchdog.timer
   ```
3. Check:
   ```bash
   systemctl list-timers tailscale-watchdog.timer
   sudo /usr/local/bin/tailscale-watchdog.sh && echo "script OK"
   ```

### 4. Keep logs across reboots

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
```

### 5. Automatic security updates, rebooting at 04:00

```bash
sudo apt install -y unattended-upgrades
sudo tee /etc/apt/apt.conf.d/52server-reboot >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
```

## Battery and power cuts

### 1. Limit the charge to 80%

1. Check support: `ls /sys/class/power_supply/BAT*/charge_control_end_threshold`
2. If the file exists:
   ```bash
   sudo tee /etc/systemd/system/battery-limit.service >/dev/null <<'EOF'
   [Unit]
   Description=Limit battery charge to 80%

   [Service]
   Type=oneshot
   ExecStart=/bin/sh -c 'for b in /sys/class/power_supply/BAT*; do echo 80 > "$b/charge_control_end_threshold"; done'

   [Install]
   WantedBy=multi-user.target
   EOF
   sudo systemctl enable --now battery-limit.service
   cat /sys/class/power_supply/BAT*/charge_control_end_threshold    # 80
   ```
3. If it doesn't: set the limit in the BIOS (next step).

### 2. BIOS settings

1. Reboot into the BIOS (**F2**, **F10**, **F12** or **Del** at startup).
2. Set, where they exist:
   - **Power on AC** / **AC Power Recovery** → Enabled
   - **Battery charge limit** → 80%
   - **Wake on LAN** → Enabled (optional)
3. Back in Ubuntu: `sensors` → CPU below ~85 °C under load.

## Get notified when the server is offline

1. On [healthchecks.io](https://healthchecks.io): **Add Check**, Period 5 minutes, Grace 10 minutes. Copy the ping URL.
2. In **Integrations**: add email or the mobile app.
3. On the server (replace `YOUR_PING_URL`):
   ```bash
   sudo tee /etc/systemd/system/heartbeat.service >/dev/null <<'EOF'
   [Unit]
   Description=Send a heartbeat to healthchecks.io
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   ExecStart=/usr/bin/curl -fsS -m 10 --retry 3 -o /dev/null YOUR_PING_URL
   EOF

   sudo tee /etc/systemd/system/heartbeat.timer >/dev/null <<'EOF'
   [Unit]
   Description=Heartbeat every 5 minutes

   [Timer]
   OnBootSec=2min
   OnUnitActiveSec=5min

   [Install]
   WantedBy=timers.target
   EOF

   sudo systemctl daemon-reload
   sudo systemctl enable --now heartbeat.timer
   ```
4. Check: the check turns green on healthchecks.io within a minute.
5. Never commit the ping URL.

## Measure the internet speed

Every 2 hours; results in Grafana's **Server Health** dashboard (Download & Upload, Ping & Jitter) and in `/var/log/internet-speedtest.csv`.

1. Install the client:
   ```bash
   sudo snap install speedtest
   ```
2. Create the script (replace `<tailscale-ip>` with the output of `tailscale ip -4`):
   ```bash
   sudo tee /usr/local/bin/internet-speedtest >/dev/null <<'EOF'
   #!/usr/bin/env bash
   # internet-speedtest — measure internet speed, log it to a CSV and send it to the OTel Collector
   set -euo pipefail

   OTLP_URL="http://<tailscale-ip>:4318/v1/metrics"   # BIND_ADDR + port 4318
   CSV=/var/log/internet-speedtest.csv
   SPEEDTEST=${SPEEDTEST:-/snap/bin/speedtest}

   result=$("$SPEEDTEST" --accept-license --accept-gdpr --format=json)

   # Python prints 2 lines: the CSV row, then the OTLP JSON payload
   output=$(python3 - "$result" <<'PY'
   import json, sys, time
   r = json.loads(sys.argv[1])
   down = r["download"]["bandwidth"] * 8 / 1e6
   up   = r["upload"]["bandwidth"] * 8 / 1e6
   ping = r["ping"]["latency"]
   jitter = r["ping"]["jitter"]
   loss = r.get("packetLoss")

   now = str(time.time_ns())
   def gauge(name, value):
       return {"name": name, "gauge": {"dataPoints": [{"asDouble": float(value), "timeUnixNano": now}]}}
   metrics = [gauge("internet_download_mbps", down), gauge("internet_upload_mbps", up),
              gauge("internet_ping_ms", ping), gauge("internet_jitter_ms", jitter)]
   if loss is not None:
       metrics.append(gauge("internet_packet_loss_percent", loss))

   stamp = time.strftime("%Y-%m-%d %H:%M:%S")
   print(f"{stamp},{down:.1f},{up:.1f},{ping:.1f},{jitter:.1f},{'' if loss is None else loss}")
   print(json.dumps({"resourceMetrics": [{
       "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "speedtest"}}]},
       "scopeMetrics": [{"scope": {"name": "speedtest"}, "metrics": metrics}]}]}))
   PY
   )
   row=$(head -n1 <<<"$output")
   payload=$(tail -n1 <<<"$output")

   [ -f "$CSV" ] || echo "time,download_mbps,upload_mbps,ping_ms,jitter_ms,packet_loss_percent" > "$CSV"
   echo "$row" >> "$CSV"

   if curl -fsS -m 10 -o /dev/null -H 'Content-Type: application/json' -d "$payload" "$OTLP_URL"; then
     echo "Sent to Grafana: $row"
   else
     echo "Stack not reachable, saved to $CSV only: $row"
   fi
   EOF
   sudo chmod +x /usr/local/bin/internet-speedtest
   ```
3. With the stack up (`make up`), test it once (~30 s):
   ```bash
   sudo internet-speedtest      # Sent to Grafana: <time>,<down>,<up>,<ping>,<jitter>,<loss>
   ```
4. Run it every 2 hours:
   ```bash
   sudo tee /etc/systemd/system/internet-speedtest.service >/dev/null <<'EOF'
   [Unit]
   Description=Internet speed test
   After=network-online.target
   Wants=network-online.target

   [Service]
   Type=oneshot
   ExecStart=/usr/local/bin/internet-speedtest
   EOF

   sudo tee /etc/systemd/system/internet-speedtest.timer >/dev/null <<'EOF'
   [Unit]
   Description=Internet speed test every 2 hours

   [Timer]
   OnBootSec=10min
   OnUnitActiveSec=2h
   RandomizedDelaySec=5min

   [Install]
   WantedBy=timers.target
   EOF

   sudo systemctl daemon-reload
   sudo systemctl enable --now internet-speedtest.timer
   ```
5. Check:
   ```bash
   systemctl list-timers internet-speedtest.timer
   journalctl -u internet-speedtest -n 5
   ```
6. Read the history: `column -s, -t /var/log/internet-speedtest.csv | tail -n 20`
7. Change the frequency: edit `OnUnitActiveSec=` in `/etc/systemd/system/internet-speedtest.timer` (not below `1h`), then
   ```bash
   sudo systemctl daemon-reload && sudo systemctl restart internet-speedtest.timer
   ```
8. Remove it:
   ```bash
   sudo systemctl disable --now internet-speedtest.timer
   sudo rm -f /etc/systemd/system/internet-speedtest.* /usr/local/bin/internet-speedtest
   sudo systemctl daemon-reload
   sudo rm -f /var/log/internet-speedtest.csv     # optional: the history
   sudo snap remove speedtest                     # optional: the client
   ```

## Test the server

Once the homelab runs ([First start](#first-start)):

- [ ] `sudo reboot`, don't log in, close the lid. After 5 minutes, from a phone on mobile data with Tailscale: `ssh <user>@<tailscale-ip>` works.
- [ ] `systemctl is-active tailscaled` → `active`; `systemctl is-active docker` → `inactive` until the first `docker` command.
- [ ] `make up`; Grafana's **Server Health** dashboard shows temperatures.
- [ ] Unplug the Ethernet cable for 1 minute: still reachable. Plug it back: `ip route show default` uses Ethernet.
- [ ] `sudo systemctl stop tailscaled`, wait 5 minutes: `journalctl -t tailscale-watchdog` shows "Restarting tailscaled", `tailscale status` works.
- [ ] `make down`, then `echo c | sudo tee /proc/sysrq-trigger`: the laptop reboots by itself within a minute, Tailscale is back.
- [ ] Unplug the charger for 2 minutes: the laptop keeps running.

---

## First start

1. Get the repository:
   ```bash
   git clone <homelab-infra repository> && cd homelab-infra
   ```
2. Create `.env`:
   - `make env`
   - raw: `cp .env.example .env && chmod 600 .env`
3. Generate the passwords and secrets:
   - `make secrets`
   - raw: `./scripts/secrets.sh`
4. Edit `.env` (`nano .env`):
   - `HOMELAB_DOMAIN=<HOMELAB_DOMAIN>`
   - `BIND_ADDR=<tailscale-ip>` (`tailscale ip -4`; every port listens there only)
   - `LLM_BASE_URL` and `LLM_API_KEY`: NVIDIA's `https://integrate.api.nvidia.com/v1` with your key, or `http://llm:8080/v1` for the local models
   - optional: `TOOLBOX_EXTRA_ALLOWED_HOSTS="<machine>:8001"` if MCP clients use the short MagicDNS name
   - optional: `POSTGRES_USER`, `POSTGRES_DB`, `MONGO_ROOT_USER`, `GRAFANA_ADMIN_USER`, `KEYCLOAK_ADMIN_USER`
5. `make secrets` again → *nothing left to set by hand*.
6. Validate:
   - `make validate`
   - raw: `./scripts/validate.sh`
7. Start (the first time downloads ~5 GB):
   - `make up`
   - raw: `docker compose up -d --build --remove-orphans && docker compose kill -s SIGHUP prometheus alloy`
8. Create your account (email, names, password twice):
   - `make user-add ACCOUNT=<name>`
   - raw: `./scripts/users.sh add <name>`
9. Make it admin:
   - `make user-admin ACCOUNT=<name>`
   - raw: `./scripts/users.sh admin <name>`
10. Verify, every line ✓:
    - `make verify` — raw: `./scripts/verify.sh`
    - `make health` (wait a minute after the start for Loki and Tempo)
11. Open `https://<HOMELAB_DOMAIN>/status` on a Tailscale device and sign in.

## Start, stop, restart

| Scenario | make | Raw command |
|---|---|---|
| Start everything / apply any change | `make up` | `docker compose up -d --build --remove-orphans` |
| Start some services | `make up S="grafana loki"` | `docker compose up -d --build --remove-orphans grafana loki` |
| Start one group | `make up-gateway` · `up-db` · `up-kafka` · `up-obs` · `up-llm` · `up-apps` | `docker compose up -d <services of the group>` |
| Stop everything, keep data | `make down` | `docker compose down --remove-orphans` |
| Stop without removing | `make stop S=grafana` | `docker compose stop grafana` |
| Start stopped containers | `make start S=grafana` | `docker compose start grafana` |
| Restart | `make restart S=grafana` | `docker compose restart grafana` |
| Recreate after a config change | `make recreate S=caddy` | `docker compose up -d --force-recreate caddy` |
| Rebuild without cache | `make build S=llm-sd-exporter` | `docker compose build --no-cache llm-sd-exporter` |
| After a server reboot | `make up` | `docker compose up -d --build --remove-orphans` |

## Check the stack

| Scenario | make | Raw command |
|---|---|---|
| Is every container healthy? | `make health` | `docker compose exec -T caddy wget -q -T 5 -O - http://<service>:<port>/<path>` (one per service) |
| Is sign-in and data protection working? | `make verify` | `./scripts/verify.sh` |
| What runs? | `make ps` | `docker compose ps` |
| Why does a service fail? | `make logs S=keycloak TAIL=500` | `docker compose logs -f --tail=500 keycloak` |
| CPU and memory | `make stats` | `docker stats` |
| Prometheus targets | `make targets` | `docker compose exec -T caddy wget -q -O - http://prometheus:9090/api/v1/targets` |
| Disk used by data | `make volumes` | `docker system df -v` |
| Resolved configuration | `make config` | `docker compose config` |

In a browser: `https://<HOMELAB_DOMAIN>/status`.

## Update the stack

**Pull a new version of this repository**
1. `git pull`
2. `make validate`
3. `make up`
4. `make verify && make health`

**New image versions**
1. Bump the `*_TAG` in `.env`, one service at a time.
2. `make validate`
3. `make update` — raw: `docker compose pull --ignore-buildable && docker compose up -d --build --remove-orphans`
4. `make verify && make health`

## Accounts

**List accounts**
- `make users` — raw: `./scripts/users.sh list`

**Create an account**
1. `make user-add ACCOUNT=<name>` — raw: `./scripts/users.sh add <name>`
2. Enter email, first name, last name, then the password twice (12+ characters).
3. Optional admin: `make user-admin ACCOUNT=<name>`.
4. Send the person `https://<HOMELAB_DOMAIN>/`.

**Set a new password for someone**
1. `make user-password ACCOUNT=<name>` — raw: `./scripts/users.sh password <name>`
2. Enter the new password twice.

**Change your own password**
1. Open `https://<HOMELAB_DOMAIN>:8443/realms/homelab/account` (or the **Account** tile in homelab-ui).
2. **Account security → Signing in → Password → Update**.

**A password expired (90 days)**
1. Sign in as usual.
2. Enter a new password on the **Update password** page.

**Give / take the admin role**
- give: `make user-admin ACCOUNT=<name>` — raw: `./scripts/users.sh admin <name>`
- take: `make user-unadmin ACCOUNT=<name>` — raw: `./scripts/users.sh unadmin <name>`
- The person signs out and in again.

**Block an account for a while**
1. `make user-disable ACCOUNT=<name>` — raw: `./scripts/users.sh disable <name>`
2. To end its open sessions now too: `make sessions-revoke`.
3. Later: `make user-enable ACCOUNT=<name>` — raw: `./scripts/users.sh enable <name>`

**Unlock after too many wrong passwords**
- `make user-unlock ACCOUNT=<name>` — raw: `./scripts/users.sh unlock <name>`

**Remove an account**
1. `make backup-postgres` (to keep its Tasker data restorable).
2. `make user-remove ACCOUNT=<name>` — raw: `./scripts/users.sh remove <name>`
3. Type the account name to confirm.
4. Answer whether to delete its Tasker workflows and favorites.
5. `make sessions-revoke` to end its open sessions now.

**Sign everyone out now**
- `make sessions-revoke`
- raw:
  ```bash
  ./scripts/secrets.sh --rotate OAUTH2_PROXY_COOKIE_SECRET
  docker compose up -d --force-recreate oauth2-proxy
  ./scripts/users.sh logout-all
  ```

**Sign out yourself**
- **Sign out** in homelab-ui's left sidebar, or open `https://<HOMELAB_DOMAIN>/oauth2/sign_out?rd=%2F`.

## Secrets and passwords

**Fill missing secrets**
- `make secrets` — raw: `./scripts/secrets.sh`

**Rotate a gateway secret**
1. `./scripts/secrets.sh --rotate <NAME>` — `<NAME>` is one of `OAUTH2_PROXY_COOKIE_SECRET`, `OAUTH2_PROXY_CLIENT_SECRET`, `GRAFANA_OIDC_CLIENT_SECRET`, `TASKER_GATEWAY_SECRET`, `LLM_GATEWAY_API_KEY`
2. `make up`
3. After `LLM_GATEWAY_API_KEY`: update the scripts and apps that call the LLM API.

**Check the database passwords in `.env`**
- `make db-passwords-check` — raw: `./scripts/db-passwords.sh check`

**Change the PostgreSQL password**
1. Set the new `POSTGRES_PASSWORD` in `.env` (letters and digits).
2. `make postgres-password-sync` — raw: `./scripts/db-passwords.sh postgres-sync`
3. `make up`

**Change the MongoDB password**
1. Set the new `MONGO_ROOT_PASSWORD` in `.env`.
2. `make mongo-password-sync` — raw: `./scripts/db-passwords.sh mongo-sync` (asks the current password)
3. `make up`

**Change `POSTGREST_PASSWORD` or `KEYCLOAK_DB_PASSWORD`**
1. Set the new value in `.env`.
2. `make up`

**Change Grafana's local admin password**
1. ```bash
   docker compose exec grafana grafana cli admin reset-admin-password '<new password>'
   ```
2. Set the same value as `GRAFANA_ADMIN_PASSWORD` in `.env`.

**Change Keycloak's admin password**
1. Run (first prompt: current password, second: new one):
   ```bash
   docker compose exec keycloak bash -c 'kc=/opt/keycloak/bin/kcadm.sh; cfg=/tmp/kcadm-pw.config; trap "rm -f $cfg" EXIT; $kc config credentials --config $cfg --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" && $kc set-password --config $cfg -r master --username "$KC_BOOTSTRAP_ADMIN_USERNAME"'
   ```
2. Set the new value as `KEYCLOAK_ADMIN_PASSWORD` in `.env`.
3. `make up`
4. `make users` works → done.

## Database shells

| Scenario | make | Raw command |
|---|---|---|
| psql on the homelab database | `make psql` | `docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'` |
| psql on the accounts database | — | `docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d keycloak'` |
| mongosh | `make mongosh` | `docker compose exec mongodb sh -c 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'` |
| Shell in a container | `make sh S=kafka` | `docker compose exec kafka sh` |

**Connect an app:** PostgreSQL `<HOMELAB_DOMAIN>:5432`; MongoDB `mongodb://<user>:<password>@<HOMELAB_DOMAIN>:27017/?authSource=admin`; from a container of the stack: `postgres:5432`, `mongodb:27017`.

## Database migrations

**Add a migration**
1. `make backup-postgres`
2. Create the file:
   - `make migration-new NAME=add_workflow_tags`
   - raw: create `repository/postgres/migrations/<next number>_add_workflow_tags.sql` with the lines `-- migrate:up` and `-- migrate:down`
3. Write the change under `-- migrate:up` and its undo under `-- migrate:down`; end both with `NOTIFY pgrst, 'reload schema';` when Tasker's API uses the change:
   ```sql
   -- migrate:up
   ALTER TABLE tasker.workflows ADD COLUMN tags text[] NOT NULL DEFAULT '{}';
   NOTIFY pgrst, 'reload schema';

   -- migrate:down
   ALTER TABLE tasker.workflows DROP COLUMN tags;
   NOTIFY pgrst, 'reload schema';
   ```
4. `make validate`
5. Apply:
   - `make migrate`
   - raw: `docker compose run --rm db-migrate migrate && docker compose kill -s SIGUSR1 postgrest`
6. Check:
   - `make migrate-status`
   - raw: `docker compose run --rm db-migrate status`
7. Commit the file.

**Undo the latest migration**
1. `make backup-postgres`
2. `make migrate-rollback` — raw: `docker compose run --rm db-migrate rollback`
3. Type `rollback` to confirm.
4. `make migrate-status`

**Fix a migration that already ran**
1. Don't edit it.
2. Add a new migration that corrects it (steps above).

More on the files: [repository/postgres/MIGRATIONS.md](repository/postgres/MIGRATIONS.md).

## Backups and restores

**Back up everything**
1. `make backup` — raw: `make backup-postgres && make backup-mongo`
2. Copy `backups/` off the server.

| Scenario | make | Raw command |
|---|---|---|
| PostgreSQL + accounts | `make backup-postgres` | `docker compose exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' > backups/postgres_<date>.dump` and the same with `keycloak` → `backups/keycloak_<date>.dump` |
| MongoDB | `make backup-mongo` | `docker compose exec -T mongodb sh -c 'mongodump -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip --quiet' > backups/mongo_<date>.archive` |

**Restore the homelab database**
1. `make restore-postgres FILE=backups/postgres_<date>.dump`
   - raw: `docker compose exec -T postgres sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists' < backups/postgres_<date>.dump`
2. Type `restore`.
3. `make restart S=postgrest`

**Restore the accounts**
1. `make restore-postgres FILE=backups/keycloak_<date>.dump DB=keycloak`
   - raw: same with `-d keycloak`
2. Type `restore`.
3. `make restart S=keycloak`

**Restore MongoDB**
1. `make restore-mongo FILE=backups/mongo_<date>.archive`
   - raw: `docker compose exec -T mongodb sh -c 'mongorestore -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --archive --gzip --drop' < backups/mongo_<date>.archive`
2. Type `restore`.

## Gateway

**Check the HTTPS certificate**
1. `curl -sS https://<HOMELAB_DOMAIN>/healthz` → `OK`
2. If not: `make logs S=caddy`.

**Change the domain**
1. Set `HOMELAB_DOMAIN` in `.env`.
2. `make validate`
3. `make up`
4. `make verify`
5. Everyone signs in again at the new address.

**Apply a Caddyfile change**
1. Edit `gateway/caddy/Caddyfile`.
2. `make validate`
3. `make recreate S=caddy` — raw: `docker compose up -d --force-recreate caddy`

**Change the password policy, lockout or a client**
1. Edit `gateway/keycloak/sync.sh`.
2. `make up` — raw: `docker compose up -d --build --remove-orphans` (runs `keycloak-sync`)
3. `make logs S=keycloak-sync`

**Call the LLM API from another machine**
```bash
curl https://<HOMELAB_DOMAIN>:8090/v1/models -H "Authorization: Bearer $LLM_GATEWAY_API_KEY"
```

**Open the tools**
- The list of URLs: [README → Access](README.md#access), or the Status page.

## LLM and agent

| Scenario | make | Raw command |
|---|---|---|
| Is it up, which models | `make llm-status` | `docker compose exec -T caddy wget -q -O - http://llm:8080/v1/models` |
| Models loaded now | `make llm-running` | `python3 ai/llm/test.py running https://<HOMELAB_DOMAIN>:8090` |
| Ask a question | `make llm-ask M=qwen3-8b Q="Hello"` | `python3 ai/llm/test.py ask https://<HOMELAB_DOMAIN>:8090 qwen3-8b "Hello"` |
| Logs | `make llm-logs` | `docker compose logs -f --tail=200 llm` |
| Free its RAM | `make llm-down` | `docker compose stop llm` |
| Start it again | `make up-llm` | `docker compose up -d llm` |
| Download models ahead | — | `./scripts/download_models.sh --list` · `./scripts/download_models.sh qwen3-14b` · `./scripts/download_models.sh --all` |
| Start agent, toolbox, MCP Inspector, UI | `make up-apps` | `docker compose up -d agent-toolbox agent-runtime mcp-inspector homelab-ui` |
| Stop them | `make down-apps` | `docker compose stop agent-toolbox agent-runtime mcp-inspector homelab-ui` |
| Agent logs | `make logs S="agent-runtime agent-toolbox"` | `docker compose logs -f --tail=200 agent-runtime agent-toolbox` |

**Chat with the agent**
1. Open `https://<HOMELAB_DOMAIN>/agent` (homelab-ui → **Agent**).

**Call the agent API from a tailnet device**
1. API docs: `http://<HOMELAB_DOMAIN>:8000/docs` (needs `WEB_DOCS=true`).
2. Health: `curl http://<HOMELAB_DOMAIN>:8000/actuator/health`

**Connect an MCP client to the toolbox from a tailnet device**
1. Server URL: `http://<HOMELAB_DOMAIN>:8001/mcp`, transport **Streamable HTTP**.
2. Using another name (e.g. `<machine>:8001`)? Add it to `TOOLBOX_EXTRA_ALLOWED_HOSTS` in `.env`, then `make up S=agent-toolbox`.

**List and try the agent's tools (agent-toolbox)**
1. Open `https://<HOMELAB_DOMAIN>:6274` (homelab-ui → **MCP Inspector**) and sign in.
2. Pick **agent-toolbox** → **Connect**.
3. **Tools** → **List tools** → pick a tool → fill its inputs → **Run tool**.

**Update the MCP Inspector**
1. Set `MCP_INSPECTOR_TAG` in `.env` (releases: [github.com/modelcontextprotocol/inspector/releases](https://github.com/modelcontextprotocol/inspector/releases)).
2. `make pull S=mcp-inspector && make up S=mcp-inspector`
   - raw: `docker compose pull mcp-inspector && docker compose up -d mcp-inspector`
3. `make verify`

**Add a model**
1. Add it to `ai/llm/config.yml` (see [ai/llm/README.md](ai/llm/README.md)).
2. `./scripts/download_models.sh <model>`
3. `make recreate S=llm`
4. `make llm-status`

## Kafka

| Scenario | make | Raw command |
|---|---|---|
| List topics | `make topics` | `docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list` |
| Create a topic | `make topic-create TOPIC=demo PARTITIONS=3` | `docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --if-not-exists --topic demo --partitions 3 --replication-factor 1` |
| Describe a topic | `make topic-describe TOPIC=demo` | `docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic demo` |
| Read a topic | `make consume TOPIC=demo` | `docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic demo --from-beginning` |
| Consumer groups and lag | `make groups` | `docker compose exec kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups` |

**Connect an app from another machine**
1. Set `KAFKA_EXTERNAL_HOST=<HOMELAB_DOMAIN>` in `.env`.
2. `make up S=kafka`
3. Bootstrap server: `<HOMELAB_DOMAIN>:9094` (containers: `kafka:9092`).

## Observability

**Send your app's telemetry to Grafana**
1. Add to its compose service:
   ```yaml
   environment:
     OTEL_SERVICE_NAME: my-service
     OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector:4318   # another machine: http://<HOMELAB_DOMAIN>:4318
     OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
   labels:
     homelab.logs.otlp: "true"   # only if it sends its logs over OTLP
   ```
2. `make up S=my-service`
3. Grafana → **Explore** → Tempo / Loki / Prometheus, `service_name = my-service`.

**Apply a config change**

| File | make | Raw command |
|---|---|---|
| `observability/metrics/prometheus/prometheus.yml` | `make reload-prometheus` | `docker compose kill -s SIGHUP prometheus` |
| `observability/collectors/alloy/config.alloy` | `make reload-alloy` | `docker compose kill -s SIGHUP alloy` |
| Loki, Tempo, OTel Collector config | `make recreate S=loki` | `docker compose up -d --force-recreate loki` |
| Grafana dashboard JSON | `make restart S=grafana` | `docker compose restart grafana` |

Run `make validate` before each.

**Keep a dashboard made in Grafana**
1. Dashboard → **Export → Export as JSON** → download.
2. Save it in `observability/dashboards/grafana/dashboards/<name>.json`.
3. `make restart S=grafana`
4. Commit the file.

**Add an alert**
1. Grafana → **Alerting → Contact points → Add contact point**; test it.
2. **Alerting → Alert rules → New alert rule**; pick a query, condition, pending period and the contact point. Examples:

| Alert | Query | Condition | Pending |
|---|---|---|---|
| CPU too hot | `max(node_hwmon_temp_celsius)` | above 90 | 5m |
| On battery | `max(node_power_supply_online{power_supply!~"BAT.*"})` | below 1 | 2m |
| Battery low | `min(node_power_supply_capacity{power_supply=~"BAT.*"})` | below 30 | 1m |
| Disk almost full | `100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})` | above 90 | 15m |
| Server rebooted | `changes(node_boot_time_seconds[15m])` | above 0 | 0s |

**Change retention**
- Prometheus: `PROMETHEUS_RETENTION_TIME` / `_SIZE` in `.env`, then `make up S=prometheus`.
- Loki: `retention_period` in `observability/logs/loki/config.yml`, then `make recreate S=loki`.
- Tempo: `block_retention` in `observability/traces/tempo/config.yml`, then `make recreate S=tempo`.

## Publish and deploy homelab-ui

**On your Mac, in the homelab-ui repository**
1. `make check` — raw: `npx prettier --check . && npx tsc -p tsconfig.app.json --noEmit && npx ng test --watch=false`
2. `docker login`
3. `make docker_publish` (or `make docker_publish TAG=1.4.0`)
   - raw: `docker buildx build --platform linux/amd64,linux/arm64 -f devops/docker/Dockerfile -t toufik142/homelab-ui:latest --push .`

**On the server**
1. Pinned version only: `HOMELAB_UI_TAG=1.4.0` in `.env`.
2. `make pull S=homelab-ui && make up S=homelab-ui`
   - raw: `docker compose pull homelab-ui && docker compose up -d homelab-ui`
3. Open `https://<HOMELAB_DOMAIN>/status` and reload the page.

**Roll back**
1. `HOMELAB_UI_TAG=<previous tag>` in `.env`.
2. `make pull S=homelab-ui && make up S=homelab-ui`

## Add a service

1. Create `<group>/<service>/compose.yml` (`gateway`, `repository`, `message_broker`, `observability/<metrics|logs|traces|collectors|dashboards>`, `ai`, `apps`).
2. Add it to `include:` in `compose.yml`.
3. Add `<SERVICE>_TAG` to `.env.example` and `.env`; set `mem_limit`, `cpus` and the `logging` block like the other services.
4. Web interface — don't publish its port; in `gateway/caddy/Caddyfile` add:
   ```
   {$HOMELAB_DOMAIN}:<port> {
   	import signed_in_tool <service>:<port>
   }
   ```
   and the port in `gateway/caddy/compose.yml`.
5. Health — in the `Caddyfile` under `/api/*`: `import health_route <service> <service>:<port> <health path>`; in the `Makefile`: add it to `HEALTH_INTERNAL`.
6. Status page — in homelab-ui: add it to `STACK_SERVICES` (`src/app/features/status/domain/stack-services.ts`), then [publish the UI](#publish-and-deploy-homelab-ui).
7. Metrics — add a scrape job in `observability/metrics/prometheus/prometheus.yml`.
8. Add it to [README.md](README.md).
9. `make validate && make up && make verify && make health`

## Troubleshooting

**`make up` stops at `db-migrate`, log says `password authentication failed`**
1. `make db-passwords-check`
2. `make postgres-password-sync`
3. `make up`

**`keycloak-sync` failed**
1. `make logs S=keycloak-sync`
2. `docker compose logs --tail=100 keycloak`
3. Wrong admin password → [Change Keycloak's admin password](#secrets-and-passwords), else `make up` again.

**`https://<HOMELAB_DOMAIN>` doesn't open, or the certificate is refused**
1. The device is on Tailscale: `tailscale status`.
2. Tailscale admin console → **DNS** → HTTPS Certificates on.
3. `tailscale status --json | jq -r .Self.DNSName` = `HOMELAB_DOMAIN` (without the final dot).
4. `make logs S=caddy`

**Every page sends you back to the sign-in**
1. `timedatectl` → the clock is synchronized.
2. `make recreate S=oauth2-proxy`
3. Clear the browser's cookies for `<HOMELAB_DOMAIN>`.

**"Account is temporarily disabled"**
- `make user-unlock ACCOUNT=<name>`, or wait 15 minutes.

**`make health`: Loki or Tempo ✗ right after a start**
- Wait one minute, `make health` again.

**Status page: a service is *Not ready***
1. `make ps`
2. `make logs S=<service>`
3. `make restart S=<service>`

**Status page: everything *Unknown***
1. Open it at `https://<HOMELAB_DOMAIN>/status` (not from `npm start`).
2. `make logs S=prometheus`

**A container exits with `exec format error`**
1. Publish the image for both platforms (`make docker_publish` in homelab-ui).
2. `make pull S=<service> && make up S=<service>`

**MCP Inspector: the page answers 403, or `/api` calls fail with 403**
1. `HOMELAB_DOMAIN` in `.env` is the address in the browser.
2. `make recreate S=mcp-inspector` (it reads `HOMELAB_DOMAIN` at start).
3. `make logs S=mcp-inspector`

**MCP Inspector: Connect to agent-toolbox fails**
1. `make health` → agent-toolbox ✓.
2. `make logs S=agent-toolbox` → look for `Invalid Host header` or `Invalid Origin header`.
3. `make verify` → "the MCP Inspector reaches agent-toolbox" ✓.

**`make user-*` says `No account named …`**
- `make users`

**The laptop sleeps with the lid closed**
1. `systemctl status sleep.target` → masked.
2. `cat /etc/systemd/logind.conf.d/server.conf` → exists.
3. In the BIOS: disable any "sleep on lid close".

**The laptop rebooted on its own**
```bash
journalctl -b -1 -e                  # end of the previous boot
journalctl -t tailscale-watchdog     # reboots by the watchdog
last -x reboot | head
```

**Tailscale is logged out after a reboot**
1. `sudo tailscale up`
2. Admin console → the laptop → **Disable key expiry**.

**The laptop reboots in a loop**
1. Within 5 minutes of boot:
   ```bash
   sudo systemctl disable --now tailscale-watchdog.timer
   sudo rm /etc/systemd/system.conf.d/watchdog.conf /etc/sysctl.d/99-server-autoreboot.conf
   sudo reboot
   ```
2. `journalctl -b -1 -e`

**No internet speed data in Grafana**
1. `sudo internet-speedtest` with the stack up.
2. `Stack not reachable` → `docker port otel-collector` shows 4318; `make logs S=otel-collector`.
3. Prometheus (`https://<HOMELAB_DOMAIN>:9090/query`): `{__name__=~"internet.*"}`.

**No temperatures in Grafana**
1. `sensors` shows nothing → `sudo sensors-detect --auto`, reboot.
2. Prometheus: `node_hwmon_temp_celsius`.

## Reset the homelab

Deletes all data: databases, accounts, metrics, logs, traces, Kafka, models, agent files.

1. `make backup` (if anything is worth keeping)
2. `make clean`, type `delete`
   - raw: `docker compose down --remove-orphans --volumes`
3. `docker volume ls -q | grep '^homelab_'` → nothing.
4. `mv .env .env.old`
5. Follow [First start](#first-start).
6. `rm .env.old`

## Undo the server setup

```bash
# Sleep and lid
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo rm -f /etc/systemd/logind.conf.d/server.conf

# Desktop
sudo systemctl set-default graphical.target

# Docker at boot
sudo systemctl enable docker.service containerd.service

# Freeze protection
sudo systemctl disable --now tailscale-watchdog.timer
sudo rm -f /etc/systemd/system/tailscale-watchdog.* /usr/local/bin/tailscale-watchdog.sh
sudo rm -f /etc/systemd/system.conf.d/watchdog.conf /etc/modules-load.d/watchdog.conf
sudo rm -f /etc/sysctl.d/99-server-autoreboot.conf
sudo rm -rf /etc/systemd/system/tailscaled.service.d

# Internet speed test
sudo systemctl disable --now internet-speedtest.timer
sudo rm -f /etc/systemd/system/internet-speedtest.* /usr/local/bin/internet-speedtest

# Battery, heartbeat, updates
sudo systemctl disable --now battery-limit.service heartbeat.timer
sudo rm -f /etc/systemd/system/battery-limit.service /etc/systemd/system/heartbeat.*
sudo rm -f /etc/apt/apt.conf.d/52server-reboot

# Wi-Fi power saving
sudo rm -f /etc/NetworkManager/conf.d/wifi-powersave-off.conf

sudo systemctl daemon-reload
sudo reboot
```

## Every make command

`make help` prints this list on the server.

| make | Raw command |
|---|---|
| `make env` | `cp .env.example .env && chmod 600 .env` |
| `make secrets` | `./scripts/secrets.sh` |
| `make validate` | `./scripts/validate.sh` |
| `make config` | `docker compose config` |
| `make up [S=…]` | `./scripts/up.sh` → `docker compose up -d --build --remove-orphans`, then `docker compose kill -s SIGHUP prometheus alloy` |
| `make down` | `./scripts/down.sh` → `docker compose down --remove-orphans` |
| `make stop [S=…]` | `docker compose stop` |
| `make start [S=…]` | `docker compose start` |
| `make restart [S=…]` | `docker compose restart` |
| `make recreate [S=…]` | `docker compose up -d --force-recreate` |
| `make build [S=…]` | `docker compose build --no-cache` |
| `make pull [S=…]` | `docker compose pull --ignore-buildable` |
| `make update` | `make pull && make up` |
| `make up-gateway` | `docker compose up -d caddy keycloak oauth2-proxy` |
| `make up-db` | `docker compose up -d postgres mongodb postgres-exporter mongodb-exporter postgrest` |
| `make up-kafka` | `docker compose up -d kafka kafka-ui kafka-exporter` |
| `make up-obs` | `docker compose up -d prometheus loki tempo otel-collector alloy grafana` |
| `make up-llm` | `docker compose up -d llm` |
| `make up-apps` | `docker compose up -d agent-toolbox agent-runtime mcp-inspector homelab-ui` |
| `make down-apps` | `docker compose stop agent-toolbox agent-runtime mcp-inspector homelab-ui` |
| `make ps` | `docker compose ps` |
| `make logs [S=…] [TAIL=…]` | `docker compose logs -f --tail=200` |
| `make stats` | `docker stats` |
| `make health` | `docker compose exec -T caddy wget -q -T 5 -O - <health URL>` per service, `curl https://<HOMELAB_DOMAIN>/healthz` |
| `make verify` | `./scripts/verify.sh` |
| `make targets` | `docker compose exec -T caddy wget -q -O - http://prometheus:9090/api/v1/targets` |
| `make volumes` | `docker system df -v` |
| `make users` | `./scripts/users.sh list` |
| `make user-add ACCOUNT=…` | `./scripts/users.sh add <name>` |
| `make user-password ACCOUNT=…` | `./scripts/users.sh password <name>` |
| `make user-admin ACCOUNT=…` | `./scripts/users.sh admin <name>` |
| `make user-unadmin ACCOUNT=…` | `./scripts/users.sh unadmin <name>` |
| `make user-disable ACCOUNT=…` | `./scripts/users.sh disable <name>` |
| `make user-enable ACCOUNT=…` | `./scripts/users.sh enable <name>` |
| `make user-unlock ACCOUNT=…` | `./scripts/users.sh unlock <name>` |
| `make user-remove ACCOUNT=…` | `./scripts/users.sh remove <name>` |
| `make sessions-revoke` | `./scripts/secrets.sh --rotate OAUTH2_PROXY_COOKIE_SECRET && docker compose up -d --force-recreate oauth2-proxy && ./scripts/users.sh logout-all` |
| `make migrate` | `docker compose run --rm db-migrate migrate && docker compose kill -s SIGUSR1 postgrest` |
| `make migrate-status` | `docker compose run --rm db-migrate status` |
| `make migrate-rollback` | `docker compose run --rm db-migrate rollback` |
| `make migration-new NAME=…` | create `repository/postgres/migrations/<NNN>_<name>.sql` |
| `make db-passwords-check` | `./scripts/db-passwords.sh check` |
| `make postgres-password-sync` | `./scripts/db-passwords.sh postgres-sync` |
| `make mongo-password-sync` | `./scripts/db-passwords.sh mongo-sync` |
| `make sh S=…` | `docker compose exec <service> sh` |
| `make psql` | `docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'` |
| `make mongosh` | `docker compose exec mongodb sh -c 'mongosh -u … -p … --authenticationDatabase admin'` |
| `make topics` · `topic-create` · `topic-describe` · `consume` · `groups` | see [Kafka](#kafka) |
| `make reload-prometheus` | `docker compose kill -s SIGHUP prometheus` |
| `make reload-alloy` | `docker compose kill -s SIGHUP alloy` |
| `make llm-status` · `llm-running` · `llm-ask` · `llm-logs` · `llm-down` | see [LLM and agent](#llm-and-agent) |
| `make backup` | `make backup-postgres && make backup-mongo` |
| `make backup-postgres` · `backup-mongo` | `pg_dump` / `mongodump` into `backups/`, see [Backups and restores](#backups-and-restores) |
| `make restore-postgres FILE=… [DB=keycloak]` | `pg_restore --clean --if-exists` |
| `make restore-mongo FILE=…` | `mongorestore --archive --gzip --drop` |
| `make clean` | `./scripts/down.sh --volumes` → `docker compose down --remove-orphans --volumes` |
| `make prune` | `docker image prune -f && docker builder prune -f` |
