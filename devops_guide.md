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
[Database shells](#database-shells) ·
[Database migrations](#database-migrations) ·
[Backups and restores](#backups-and-restores) ·
[Observability](#observability) ·
[LLM and agent](#llm-and-agent) ·
[Kafka](#kafka) ·
[Add an app](#add-an-app) ·
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
   RuntimeDirectoryPreserve=restart
   EOF
   sudo systemctl daemon-reload
   ```
   `RuntimeDirectoryPreserve=restart` keeps the folder `/run/tailscale` when tailscaled restarts. Caddy mounts that folder to reach Tailscale's socket and get its certificate; a new folder would leave Caddy on the old one.
2. SSH on:
   ```bash
   sudo systemctl enable ssh
   ```
3. Turn off what a server doesn't need (if listed by `systemctl list-unit-files --type=service --state=enabled`):
   ```bash
   sudo systemctl disable --now cups.service cups-browsed.service bluetooth.service ModemManager.service
   ```
4. Reboot, then check: `systemctl is-active tailscaled` → `active`, and `systemctl show tailscaled -p RuntimeDirectoryPreserve` → `RuntimeDirectoryPreserve=restart`.
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
3. If `~/.docker/config.json` exists, drop its credential helper (Helm reads this file to pull charts):
   ```bash
   jq 'del(.credsStore)' ~/.docker/config.json > ~/.docker/config.json.new && mv ~/.docker/config.json.new ~/.docker/config.json
   ```
4. Optional, deletes the old containers and volumes for good:
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
       ip daddr 10.250.0.1 drop
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
4. On a server set up before the `ip daddr 10.250.0.1 drop` line existed: add it under `udp dport 8472 drop` in `/etc/homelab/k3s-lan-guard.nft` (`sudo nano`), then
   ```bash
   sudo systemctl restart k3s-lan-guard
   sudo nft list table inet homelab_lan_guard    # shows ip daddr 10.250.0.1 drop
   ```

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
   ROUTER="$(ip -4 route show default | awk '{print $3; exit}')"
   sudo mkdir -p /etc/rancher/k3s
   echo "nameserver ${ROUTER}" | sudo tee /etc/rancher/k3s/resolv.conf
   sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<EOF
   node-ip: 10.250.0.1
   flannel-iface: k3s0
   write-kubeconfig-mode: "0640"
   write-kubeconfig-group: k3s-admin
   secrets-encryption: true
   resolv-conf: /etc/rancher/k3s/resolv.conf
   disable:
     - traefik
     - servicelb
   tls-san:
     - ${DOMAIN}
     - ${TSIP}
   EOF
   sudo cat /etc/rancher/k3s/config.yaml
   ```
   → `nameserver <router-ip>`, then the config.
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
- [ ] Grafana's **Server Health** dashboard shows temperatures.
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

**Each app repository: homelab-ui, agent-toolbox, agent-runtime**
1. **Settings → Environments → production → Deployment branches and tags**: if it is restricted, **Add deployment branch or tag rule** → **Tag** `v*`.
2. Merge the release to `main`, then tag it (on your Mac, in the app repository):
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```
3. **Actions**: PUBLISH and CHART are green.
4. Packages → `charts/<app>` → **Change visibility → Public**.
5. Check on the server: `helm show chart oci://ghcr.io/s-toufik/charts/<app> --version 1.0.0` → `name: <app>`.

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
4. Type NVIDIA's API key (`nvapi-…`), for the agent's NVIDIA models; the homelab's own models need none:
   - `make secret-set SECRET=agent-runtime KEY=llm-api-key`
   - raw: `./scripts/secrets.sh set agent-runtime llm-api-key`
5. Create the backups folder (root only):
   ```bash
   sudo install -d -m 0700 /var/backups/homelab
   ```
6. Check:
   - `make validate`
   - raw: `./scripts/validate.sh`
7. Deploy everything (the first time ~10 minutes: images download, PostgreSQL starts):
   - `make apply`
   - raw: `helmfile apply`
8. Create your account (email, names, password twice):
   - `make user-add ACCOUNT=<name>`
   - raw: `./scripts/users.sh add <name>`
9. Make it admin:
   - `make user-admin ACCOUNT=<name>`
   - raw: `./scripts/users.sh admin <name>`
10. Verify, every line ✓:
   - `make verify`
   - raw: `./scripts/verify.sh`
11. Open `https://<HOMELAB_DOMAIN>/` on a Tailscale device and sign in.

## Deploy

**See what would change**
- `make diff` (or `R=<release>`, or `G=<group>`)
- raw: `helmfile diff` (`helmfile -l name=<release> diff`, `helmfile -l group=<group> diff`)

**Apply it**
- everything (the release train): `make apply` — raw: `helmfile apply`
- one release: `make apply R=<release>` — raw: `helmfile -l name=<release> apply`
- one group (`platform`, `repository`, `message-broker`, `observability`, `gateway`, `llm`, `apps`): `make apply G=<group>` — raw: `helmfile -l group=<group> apply`

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
3. **Actions**: RELEASE TARGET says `release`; PUBLISH (images `toufik142/<app>:<X.Y.Z>` and `:latest`) and CHART (`oci://ghcr.io/s-toufik/charts/<app>:<X.Y.Z>`) are green.

**In homelab-infra**
4. Set the version in `environments/versions.yaml` (`apps.homelabUi`, `apps.agentToolbox` or `apps.agentRuntime`), commit, push.

**On the server**
5. `git pull`
6. `make diff R=<release>` — raw: `helmfile -l name=<release> diff`
7. `make apply R=<release>` — raw: `helmfile -l name=<release> apply`
8. `make status` → the pod is `Running`; open the app.

**A pre-release image** (tried by hand, never deployed)
1. `git switch develop && git pull`
2. `git tag v<X.Y.Z>-rc.<N>`
3. `git push origin v<X.Y.Z>-rc.<N>`
4. **Actions**: RELEASE TARGET says `prerelease`; PUBLISH (images `toufik142/<app>:<X.Y.Z>-rc.<N>` and `:dev`) is green; no CHART.

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

- Pods: `make status` (or `make ps`) — raw: `kubectl -n homelab get pods -o wide`
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
- What it opens: homelab-ui's Kubernetes page, Headlamp (`:4466`), Kafka changes (topics, messages), unloading a model, Grafana's Admin role.

**Block an account for a while**
1. `make user-disable ACCOUNT=<name>` — raw: `./scripts/users.sh disable <name>`
2. To end its open sessions now too: `make sessions-revoke`.
3. Later: `make user-enable ACCOUNT=<name>` — raw: `./scripts/users.sh enable <name>`

**Unlock after too many wrong passwords**
- `make user-unlock ACCOUNT=<name>` — raw: `./scripts/users.sh unlock <name>`

**Remove an account**
1. `make backup` (to keep its Tasker data restorable).
2. `make user-remove ACCOUNT=<name>` — raw: `./scripts/users.sh remove <name>`
3. Type the account name to confirm.
4. Answer whether to delete its Tasker workflows and favorites.
5. `make sessions-revoke` to end its open sessions now.

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

**Show their values** (every password and key, PostgreSQL's included)
- `make show-secrets` — raw: `./scripts/secrets.sh show`

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

## Database shells

- PostgreSQL: `make psql` — raw: `kubectl -n homelab exec -it "$(kubectl -n homelab get pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o name)" -c postgres -- psql -d homelab`
- Keycloak's database: `\c keycloak` inside psql.
- MongoDB: `make mongosh` — raw: `kubectl -n homelab exec -it mongodb-0 -- sh -c 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin'`

## Database migrations

**Add a migration** (on your Mac, in homelab-infra)
1. `make migration-new NAME=<what_it_does>` — raw: create `repository/db-migrate/migrations/<next number>_<what_it_does>.sql` with `-- migrate:up` and `-- migrate:down`
2. Write the up and down SQL. If PostgREST serves what it changes, end `migrate:up` with `NOTIFY pgrst, 'reload schema';`.
3. Commit, push.

**Apply it** (on the server)
1. `git pull`
2. `make validate` → the file has both sections.
3. `make migrate`
   - raw:
     ```bash
     helmfile -l name=db-migrate sync
     kubectl -n homelab exec "$(kubectl -n homelab get pod -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o name)" -c postgres -- psql -d homelab -qc "NOTIFY pgrst, 'reload schema'"
     ```
4. `make migrate-status` — raw: `./scripts/dbmate.sh status` → every file `[X]`.

**Undo the latest**
1. `make migrate-rollback`, type `rollback` — raw: `./scripts/dbmate.sh rollback`
2. Delete or fix the file, commit, push (otherwise the next deploy applies it again).

## Backups and restores

Every night at 03:00 (`backups` in `environments/default.yaml`): PostgreSQL (databases `homelab` and `keycloak`) and MongoDB into `/var/backups/homelab`, kept 14 days.

**List them**
- `make backups` — raw: `./scripts/backups.sh list`

**Back up now** (e.g. before an upgrade)
- `make backup` — raw: `./scripts/backups.sh now`

**Copy them off the server** (on your Mac)
```bash
ssh -t <user>@<HOMELAB_DOMAIN> 'sudo tar -C /var/backups -czf - homelab' > homelab-backups-$(date +%F).tar.gz
```

**Restore PostgreSQL** (replaces the database)
1. `make backups` → the file, e.g. `/var/backups/homelab/postgres/homelab_2026-11-03_0300.dump` (or `keycloak_…`).
2. `make restore-postgres FILE=<file>`, type `restore` — raw: `./scripts/backups.sh restore-postgres <file>`
3. For `keycloak_…`: `kubectl -n homelab rollout restart deploy/keycloak`.

**Restore MongoDB** (replaces its data)
1. `make backups` → the file, e.g. `/var/backups/homelab/mongodb/mongodb_2026-11-03_0300.archive`.
2. `make restore-mongo FILE=<file>`, type `restore` — raw: `./scripts/backups.sh restore-mongo <file>`

**Change the schedule or how long they are kept**
1. `backups.schedule` / `backups.keepDays` in `environments/default.yaml`.
2. `make apply R=backups`

## Observability

**Dashboards**
- `https://<HOMELAB_DOMAIN>:3000` → **Dashboards → Homelab**: Homelab Overview, Server Health, LLM (llama.cpp).

**Search the logs**
- Grafana → **Explore** → Loki → `{namespace="homelab", service_name="<release>"}`.

**See what Prometheus scrapes**
- `make targets` — raw: `kubectl -n homelab exec deploy/caddy -c caddy -- wget -q -O - http://prometheus:9090/api/v1/targets`
- or `https://<HOMELAB_DOMAIN>:9090/targets`

**Scrape a new service**
- In its values: `metrics: { port: <port>, path: /metrics }`, then `make apply R=<release>`; Prometheus finds it within a minute.

**Change a dashboard**
1. Edit it in Grafana, **Save**; **Export → Export as JSON**.
2. Replace the file in `observability/grafana/dashboards/`, commit, push.
3. On the server: `git pull`, `make apply R=grafana`.

**Change how long metrics are kept**
1. `prometheus.retentionTime` / `retentionSize` in `environments/default.yaml`.
2. `make apply R=prometheus`

## LLM and agent

**Chat**
- homelab-ui → **Agent**.

**Call the agent API** (from a tailnet device)
- In a browser, signed in: `https://<HOMELAB_DOMAIN>:8100/docs`
- From Postman or a script: `http://<HOMELAB_DOMAIN>:8000` (plain HTTP, no sign-in)

**Connect an MCP client to agent-toolbox** (from a tailnet device)
- `http://<HOMELAB_DOMAIN>:8001/mcp`
- With the short MagicDNS name, add it to `TOOLBOX_EXTRA_ALLOWED_HOSTS` in agent-toolbox's `devops/helm/values.yml` and release it.

**List and try the tools in the browser**
- `https://<HOMELAB_DOMAIN>:6274` (MCP Inspector, signed in) → **Connect** → **Tools → List Tools**.

**The agent's model providers**
The agent offers the homelab's models (`http://llm:8080/v1`, set in `apps/agent-runtime/values.yaml.gotmpl`) and NVIDIA's (`https://integrate.api.nvidia.com/v1`, in the app's own `devops/helm/values.yml`), side by side in the model list.
1. NVIDIA's key: `make secret-set SECRET=agent-runtime KEY=llm-api-key` — raw: `./scripts/secrets.sh set agent-runtime llm-api-key`
2. Leave out the homelab's models: remove `HOMELAB_LLM_BASE_URL` from `apps/agent-runtime/values.yaml.gotmpl`.
3. `make apply R=agent-runtime` — raw: `helmfile -l name=agent-runtime apply`
4. Check: `make logs R=agent-runtime` → no `Model provider '…' has no URL` line for a provider you want.

**The local LLM**
- Up, and its models: `make llm-status` — raw: `kubectl -n homelab exec deploy/caddy -c caddy -- wget -q -O - http://llm:8080/v1/models`
- Loaded right now: `make llm-running` — raw: `LLM_GATEWAY_API_KEY=… python3 llm/llm/test.py running https://<HOMELAB_DOMAIN>:8090`
- Ask: `make llm-ask [M=<model>] [Q="…"]` — raw: `LLM_GATEWAY_API_KEY=… python3 llm/llm/test.py ask https://<HOMELAB_DOMAIN>:8090 <model> "<question>"`
- Model names: `make llm-models` — raw: `./scripts/download_models.sh --list`
- Download before first use: `make llm-download MODELS="<model> …"` (or `MODELS=--all`) — raw: `./scripts/download_models.sh <model> …`
- Stop it (frees its memory): `make llm-down` — raw: `kubectl -n homelab scale deploy/llm --replicas=0`; start it: `make llm-up` — raw: `kubectl -n homelab scale deploy/llm --replicas=1`
- Change a model: `llm/llm/config.yml`, then `make apply R=llm`.
- The API key for scripts: `kubectl -n homelab get secret llm-gateway -o jsonpath='{.data.api-key}' | base64 -d; echo`

**Give the toolbox Grafana, MongoDB and PostgreSQL** (their MCP servers, first time)
1. In Grafana (`https://<HOMELAB_DOMAIN>:3000`, as admin): **Administration → Users and access → Service accounts → Add service account**, name `mcp`, role **Viewer** (**Editor** to let it write) → **Add service account token** → copy it.
2. `make secret-set SECRET=grafana-mcp KEY=token` — raw: `./scripts/secrets.sh set grafana-mcp token`. Paste the token twice.
3. `make secrets` — raw: `./scripts/secrets.sh`. Creates `mongodb-mcp` and `pg-role-mcp`.
4. `make apply R=postgres` — raw: `helmfile -l name=postgres apply`. Creates the role `mcp`.
5. `make apply R=mongodb` — raw: `helmfile -l name=mongodb apply`. Its job prints `user mcp created: readAnyDatabase`.
6. `make apply G=llm` — raw: `helmfile -l group=llm apply`. Starts grafana-mcp, mongodb-mcp, postgres-mcp.
7. `make apply R=agent-toolbox` — raw: `helmfile -l name=agent-toolbox apply` (a version with external MCP tools, `apps.agentToolbox` in `environments/versions.yaml`).
8. `make verify` — raw: `./scripts/verify.sh`. `agent-toolbox offers grafana_search_dashboards`, `mongodb_find`, `postgres_execute_sql` are ✓.

**Let an MCP server write, or take it back**
1. `mcp.<grafana|mongodb|postgres>.write: true` (or `false`) in `environments/default.yaml`; commit, push, `git pull` on the server.
2. PostgreSQL: `make apply R=postgres`, then `make apply R=postgres-mcp`. MongoDB: `make apply R=mongodb`, then `make apply R=mongodb-mcp`. Grafana: give the `mcp` service account the role Editor (or Viewer) in Grafana, then `make apply R=grafana-mcp`.
3. Nothing to restart: within a minute the toolbox re-reads the server's tools, and the agent the toolbox's, so the write tools appear (or go). To see it at once: `make restart R=agent-toolbox` — raw: `kubectl -n homelab rollout restart deploy/agent-toolbox`.

**Choose Grafana's MCP tools**
1. `mcp.grafana.categories` in `environments/default.yaml` (comma-separated: `search`, `datasource`, `dashboard`, `prometheus`, `loki`, `alerting`, `navigation`, …).
2. `make apply R=grafana-mcp` — raw: `helmfile -l name=grafana-mcp apply`. Within a minute the toolbox and the agent follow.

**Rotate the MCP passwords**
- `make secret-rotate SECRET=pg-role-mcp KEY=password` (PostgreSQL applies it itself).
- `make secret-rotate SECRET=mongodb-mcp KEY=password`, then `make sync R=mongodb` (raw: `helmfile -l name=mongodb sync`): its job sets the new password.

**Update the MCP Inspector**
1. `images.mcpInspector` in `environments/versions.yaml` ([its releases](https://github.com/modelcontextprotocol/inspector/releases)).
2. `make apply R=mcp-inspector`

## Kafka

- Topics: `make topics` — raw: `kubectl -n homelab exec -it kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list`
- Create one: `make topic-create TOPIC=<name> [PARTITIONS=3]` — raw: `kubectl -n homelab exec -it kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --if-not-exists --topic <name> --partitions 3 --replication-factor 1`
- Describe it: `make topic-describe TOPIC=<name>` — raw: `kubectl -n homelab exec -it kafka-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic <name>`
- Read it from the start: `make consume TOPIC=<name>` — raw: `kubectl -n homelab exec -it kafka-0 -- /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic <name> --from-beginning`
- Consumer groups and lag: `make groups` — raw: `kubectl -n homelab exec -it kafka-0 -- /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups`
- In the browser: `https://<HOMELAB_DOMAIN>:8080` (Kafka UI, signed in).
- From a tailnet device: bootstrap server `<HOMELAB_DOMAIN>:9094`.

## Add an app

**In a new repository** (start from `templates/myapi-a`)
1. `devops/docker/Dockerfile` and `devops/helm/values.yml` (port, env, the Secrets it reads, probes, resources).
2. `.github/workflows/cicd.yml`: copy agent-toolbox's, change the image name and the `chart` job's `name` and `image`.
3. GitHub: [Set up GitHub](#set-up-github) → **Each app repository** (environment rule, tag `v1.0.0`, package public).

**In homelab-infra**
4. If it reads Secrets: add them to `SPECS` in `scripts/secrets.sh`.
5. In `environments/versions.yaml`, under `apps`: `<appName>: 1.0.0`.
6. In `helmfile.yaml.gotmpl`, a release in its group:
   ```yaml
     - name: <app>
       inherit: [{ template: homelab }]
       chart: homelab/<app>
       version: {{ .Values.apps.<appName> }}
       labels: { group: apps }
   ```
7. `apps/<app>/values.yaml.gotmpl`: what this server adds (often nothing: copy `apps/homelab-ui/values.yaml.gotmpl`).
8. A web page behind the sign-in: a route in `gateway/caddy/Caddyfile` ([gateway/caddy/README.md](gateway/caddy/README.md), Adding a route or a tool).
9. Commit, push.

**On the server**
10. `git pull`, `make secrets` (if it reads Secrets), `make validate`, `make apply R=<app>`.
11. `make status` → `Running`; `make logs R=<app>`.

## Troubleshooting

**`make apply` stops at `secrets.sh check`**
1. The line above names the Secret and key.
2. `make secrets`, or `make secret-set SECRET=<secret> KEY=<key>` for a typed one.

**Warning `DNSConfigForming` … `Nameserver limits were exceeded` (CoreDNS, every minute)**
1. `grep nameserver /run/systemd/resolve/resolv.conf` → 4 lines or more (the router once per network).
2. `echo "nameserver $(ip -4 route show default | awk '{print $3; exit}')" | sudo tee /etc/rancher/k3s/resolv.conf` → `nameserver <router-ip>`.
3. `grep -q resolv-conf /etc/rancher/k3s/config.yaml || echo 'resolv-conf: /etc/rancher/k3s/resolv.conf' | sudo tee -a /etc/rancher/k3s/config.yaml`
4. `sudo systemctl restart k3s`; after a minute `kubectl get nodes` → `Ready` (pods keep running).
5. `kubectl -n kube-system rollout restart deploy/coredns` → `deployment.apps/coredns restarted`.
6. After 5 minutes, `kubectl -n kube-system get events --field-selector reason=DNSConfigForming` lists no new event; `make verify` is all ✓.
7. New router, or its address changed: redo 2, 4, 5.

**`make apply` fails with `not ready` … `context deadline exceeded`**
1. The releases after the failed one didn't run.
2. `kubectl -n homelab get pods -l app.kubernetes.io/instance=<release> -o wide` → `Pending`, `CrashLoopBackOff` or `0/1 Running`.
3. `kubectl -n homelab describe pod -l app.kubernetes.io/instance=<release> | tail -n 25` → the events: a port or volume it can't get, a failing probe.
4. `kubectl -n homelab logs deploy/<release> --tail=40` (`statefulset/<release>` for a database) → its own error.
5. Fix, commit, push; on the server `git pull`, `make sync R=<release>`, then `make apply`.

**A pod is `CreateContainerConfigError`**
1. `kubectl -n homelab describe pod <pod> | tail -n 20` → names the missing Secret or key.
2. `make secrets`.

**Pulling a chart fails with `docker-credential-desktop` (or another `docker-credential-…`) `not found`**
1. Helm reads Docker's login settings, and they name a credential helper that isn't installed.
2. Remove that setting, keeping a copy:
   ```bash
   cp ~/.docker/config.json ~/.docker/config.json.bak
   jq 'del(.credsStore)' ~/.docker/config.json.bak > ~/.docker/config.json
   ```
3. `make validate` → `Helm can read the registry logins`.

**A pod is `ImagePullBackOff`, or `make apply` says a chart is not found**
1. `kubectl -n homelab describe pod <pod> | tail -n 20`, or `helm show chart oci://ghcr.io/s-toufik/charts/<chart> --version <version>`.
2. The version doesn't exist (check the app's Actions run and `environments/versions.yaml`), or the package isn't public ([Set up GitHub](#set-up-github), step 4).

**A pod stays `Pending`** (`didn't have free ports`)
1. `make validate` → `no two pods want the same server port`; otherwise it names the port and the releases: change one of them.
2. Outside Kubernetes: `sudo ss -tlnp | grep -E ':(443|8443|3000|9090)\b'`, stop what holds it (e.g. an old Docker stack: [Install Kubernetes](#1-remove-docker-only-if-installed)).
3. An old pod of another release may hold the port: `make sync R=<that release>` replaces it.

**`https://<HOMELAB_DOMAIN>/` doesn't answer**
1. `make status` → caddy `Running`?
2. `make logs R=caddy` → certificate errors: MagicDNS and HTTPS certificates on in the Tailscale admin console; `make validate` (Tailscale's socket).

**HTTPS fails with `tlsv1 alert internal error`, and Caddy's logs say `dial unix /var/run/tailscale/tailscaled.sock: connect: connection refused`**
1. Caddy can't reach Tailscale to get its certificate: tailscaled restarted and Caddy still holds its old socket. `systemctl show tailscaled -p ActiveEnterTimestamp` is later than Caddy's start (`kubectl -n homelab get pod -l app.kubernetes.io/instance=caddy -o custom-columns=NAME:.metadata.name,START:.status.startTime`).
2. `make restart R=caddy` — raw: `kubectl -n homelab rollout restart deploy/caddy && kubectl -n homelab rollout status deploy/caddy`.
3. So it doesn't come back: `make validate` → `tailscaled keeps /run/tailscale when it restarts`; otherwise add `RuntimeDirectoryPreserve=restart` to the drop-in ([Start Tailscale and SSH at boot](#8-start-tailscale-and-ssh-at-boot), step 1), then `sudo systemctl daemon-reload`.

**Signing in fails (error page or endless redirect)**
1. `make logs R=oauth2-proxy`
2. Inside the cluster the Tailscale name must reach Caddy: `kubectl -n homelab exec deploy/caddy -- wget -qO- https://<HOMELAB_DOMAIN>:8443/realms/homelab/.well-known/openid-configuration` → JSON. If not: `kubectl -n kube-system get configmap coredns-custom -o yaml` and `make apply R=caddy`.
3. `kubectl -n homelab logs job/keycloak-sync` → `keycloak sync done`; otherwise `make sync R=keycloak`.

**PostgreSQL isn't Ready**
1. `kubectl -n homelab get clusters.postgresql.cnpg.io postgres` → STATUS.
2. `make logs R=postgres`
3. Roles: `kubectl -n homelab get clusters.postgresql.cnpg.io postgres -o jsonpath='{.status.managedRolesStatus}'; echo`

**agent-toolbox or the MCP Inspector answers `403` / `Invalid Host header`**
- The address isn't one it accepts: use `http://<HOMELAB_DOMAIN>:8001/mcp` or `http://<tailscale-ip>:8001/mcp`, or add the name to `TOOLBOX_EXTRA_ALLOWED_HOSTS` (agent-toolbox's `devops/helm/values.yml`, then a release).

**A connection to or from agent-toolbox or the MCP Inspector times out**
1. Their NetworkPolicy allows only what they need: `kubectl -n homelab get networkpolicy <release> -o yaml`.
2. Expected: agent-toolbox ← agent-runtime, MCP Inspector, Caddy, tailnet devices; agent-toolbox → DNS, OTel Collector, internet. MCP Inspector ← Caddy; → DNS, agent-toolbox, internet.
3. A new caller or target: add it in `apps/agent-toolbox/values.yaml.gotmpl` or `llm/mcp-inspector/values.yaml.gotmpl`, then `make apply R=<release>`.

**A Prometheus target is down** (`make verify`, `make targets`)
1. `make logs R=<release>` and `make status`.
2. The pod's `prometheus.io/port` must be the port its metrics are on: its values' `metrics:`.

**A backup fails, or none has run**
1. `kubectl -n homelab get cronjob,job | grep backups`
2. `kubectl -n homelab logs job/<the failed backups job>`
3. `make validate` → `/var/backups/homelab exists`.

**The `db-migrate` job fails**
1. `kubectl -n homelab logs job/db-migrate-migrate`
2. Fix the migration file, then `make migrate`.

**A release's pods are gone, and `make apply` doesn't bring them back**
1. `make apply` only upgrades releases whose files changed; something deleted by hand stays deleted.
2. `git pull` (the server may be behind), then `make sync R=<release>` — raw: `helmfile -l name=<release> sync` (re-deploys it even without a change).

**`another operation (install/upgrade/rollback) is in progress`**
1. `helm -n homelab history <release>`
2. `make rollback R=<release>`

## Reset the homelab

Deletes all data: databases, accounts, Secrets, volumes. The operators (`cnpg`, `reloader`) and the backups in `/var/backups/homelab` stay.

1. `make backup` (if anything is worth keeping)
2. `kubectl delete namespace homelab` (waits until everything in it is gone)
3. `kubectl -n kube-system delete configmap coredns-custom`
4. `kubectl get pv` → nothing left from `homelab`.
5. Follow [First deploy](#first-deploy) from step 3.

## Every make command

`make help` prints this list on the server.

| make | Raw command |
|---|---|
| `make local` | `./scripts/local.sh` |
| `make secrets` | `./scripts/secrets.sh` |
| `make secrets-list` | `./scripts/secrets.sh list` |
| `make show-secrets` | `./scripts/secrets.sh show` |
| `make secret-set SECRET=… KEY=…` | `./scripts/secrets.sh set <secret> <key>` |
| `make secret-rotate SECRET=… KEY=…` | `./scripts/secrets.sh rotate <secret> <key>` |
| `make validate` | `./scripts/validate.sh` |
| `make diff [R=…\|G=…]` | `helmfile [-l name=<release>\|-l group=<group>] diff` |
| `make apply [R=…\|G=…]` | `helmfile [-l name=<release>\|-l group=<group>] apply` |
| `make sync [R=…\|G=…]` | `helmfile [-l name=<release>\|-l group=<group>] sync` |
| `make template [R=…\|G=…]` | `helmfile [-l name=<release>\|-l group=<group>] template` |
| `make releases` | `helm list -A` |
| `make rollback R=…` | `helm -n homelab rollback <release>` |
| `make restart R=…` | `kubectl -n homelab rollout restart deploy/<release>` (or `statefulset/…`), then `kubectl -n homelab rollout status …` |
| `make status` · `make ps` | `kubectl -n homelab get pods -o wide` |
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
| `make sh R=…` | `kubectl -n homelab exec -it <release's running pod> -- sh` |
| `make psql` | `kubectl -n homelab exec -it <postgres primary pod> -c postgres -- psql -d homelab` |
| `make mongosh` | `kubectl -n homelab exec -it mongodb-0 -- sh -c 'mongosh -u … -p … --authenticationDatabase admin'` |
| `make migration-new NAME=…` | create `repository/db-migrate/migrations/<NNN>_<name>.sql` |
| `make migrate` | `helmfile -l name=db-migrate sync`, then `NOTIFY pgrst, 'reload schema'` in psql |
| `make migrate-status` | `./scripts/dbmate.sh status` |
| `make migrate-rollback` | `./scripts/dbmate.sh rollback` |
| `make topics` · `topic-create` · `topic-describe` · `consume` · `groups` | see [Kafka](#kafka) |
| `make targets` | `kubectl -n homelab exec deploy/caddy -c caddy -- wget -q -O - http://prometheus:9090/api/v1/targets` |
| `make llm-status` · `llm-running` · `llm-ask` · `llm-models` · `llm-download` · `llm-down` · `llm-up` | see [LLM and agent](#llm-and-agent) |
| `make backup` | `./scripts/backups.sh now` |
| `make backups` | `./scripts/backups.sh list` |
| `make restore-postgres FILE=…` | `./scripts/backups.sh restore-postgres <file>` |
| `make restore-mongo FILE=…` | `./scripts/backups.sh restore-mongo <file>` |
| `make destroy` | `helmfile destroy` |
