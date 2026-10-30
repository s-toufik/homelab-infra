# Homelab DevOps guide

Scenarios, as steps. Each `make` command is followed by the raw command it runs.

- Run commands on the server, in the `homelab-infra` folder, unless a step says otherwise.
- `<HOMELAB_DOMAIN>` = `<machine>.<tailnet>.ts.net`. `<tailscale-ip>` = `tailscale ip -4`. `<lan-ip>` = the `src` of `ip -4 route get 1.1.1.1`.
- `<release>` = a release name in `helmfile.yaml.gotmpl` (`caddy`, `keycloak`, `homelab-ui`…). `<name>` = an account name.

**Server**
[Prepare the server](#prepare-the-server) ·
[Install Kubernetes](#install-kubernetes) ·
[Protect it against freezes](#protect-the-server-against-freezes) ·
[Battery and power cuts](#battery-and-power-cuts) ·
[Get notified when the server is offline](#get-notified-when-the-server-is-offline) ·
[Measure the internet speed](#measure-the-internet-speed) ·
[Test the server](#test-the-server) ·
[Undo the server setup](#undo-the-server-setup)

**Homelab**
[Set up GitHub](#set-up-github) ·
[First deploy](#first-deploy) ·
[Deploy](#deploy) ·
[Release an app](#release-an-app) ·
[Roll back](#roll-back) ·
[Change a chart](#change-a-chart) ·
[Check the homelab](#check-the-homelab) ·
[Accounts](#accounts) ·
[Secrets](#secrets) ·
[Database shell](#database-shell) ·
[Troubleshooting](#troubleshooting) ·
[Reset the homelab](#reset-the-homelab) ·
[Every make command](#every-make-command)

---

## Prepare the server

Turn an Ubuntu laptop into an always-on server. Do it on the laptop itself (keyboard and screen), plugged into power.

### 1. Update and install the tools

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y curl jq lm-sensors openssh-server nftables
```

### 2. Install and connect Tailscale

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

### 3. Never sleep

1. ```bash
   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
   ```
2. Check: `systemctl status sleep.target` → `Loaded: masked`.

### 4. Keep running with the lid closed

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

### 5. Boot without the desktop

1. ```bash
   sudo systemctl set-default multi-user.target
   sudo reboot
   ```
2. Log in at the text prompt.
3. Check: `systemctl get-default` → `multi-user.target`.
4. Close the lid for one minute, open it: `uptime` shows no sleep.

### 6. Ethernet as the main network

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

### 7. Wi-Fi as the fallback network

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

### 8. Start Tailscale and SSH at boot

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
2. SSH on:
   ```bash
   sudo systemctl enable ssh
   ```
3. Turn off what a server doesn't need (if listed by `systemctl list-unit-files --type=service --state=enabled`):
   ```bash
   sudo systemctl disable --now cups.service cups-browsed.service bluetooth.service ModemManager.service
   ```
4. Reboot, then check: `systemctl is-active tailscaled` → `active`.
5. From another tailnet device: `ssh <user>@<tailscale-ip>`.

## Install Kubernetes

Single-node k3s, Helm, the helm-diff plugin and helmfile. Versions used:

| Tool | Version |
|---|---|
| k3s | `v1.36.5+k3s1` |
| Helm | `v4.3.1` |
| helm-diff | `v3.15.15` |
| helmfile | `v1.8.2` |

### 1. Remove Docker (only if installed)

1. ```bash
   sudo systemctl disable --now docker.socket docker.service containerd.service
   sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
   sudo apt autoremove -y
   sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg
   sudo gpasswd -d "$USER" docker
   sudo reboot
   ```
2. Check: `command -v docker || echo gone` → `gone`.
3. Optional, deletes the old containers and volumes for good:
   ```bash
   sudo du -sh /var/lib/docker /var/lib/containerd
   sudo rm -rf /var/lib/docker /var/lib/containerd
   ```

### 2. Kernel limits

```bash
sudo tee /etc/sysctl.d/90-kubernetes.conf >/dev/null <<'EOF'
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches    # 1024, 524288
```

### 3. Fixed node address

1. ```bash
   sudo nmcli connection add type dummy ifname k3s0 con-name k3s0 \
     ipv4.method manual ipv4.addresses 10.250.0.1/32 ipv6.method disabled connection.autoconnect yes
   sudo nmcli connection up k3s0
   ```
2. Check: `ip -4 addr show k3s0` → `inet 10.250.0.1/32`.

### 4. Keep the Kubernetes ports off the LAN

1. ```bash
   sudo mkdir -p /etc/homelab
   sudo tee /etc/homelab/k3s-lan-guard.nft >/dev/null <<'EOF'
   table inet homelab_lan_guard
   delete table inet homelab_lan_guard
   table inet homelab_lan_guard {
     chain input {
       type filter hook input priority filter - 10; policy accept;
       iifname { "lo", "tailscale0", "k3s0", "cni0", "flannel.1" } accept
       tcp dport { 6443, 10250 } drop
       udp dport 8472 drop
     }
   }
   EOF
   sudo tee /etc/systemd/system/k3s-lan-guard.service >/dev/null <<'EOF'
   [Unit]
   Description=Keep the Kubernetes ports off the LAN
   Before=k3s.service

   [Service]
   Type=oneshot
   RemainAfterExit=yes
   ExecStart=/usr/sbin/nft -f /etc/homelab/k3s-lan-guard.nft

   [Install]
   WantedBy=multi-user.target
   EOF
   sudo systemctl daemon-reload
   sudo systemctl enable --now k3s-lan-guard
   ```
2. Check: `sudo nft list table inet homelab_lan_guard` prints the rules.
3. Never `systemctl enable nftables`: its config flushes the k3s and Tailscale rules.

### 5. Let your account run kubectl and helm

1. ```bash
   sudo groupadd --system k3s-admin
   sudo usermod -aG k3s-admin "$USER"
   echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc    # zsh: ~/.zshrc
   ```
2. Log out and back in.
3. Check: `id -nG` lists `k3s-admin`; `echo $KUBECONFIG` → `/etc/rancher/k3s/k3s.yaml`.

### 6. Install k3s

1. Write the config:
   ```bash
   DOMAIN="$(tailscale status --json | jq -r '.Self.DNSName | rtrimstr(".")')"
   TSIP="$(tailscale ip -4)"
   sudo mkdir -p /etc/rancher/k3s
   sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
   node-ip: 10.250.0.1
   flannel-iface: k3s0
   write-kubeconfig-mode: "0640"
   write-kubeconfig-group: k3s-admin
   secrets-encryption: true
   disable:
     - traefik
     - servicelb
   tls-san:
     - ${DOMAIN}
     - ${TSIP}
   EOF
   sudo cat /etc/rancher/k3s/config.yaml
   ```
2. Install:
   ```bash
   cd "$(mktemp -d)"
   curl -fsSL https://get.k3s.io -o k3s-install.sh
   sudo INSTALL_K3S_VERSION='v1.36.5+k3s1' sh k3s-install.sh
   ```
3. Check, after a minute:
   ```bash
   kubectl get nodes -o wide          # Ready, INTERNAL-IP 10.250.0.1, v1.36.5+k3s1
   kubectl get pods -A                # coredns, local-path-provisioner, metrics-server Running; no traefik, no svclb
   sudo k3s secrets-encrypt status    # Encryption Status: Enabled
   kubectl top node                   # CPU and memory figures
   ```

### 7. Docker Hub login for image pulls

1. On hub.docker.com: **Account settings → Personal access tokens → Generate**, access **Read-only**. Copy it.
2. `sudo nano /etc/rancher/k3s/registries.yaml`, paste, replace `<token>`:
   ```yaml
   mirrors:
     docker.io:
       endpoint:
         - "https://index.docker.io/v2"
   configs:
     "https://index.docker.io/v2":
       auth:
         username: toufik142
         password: <token>
   ```
3. ```bash
   sudo chmod 600 /etc/rancher/k3s/registries.yaml
   sudo systemctl restart k3s
   ```
4. Check: `sudo k3s crictl pull docker.io/library/busybox:1.36` → `Image is up to date` (a wrong token fails with `401 Unauthorized`).

### 8. Install Helm

1. ```bash
   ARCH="$(dpkg --print-architecture)"; cd "$(mktemp -d)"
   curl -fsSLO "https://get.helm.sh/helm-v4.3.1-linux-${ARCH}.tar.gz"
   curl -fsSLO "https://get.helm.sh/helm-v4.3.1-linux-${ARCH}.tar.gz.sha256sum"
   sha256sum -c "helm-v4.3.1-linux-${ARCH}.tar.gz.sha256sum"       # OK
   tar -xzf "helm-v4.3.1-linux-${ARCH}.tar.gz"
   sudo install -m 0755 "linux-${ARCH}/helm" /usr/local/bin/helm
   ```
2. Check: `helm version` → `v4.3.1`; `helm list -A` → column headers, no error.

### 9. Install the helm-diff plugin

1. Get the signing key:
   ```bash
   mkdir -p ~/.config/helm/keyrings
   curl -fsSL https://github.com/databus23.gpg | gpg --dearmor > ~/.config/helm/keyrings/databus23.gpg
   gpg --show-keys --with-fingerprint ~/.config/helm/keyrings/databus23.gpg
   ```
2. The fingerprint must be `C564 5EF4 7482 257A 1F80  6D2B EA17 A2A2 06AF F8CD`. Stop if it isn't.
3. ```bash
   ARCH="$(dpkg --print-architecture)"
   helm plugin install "https://github.com/databus23/helm-diff/releases/download/v3.15.15/helm-diff-linux-${ARCH}.tgz" \
     --keyring ~/.config/helm/keyrings/databus23.gpg
   ```
4. Check: output has `Plugin Hash Verified`; `helm plugin list` → `diff 3.15.15`.

### 10. Install helmfile

1. ```bash
   ARCH="$(dpkg --print-architecture)"; cd "$(mktemp -d)"
   curl -fsSLO "https://github.com/helmfile/helmfile/releases/download/v1.8.2/helmfile_1.8.2_linux_${ARCH}.tar.gz"
   curl -fsSLO "https://github.com/helmfile/helmfile/releases/download/v1.8.2/helmfile_1.8.2_checksums.txt"
   sha256sum -c --ignore-missing helmfile_1.8.2_checksums.txt    # OK
   tar -xzf "helmfile_1.8.2_linux_${ARCH}.tar.gz" helmfile
   sudo install -m 0755 helmfile /usr/local/bin/helmfile
   ```
2. Check: `helmfile version` → `1.8.2`.

### 11. Check the cluster

1. Pods reach the API and the internet:
   ```bash
   kubectl run nettest --rm -i --restart=Never --image=curlimages/curl:8.11.1 -- sh -c \
     'curl -sk -o /dev/null -w "api %{http_code}\n" https://kubernetes.default.svc/version;
      curl -s  -o /dev/null -w "internet %{http_code}\n" https://integrate.api.nvidia.com/v1/models'
   ```
   → `api 401` and `internet 200`.
2. From another device on the home network:
   - `nc -vz -w 3 <lan-ip> 6443` → times out
   - `nc -vz -w 3 <tailscale-ip> 6443` → succeeded
3. `sudo reboot`; after two minutes: `systemctl is-active k3s k3s-lan-guard` → `active` twice, `kubectl get nodes` → `Ready`.
4. Unplug the Ethernet cable, `sudo systemctl restart k3s`, wait a minute:
   - `kubectl get nodes -o wide` → `Ready`, `10.250.0.1`
   - the nettest of step 1 → `internet 200`
   - plug the cable back.

### Upgrade k3s

1. Pick the next version from [update.k3s.io/v1-release/channels](https://update.k3s.io/v1-release/channels) (`stable`); go up one minor version at a time.
2. ```bash
   cd "$(mktemp -d)"
   curl -fsSL https://get.k3s.io -o k3s-install.sh
   sudo INSTALL_K3S_VERSION='<version>' sh k3s-install.sh
   ```
3. Check: `kubectl get nodes` → `Ready`, new version.
4. Update the version table above.

### Upgrade Helm, helm-diff or helmfile

1. Helm or helmfile: repeat its install step with the new version in every URL.
2. helm-diff:
   ```bash
   helm plugin uninstall diff
   ```
   then step 3 of [Install the helm-diff plugin](#9-install-the-helm-diff-plugin) with the new version.
3. Update the version table above.

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

   OTLP_URL="http://<tailscale-ip>:4318/v1/metrics"   # the OTel Collector
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
3. Test it once (~30 s):
   ```bash
   sudo internet-speedtest      # Sent to Grafana: <time>,<down>,<up>,<ping>,<jitter>,<loss>
   ```
   Until the OTel Collector runs, it prints `Stack not reachable, saved to /var/log/internet-speedtest.csv only`.
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

- [ ] `sudo reboot`, don't log in, close the lid. After 5 minutes, from a phone on mobile data with Tailscale: `ssh <user>@<tailscale-ip>` works.
- [ ] `systemctl is-active tailscaled k3s k3s-lan-guard` → `active` three times; `kubectl get nodes` → `Ready`.
- [ ] Unplug the Ethernet cable for 1 minute: still reachable, `kubectl get nodes` → `Ready`. Plug it back: `ip route show default` uses Ethernet.
- [ ] `sudo systemctl stop tailscaled`, wait 5 minutes: `journalctl -t tailscale-watchdog` shows "Restarting tailscaled", `tailscale status` works.
- [ ] `echo c | sudo tee /proc/sysrq-trigger`: the laptop reboots by itself within a minute, Tailscale is back, `kubectl get nodes` → `Ready`.
- [ ] Unplug the charger for 2 minutes: the laptop keeps running.

## Undo the server setup

```bash
# Sleep and lid
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo rm -f /etc/systemd/logind.conf.d/server.conf

# Desktop
sudo systemctl set-default graphical.target

# Kubernetes (deletes every pod and volume)
/usr/local/bin/k3s-uninstall.sh
sudo systemctl disable --now k3s-lan-guard
sudo rm -f /etc/systemd/system/k3s-lan-guard.service /etc/sysctl.d/90-kubernetes.conf
sudo rm -rf /etc/homelab /etc/rancher
sudo nmcli connection delete k3s0
sudo rm -f /usr/local/bin/helm /usr/local/bin/helmfile
rm -rf ~/.config/helm ~/.local/share/helm ~/.cache/helm
sudo groupdel k3s-admin

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

---

## Set up GitHub

Once. Charts and images must be public, so the server pulls them without a login.

**kube-charts (on your Mac)**
1. On github.com: **New repository** `kube-charts`, **Public**, nothing else.
2. ```bash
   cd ~/SandBox/kube-charts
   git init -b main
   git add .
   git commit -m "feat: homelab charts"
   git remote add origin git@github.com:s-toufik/kube-charts.git
   git push -u origin main
   ```
3. **Actions → Charts**: CHECK and PUBLISH are green.
4. [github.com/s-toufik?tab=packages](https://github.com/s-toufik?tab=packages) → `charts/app` → **Package settings → Change visibility → Public**. Same for `charts/pg-cluster`.
5. Check on the server: `helm show chart oci://ghcr.io/s-toufik/charts/app --version 0.1.0` → `name: app`.

**Each app repository (homelab-ui first)**
1. **Settings → Environments → production → Deployment branches and tags**: if it is restricted, **Add deployment branch or tag rule** → **Tag** `v*`.
2. Merge the release to `main`, then tag it (on your Mac, in the app repository):
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. **Actions**: PUBLISH and CHART are green.
4. Packages → `charts/homelab-ui` → **Change visibility → Public**.
5. Check on the server: `helm show chart oci://ghcr.io/s-toufik/charts/homelab-ui --version 1.0.0` → `name: homelab-ui`.

## First deploy

1. Get the repository:
   ```bash
   git clone git@github.com:s-toufik/homelab-infra.git && cd homelab-infra
   git switch feature/kube
   ```
2. Write this server's name and address:
   - `make local`
   - raw: `./scripts/local.sh`
3. Create the passwords and keys:
   - `make secrets`
   - raw: `./scripts/secrets.sh`
4. Check:
   - `make validate`
   - raw: `./scripts/validate.sh`
5. Deploy everything (the first time ~10 minutes: images download, PostgreSQL starts):
   - `make apply`
   - raw: `helmfile apply`
6. Create your account (email, names, password twice):
   - `make user-add ACCOUNT=<name>`
   - raw: `./scripts/users.sh add <name>`
7. Make it admin:
   - `make user-admin ACCOUNT=<name>`
   - raw: `./scripts/users.sh admin <name>`
8. Verify, every line ✓:
   - `make verify`
   - raw: `./scripts/verify.sh`
9. Open `https://<HOMELAB_DOMAIN>/` on a Tailscale device and sign in.

## Deploy

**See what would change**
- `make diff` (or `R=<release>`, or `G=<group>`)
- raw: `helmfile diff` (`helmfile -l name=<release> diff`, `helmfile -l group=<group> diff`)

**Apply it**
- everything (the release train): `make apply` — raw: `helmfile apply`
- one release: `make apply R=<release>` — raw: `helmfile -l name=<release> apply`
- one group (`platform`, `repository`, `gateway`, `apps`): `make apply G=<group>` — raw: `helmfile -l group=<group> apply`

**Re-run a release's deploy jobs without a change** (e.g. Keycloak's realm sync)
- `make sync R=<release>`
- raw: `helmfile -l name=<release> sync`

**After editing a config file** (`gateway/caddy/Caddyfile`, `gateway/keycloak/sync.sh`, any `values.yaml.gotmpl`)
1. `make validate`
2. `make diff R=<release>`
3. `make apply R=<release>` (the pod restarts with the new file)

## Release an app

**On your Mac, in the app repository**
1. Merge to `main` what goes in the release.
2. Tag it:
   ```bash
   git tag v<X.Y.Z>
   git push origin v<X.Y.Z>
   ```
3. **Actions**: PUBLISH (image `toufik142/<app>:<X.Y.Z>`) and CHART (`oci://ghcr.io/s-toufik/charts/<app>:<X.Y.Z>`) are green.

**In homelab-infra**
4. Set the version in `environments/versions.yaml` (e.g. `apps.homelabUi: <X.Y.Z>`), commit, push.

**On the server**
5. `git pull`
6. `make diff R=<release>` — raw: `helmfile -l name=<release> diff`
7. `make apply R=<release>` — raw: `helmfile -l name=<release> apply`
8. `make status` → the pod is `Running`; open the app.

**A release train** (several apps at once)
1. Steps 1–3 in each app repository.
2. Every new version in `environments/versions.yaml`, one commit.
3. On the server: `git pull`, `make diff`, `make apply`.

## Roll back

**Right away**
1. `make releases` — raw: `helm list -A` (current revision of each release)
2. `make rollback R=<release>` — raw: `helm -n homelab rollback <release>`
3. In `environments/versions.yaml`, set the previous version back, commit, push (otherwise the next `make apply` upgrades again).

**To a chosen version**
1. That version in `environments/versions.yaml`.
2. `make apply R=<release>`

## Change a chart

**On your Mac, in kube-charts**
1. Edit the chart; raise its `version` in `charts/<chart>/Chart.yaml` (e.g. `0.1.0` → `0.1.1`).
2. Check:
   - `make check`
   - raw: `./scripts/check.sh`
3. Commit and push to `main`. **Actions → Charts**: PUBLISH is green.

**In homelab-infra**
4. The new version in `environments/versions.yaml` (`charts.app` or `charts.pgCluster`), commit, push.

**On the server**
5. `git pull`, `make diff`, `make apply`.

Apps get the new `app` chart with their next release (their CI builds on the latest one).

## Check the homelab

- Pods: `make status` — raw: `kubectl -n homelab get pods -o wide`
- Everything, every line ✓: `make verify` — raw: `./scripts/verify.sh`
- Releases and versions: `make releases` — raw: `helm list -A`
- Logs: `make logs R=<release>` — raw: `kubectl -n homelab logs -f --tail=200 -l app.kubernetes.io/instance=<release> --all-containers --prefix` (PostgreSQL: `-l cnpg.io/cluster=postgres`)
- Why a pod doesn't start: `make events` — raw: `kubectl -n homelab get events --sort-by=.lastTimestamp | tail -n 40`
- CPU and memory: `make top` — raw: `kubectl -n homelab top pods`

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
1. `make user-remove ACCOUNT=<name>` — raw: `./scripts/users.sh remove <name>`
2. Type the account name to confirm.
3. Answer whether to delete its Tasker workflows and favorites.
4. `make sessions-revoke` to end its open sessions now.

**Sign everyone out now**
- `make sessions-revoke`
- raw:
  ```bash
  ./scripts/secrets.sh rotate oauth2-proxy cookie-secret
  ./scripts/users.sh logout-all
  ```

**Sign out yourself**
- **Sign out** in homelab-ui's left sidebar, or open `https://<HOMELAB_DOMAIN>/oauth2/sign_out?rd=%2F`.

## Secrets

Kubernetes Secrets in namespace `homelab`, encrypted on disk by k3s. Never in git, never on a command line.

**Create what is missing** (safe to re-run)
- `make secrets` — raw: `./scripts/secrets.sh`

**List them** (names and keys, no values)
- `make secrets-list` — raw: `./scripts/secrets.sh list`

**Type a value yourself** (e.g. the LLM provider's API key)
1. `make secret-set SECRET=<secret> KEY=<key>` — raw: `./scripts/secrets.sh set <secret> <key>`
2. Paste the value twice (hidden). The pods using it restart.

**Rotate a generated value**
1. `make secret-rotate SECRET=<secret> KEY=<key>` — raw: `./scripts/secrets.sh rotate <secret> <key>`
2. The pods using it restart; PostgreSQL applies a new role password by itself.
3. For `oauth2-proxy/client-secret` or `grafana-oidc/client-secret`: `make sync R=keycloak`.
- Rotatable: `pg-role-postgrest/password`, `pg-role-keycloak/password`, `oauth2-proxy/client-secret`, `oauth2-proxy/cookie-secret` (signs everyone out), `grafana-oidc/client-secret`, `tasker-gateway/secret`, `llm-gateway/api-key`.
- Not rotatable (read once, when their data is created): `keycloak-admin`, `grafana-admin`, `mongodb`.

**Read one** (e.g. the LLM API key, for a script)
- `kubectl -n homelab get secret llm-gateway -o jsonpath='{.data.api-key}' | base64 -d; echo`

## Database shell

- `make psql` — raw: `kubectl -n homelab exec -it "$(kubectl -n homelab get pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o name)" -c postgres -- psql -d homelab`
- Keycloak's database: `\c keycloak` inside psql.

## Troubleshooting

**`make apply` stops at `secrets.sh check`**
1. The line above names the Secret and key.
2. `make secrets`, or `make secret-set SECRET=<secret> KEY=<key>` for a typed one.

**A pod is `CreateContainerConfigError`**
1. `kubectl -n homelab describe pod <pod> | tail -n 20` → names the missing Secret or key.
2. `make secrets`.

**A pod is `ImagePullBackOff`, or `make apply` says a chart is not found**
1. `kubectl -n homelab describe pod <pod> | tail -n 20`, or `helm show chart oci://ghcr.io/s-toufik/charts/<chart> --version <version>`.
2. The version doesn't exist (check the app's Actions run and `environments/versions.yaml`), or the package isn't public ([Set up GitHub](#set-up-github), step 4).

**The Caddy pod stays `Pending`** (`didn't have free ports`)
1. Something else holds a gateway port: `sudo ss -tlnp | grep -E ':(443|8443|3000|9090)\b'`
2. Stop it (e.g. an old Docker stack: [Install Kubernetes](#1-remove-docker-only-if-installed)).

**`https://<HOMELAB_DOMAIN>/` doesn't answer**
1. `make status` → caddy `Running`?
2. `make logs R=caddy` → certificate errors: MagicDNS and HTTPS certificates on in the Tailscale admin console; `make validate` (Tailscale's socket).

**Signing in fails (error page or endless redirect)**
1. `make logs R=oauth2-proxy`
2. Inside the cluster the Tailscale name must reach Caddy: `kubectl -n homelab exec deploy/caddy -- wget -qO- https://<HOMELAB_DOMAIN>:8443/realms/homelab/.well-known/openid-configuration` → JSON. If not: `kubectl -n kube-system get configmap coredns-custom -o yaml` and `make apply R=caddy`.
3. `kubectl -n homelab logs job/keycloak-sync` → `keycloak sync done`; otherwise `make sync R=keycloak`.

**PostgreSQL isn't Ready**
1. `kubectl -n homelab get clusters.postgresql.cnpg.io postgres` → STATUS.
2. `make logs R=postgres`
3. Roles: `kubectl -n homelab get clusters.postgresql.cnpg.io postgres -o jsonpath='{.status.managedRolesStatus}'; echo`

**`another operation (install/upgrade/rollback) is in progress`**
1. `helm -n homelab history <release>`
2. `make rollback R=<release>`

## Reset the homelab

Deletes all data: databases, accounts, Secrets, volumes. The operators (`cnpg`, `reloader`) stay.

1. `kubectl delete namespace homelab` (waits until everything in it is gone)
2. `kubectl -n kube-system delete configmap coredns-custom`
3. `kubectl get pv` → nothing left from `homelab`.
4. Follow [First deploy](#first-deploy) from step 3.

## Every make command

`make help` prints this list on the server.

| make | Raw command |
|---|---|
| `make local` | `./scripts/local.sh` |
| `make secrets` | `./scripts/secrets.sh` |
| `make secrets-list` | `./scripts/secrets.sh list` |
| `make secret-set SECRET=… KEY=…` | `./scripts/secrets.sh set <secret> <key>` |
| `make secret-rotate SECRET=… KEY=…` | `./scripts/secrets.sh rotate <secret> <key>` |
| `make validate` | `./scripts/validate.sh` |
| `make diff [R=…\|G=…]` | `helmfile [-l name=<release>\|-l group=<group>] diff` |
| `make apply [R=…\|G=…]` | `helmfile [-l name=<release>\|-l group=<group>] apply` |
| `make sync [R=…\|G=…]` | `helmfile [-l name=<release>\|-l group=<group>] sync` |
| `make template [R=…\|G=…]` | `helmfile [-l name=<release>\|-l group=<group>] template` |
| `make releases` | `helm list -A` |
| `make rollback R=…` | `helm -n homelab rollback <release>` |
| `make status` | `kubectl -n homelab get pods -o wide` |
| `make logs R=… [TAIL=…]` | `kubectl -n homelab logs -f --tail=200 -l app.kubernetes.io/instance=<release> --all-containers --prefix` |
| `make events` | `kubectl -n homelab get events --sort-by=.lastTimestamp \| tail -n 40` |
| `make top` | `kubectl -n homelab top pods` |
| `make verify` | `./scripts/verify.sh` |
| `make users` | `./scripts/users.sh list` |
| `make user-add ACCOUNT=…` | `./scripts/users.sh add <name>` |
| `make user-password ACCOUNT=…` | `./scripts/users.sh password <name>` |
| `make user-admin ACCOUNT=…` | `./scripts/users.sh admin <name>` |
| `make user-unadmin ACCOUNT=…` | `./scripts/users.sh unadmin <name>` |
| `make user-disable ACCOUNT=…` | `./scripts/users.sh disable <name>` |
| `make user-enable ACCOUNT=…` | `./scripts/users.sh enable <name>` |
| `make user-unlock ACCOUNT=…` | `./scripts/users.sh unlock <name>` |
| `make user-remove ACCOUNT=…` | `./scripts/users.sh remove <name>` |
| `make sessions-revoke` | `./scripts/secrets.sh rotate oauth2-proxy cookie-secret && ./scripts/users.sh logout-all` |
| `make sh R=…` | `kubectl -n homelab exec -it deploy/<release> -- sh` |
| `make psql` | `kubectl -n homelab exec -it <postgres primary pod> -c postgres -- psql -d homelab` |
| `make destroy` | `helmfile destroy` |
