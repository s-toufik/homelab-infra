# Turn an Ubuntu laptop into an always-on homelab server

This guide turns an Ubuntu laptop into a server that:

- never sleeps, even with the lid closed
- is connected to the router by Ethernet, with Wi-Fi as a fallback
- starts **only Tailscale** at boot
- reboots by itself if it freezes, and Tailscale comes back automatically
- reports its health (temperatures, battery, uptime, reboots, network) to Grafana
- measures its internet speed every 2 hours

Follow the sections in order. Each step has a **Check** so you know it worked before moving on.

---

## Table of contents

1. [Before you start](#1-before-you-start)
2. [Install and connect Tailscale](#2-install-and-connect-tailscale)
3. [Never sleep](#3-never-sleep)
4. [Keep running with the lid closed](#4-keep-running-with-the-lid-closed)
5. [Boot without the desktop](#5-boot-without-the-desktop)
6. [Network: Ethernet (main)](#6-network-ethernet-main)
7. [Network: Wi-Fi (fallback)](#7-network-wi-fi-fallback)
8. [Start only Tailscale at boot](#8-start-only-tailscale-at-boot)
9. [Reboot automatically if the laptop freezes](#9-reboot-automatically-if-the-laptop-freezes)
10. [Battery and power cuts](#10-battery-and-power-cuts)
11. [Monitor the server in Grafana](#11-monitor-the-server-in-grafana)
12. [Get notified if the server goes offline](#12-get-notified-if-the-server-goes-offline)
13. [Monitor internet speed](#13-monitor-internet-speed)
14. [Final test](#14-final-test)
15. [Troubleshooting and undo](#15-troubleshooting-and-undo)

---

## 1. Before you start

- Do this setup **on the laptop itself** (keyboard and screen), not over SSH. Some steps restart the network or reboot.
- Plug the laptop into power.
- Every command is run in a terminal. Commands starting with `sudo` ask for your password.

Update the system first:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y curl lm-sensors
```

---

## 2. Install and connect Tailscale

Skip this section if Tailscale is already installed and logged in.

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Open the link it prints and log in.

Then, in the [Tailscale admin console](https://login.tailscale.com/admin/machines):

1. Find this laptop in **Machines**.
2. Click **⋯ → Disable key expiry**.

Without this, the laptop disconnects from your tailnet after 180 days and needs a manual login.

**Check:**

```bash
tailscale status    # the first line shows this laptop
tailscale ip -4     # note this IP, e.g. 100.80.98.112
```

---

## 3. Never sleep

Block every way the system can sleep or hibernate:

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

**Check:**

```bash
systemctl status sleep.target
```

It must say `Loaded: masked`.

---

## 4. Keep running with the lid closed

Tell the system to ignore the lid and the sleep keys:

```bash
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

This takes effect after the reboot in the next section.

**Heat:** a closed laptop cools less well. Put it on a hard surface with the vents clear, ideally on a stand. Never leave it on a bed, sofa or inside a closed cabinet.

---

## 5. Boot without the desktop

A server doesn't need the graphical desktop. Booting in text mode frees about 1 GB of RAM and stops the desktop from starting its own power management.

```bash
sudo systemctl set-default multi-user.target
sudo reboot
```

After the reboot, you get a text login prompt. Log in with your usual username and password.

**Check:**

```bash
systemctl get-default                 # multi-user.target
cat /etc/systemd/logind.conf.d/server.conf
```

Close the lid for one minute, open it: the text console is still there and `uptime` shows the laptop didn't sleep.

> To get the desktop back one day: `sudo systemctl set-default graphical.target && sudo reboot`

---

## 6. Network: Ethernet (main)

### 6.1 Plug in and find the connection

Connect the laptop to the router with the Ethernet cable, then:

```bash
nmcli device status
```

Example output:

```
DEVICE      TYPE      STATE      CONNECTION
enp3s0      ethernet  connected  Wired connection 1
wlp2s0      wifi      connected  MyWiFi
tailscale0  tun       unmanaged  --
```

Note the name in the **CONNECTION** column for `ethernet` (here `Wired connection 1`).

### 6.2 Make Ethernet always reconnect and be preferred

Replace `Wired connection 1` with your connection name:

```bash
sudo nmcli connection modify "Wired connection 1" \
  connection.autoconnect yes \
  connection.autoconnect-priority 100 \
  connection.autoconnect-retries 0 \
  ipv4.route-metric 100
```

- `autoconnect-retries 0` means "retry forever", so a router reboot never leaves the laptop offline.
- `route-metric 100` makes Ethernet win over Wi-Fi when both are connected.

### 6.3 Give the laptop a fixed IP on your router

In your router's admin page, find **DHCP reservation** (sometimes called "static lease" or "bail DHCP") and reserve the current IP for this laptop.

Doing it on the router is simpler and safer than configuring a static IP on the laptop.

### 6.4 Only if you use a USB Ethernet adapter

USB power saving can disconnect the adapter. Disable it:

```bash
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&usbcore.autosuspend=-1 /' /etc/default/grub
sudo update-grub
sudo reboot
```

**Check:**

```bash
nmcli device status          # ethernet: connected
ip route show default        # the first line uses your Ethernet device (e.g. enp3s0)
ping -c 3 1.1.1.1
```

---

## 7. Network: Wi-Fi (fallback)

Use this if there's no Ethernet, or to keep a backup connection if the cable is unplugged.

### 7.1 Connect to your Wi-Fi

```bash
nmcli device wifi list
sudo nmcli device wifi connect "YOUR_WIFI_NAME" password "YOUR_WIFI_PASSWORD"
```

### 7.2 Make it reconnect forever, as a backup to Ethernet

```bash
sudo nmcli connection modify "YOUR_WIFI_NAME" \
  connection.autoconnect yes \
  connection.autoconnect-priority 10 \
  connection.autoconnect-retries 0 \
  ipv4.route-metric 600 \
  802-11-wireless.powersave 2
```

- Priority `10` and metric `600` keep Wi-Fi as the backup when Ethernet works.
- `powersave 2` disables Wi-Fi power saving, which otherwise makes the laptop drop off the network when idle.

### 7.3 Disable Wi-Fi power saving for every network

```bash
sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf >/dev/null <<'EOF'
[connection]
wifi.powersave = 2
EOF
sudo systemctl restart NetworkManager
```

**Check:**

```bash
nmcli connection show "YOUR_WIFI_NAME" | grep -E 'autoconnect|powersave'
```

Test the fallback: unplug the Ethernet cable, wait 30 seconds, and run `tailscale status` from another device. The laptop must still be online.

---

## 8. Start only Tailscale at boot

### 8.1 Tailscale starts at boot and restarts if it crashes

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

`StartLimitIntervalSec=0` removes the limit on restart attempts, so systemd never gives up on Tailscale.

### 8.2 Docker does not start at boot

Docker (and therefore the homelab stack) stays off at boot. It starts automatically the first time you use a `docker` command or `make up`.

```bash
sudo systemctl disable docker.service containerd.service
sudo systemctl enable docker.socket
```

How it behaves:

| Moment | What runs |
|---|---|
| After boot | Tailscale only |
| You SSH in and run `make up` | Docker starts, then the stack |

The first `docker` command also restarts any container that was running before the reboot, because the stack uses `restart: unless-stopped`.

### 8.3 Check what else starts at boot

```bash
systemctl list-unit-files --type=service --state=enabled
```

Services you usually don't need on a server, and can disable if they appear:

```bash
sudo systemctl disable --now cups.service cups-browsed.service bluetooth.service ModemManager.service
```

Keep `ssh`, `NetworkManager`, `systemd-*`, `tailscaled` and `unattended-upgrades`.

### 8.4 Allow SSH through Tailscale

```bash
sudo apt install -y openssh-server
sudo systemctl enable ssh
```

From any device on your tailnet: `ssh youruser@100.80.98.112`.

**Check:** reboot, then:

```bash
systemctl is-active tailscaled     # active
systemctl is-active docker         # inactive
tailscale status
```

---

## 9. Reboot automatically if the laptop freezes

Three layers of protection:

| Problem | Protection |
|---|---|
| Kernel crash or kernel freeze | Kernel reboots itself (9.1) |
| Whole system frozen, nothing responds | Watchdog timer forces a reboot (9.2) |
| System works but Tailscale is stuck | Tailscale watchdog script restarts it, then reboots if needed (9.3) |

### 9.1 Reboot on kernel crash or freeze

```bash
sudo tee /etc/sysctl.d/99-server-autoreboot.conf >/dev/null <<'EOF'
# Reboot 10 seconds after a kernel panic
kernel.panic = 10
# Turn kernel errors and lockups into a panic (so 'kernel.panic' reboots)
kernel.panic_on_oops = 1
kernel.softlockup_panic = 1
kernel.nmi_watchdog = 1
kernel.hardlockup_panic = 1
# A process stuck for 10 minutes means the system is hung
kernel.hung_task_timeout_secs = 600
kernel.hung_task_panic = 1
EOF
sudo sysctl --system
```

**Check:**

```bash
sysctl kernel.panic kernel.softlockup_panic kernel.hung_task_panic
```

### 9.2 Watchdog: force a reboot when everything is frozen

A watchdog is a timer that reboots the laptop unless the system confirms every 30 seconds that it's alive. If the system freezes, the confirmations stop and the reboot happens.

**Step 1: find a watchdog.** Ubuntu doesn't load hardware watchdog drivers by default. Try the one for your processor:

```bash
# Intel processor:
sudo modprobe iTCO_wdt
# AMD processor:
sudo modprobe sp5100_tco

sudo wdctl
```

- If `wdctl` shows a device: keep that driver. Replace `iTCO_wdt` below with `sp5100_tco` for AMD.
  ```bash
  echo iTCO_wdt | sudo tee /etc/modules-load.d/watchdog.conf
  ```
- If `wdctl` says `No such file or directory`: use the software watchdog instead.
  ```bash
  echo softdog | sudo tee /etc/modules-load.d/watchdog.conf
  sudo modprobe softdog
  sudo wdctl        # must now show "softdog"
  ```

The hardware watchdog is better, because it still works when the kernel itself is frozen. The software one covers the other cases, and section 9.1 covers kernel freezes.

**Step 2: let systemd feed the watchdog.**

```bash
sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/watchdog.conf >/dev/null <<'EOF'
[Manager]
RuntimeWatchdogSec=30s
RebootWatchdogSec=10min
EOF
sudo systemctl daemon-reexec
```

**Check:**

```bash
sudo wdctl | grep -i timeout      # a timeout is set
systemctl show -p RuntimeWatchdogUSec
```

### 9.3 Tailscale watchdog: repair Tailscale, reboot as a last resort

Every 2 minutes this script checks Tailscale:

1. **Tailscale is connected:** nothing happens.
2. **Not connected for ~4 minutes:** it restarts Tailscale.
3. **Still not connected after ~16 minutes:** it reboots the laptop, but **only if** the internet works (so a broken router or ISP outage never causes a reboot loop), the laptop has been up for at least 30 minutes, and Tailscale isn't just logged out (a reboot can't fix that).

**Create the script:**

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

**Run it every 2 minutes:**

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

**Check:**

```bash
systemctl list-timers tailscale-watchdog.timer
sudo /usr/local/bin/tailscale-watchdog.sh && echo "script OK"
journalctl -t tailscale-watchdog -n 20     # its log (empty while all is fine)
```

### 9.4 Keep logs across reboots

So you can see what happened before a crash:

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
```

After an unexpected reboot, read the end of the previous boot's log:

```bash
journalctl -b -1 -e
```

### 9.5 Automatic security updates, with a planned reboot

```bash
sudo apt install -y unattended-upgrades
sudo tee /etc/apt/apt.conf.d/52server-reboot >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF
```

Updates that need a reboot now reboot the laptop at 04:00 instead of waiting forever.

---

## 10. Battery and power cuts

### 10.1 Limit the battery charge to 80%

A laptop plugged in 24/7 at 100% wears its battery fast and can make it swell, which is dangerous. Check whether the laptop supports a charge limit:

```bash
ls /sys/class/power_supply/BAT*/charge_control_end_threshold
```

**If the file exists**, set the limit at every boot:

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
```

**Check:**

```bash
cat /sys/class/power_supply/BAT*/charge_control_end_threshold    # 80
```

**If the file doesn't exist**, look for "Battery charge limit" or "Battery health" in the BIOS (next step) or in the manufacturer's tool.

The battery then acts as a small UPS: the laptop keeps running during short power cuts.

### 10.2 BIOS settings

Reboot and enter the BIOS (press **F2**, **F10**, **F12** or **Del** during startup, depending on the brand). Look for:

| Setting | Set to | Why |
|---|---|---|
| **Power on AC** / **AC Power Recovery** / **Wake on AC** | Enabled | After a long power cut that empties the battery, the laptop starts again when power returns |
| **Battery charge limit** | 80% (if 10.1 didn't work) | Protects the battery |
| **Wake on LAN** | Enabled (optional) | Lets you power it on from another machine on the LAN |

Not every laptop has these options.

**Check the temperatures now** that the laptop runs closed and constantly:

```bash
sensors
```

CPU temperature should stay below about **85 °C** under load.

---

## 11. Monitor the server in Grafana

The homelab stack already collects the server's health through Alloy (see `alloy/config.alloy`): CPU, memory, disk, **temperatures**, **fans**, **battery**, uptime and network interfaces. You only need to add panels.

> Monitoring works only while the homelab stack is running (`make up`). It can't tell you the server is off, because Grafana runs on the same laptop. For that, see [section 12](#12-get-notified-if-the-server-goes-offline).

### 11.1 Check the sensors are visible

1. Open Grafana: `http://<tailscale-ip>:3000`
2. Go to **Explore**, select **Prometheus**, and run `node_hwmon_temp_celsius`.

If you get results, the temperatures are collected. If not, run `sensors` on the laptop: if it shows nothing either, run `sudo sensors-detect --auto` and reboot.

### 11.2 Create the dashboard

1. **Dashboards → New → New dashboard → Add visualization → Prometheus**.
2. For each row of the table below: paste the query, choose the visualization and unit, set the title, click **Back to dashboard**, then **Add → Visualization** for the next one.
3. Click **Save**, and name the dashboard `Server health`.

| Title | Query | Visualization | Unit |
|---|---|---|---|
| CPU temperature | `max(node_hwmon_temp_celsius * on(chip, sensor) group_left(label) node_hwmon_sensor_label{label=~"Package.*\|Tctl\|Tdie"})` | Gauge (thresholds 75 orange, 90 red) | Celsius (°C) |
| All temperatures | `node_hwmon_temp_celsius * on(chip, sensor) group_left(label) node_hwmon_sensor_label` | Time series, legend `{{chip}} {{label}}` | Celsius (°C) |
| Fan speed | `node_hwmon_fan_rpm` | Time series | RPM |
| Battery level | `node_power_supply_capacity{power_supply=~"BAT.*"}` | Gauge (thresholds 30 red) | Percent (0-100) |
| On AC power | `max(node_power_supply_online{power_supply!~"BAT.*"})` | Stat (value mapping 1 = Plugged in, 0 = ON BATTERY) | none |
| Uptime | `time() - node_boot_time_seconds` | Stat | seconds (s) |
| Reboots (last 7 days) | `changes(node_boot_time_seconds[7d])` | Stat | none |
| Ethernet link | `max(node_network_up{device=~"en.*\|eth.*"})` | Stat (value mapping 1 = Up, 0 = Down) | none |
| Tailscale interface | `count(node_network_info{device="tailscale0"}) or vector(0)` | Stat (value mapping 1 = Up, 0 = Down) | none |
| CPU usage | `100 * (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])))` | Time series | Percent (0-100) |
| Memory usage | `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` | Time series | Percent (0-100) |
| Disk usage | `100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})` | Gauge (thresholds 80 orange, 90 red) | Percent (0-100) |
| CPU throttling | `sum(rate(node_cpu_core_throttles_total[5m]))` | Time series | none |

In the table, `\|` stands for `|`. When pasting into Grafana, type a plain `|` (for example `Package.*|Tctl|Tdie`).

Notes:

- The CPU temperature label depends on the processor: `Package id 0` on Intel, `Tctl` or `Tdie` on AMD. If the first panel shows no data, look at the **All temperatures** panel to find yours.
- **CPU throttling** above 0 means the CPU slows itself down because it's too hot: improve airflow.
- Alloy runs inside a container, so network **traffic** counters show the container's traffic, not the laptop's. Link status (the Ethernet and Tailscale panels) is read correctly.

### 11.3 Keep the dashboard in git (optional)

1. Open the dashboard, click **Export → Export as JSON**, and download the file.
2. Save it as `grafana/dashboards/server-health.json` in the homelab repo.
3. Run `make recreate S=grafana`.

The dashboard is now provisioned automatically, like `homelab-overview.json`.

### 11.4 Alerts (optional)

Grafana can send a message (email, Telegram, Discord, ntfy…) when something goes wrong.

1. **Alerting → Contact points → Add contact point**: choose your integration and test it.
2. **Alerting → Alert rules → New alert rule**, one rule per line below, with the contact point you created:

| Alert | Query | Condition | Pending period |
|---|---|---|---|
| CPU too hot | `max(node_hwmon_temp_celsius)` | Is above 90 | 5m |
| Running on battery | `max(node_power_supply_online{power_supply!~"BAT.*"})` | Is below 1 | 2m |
| Battery low | `min(node_power_supply_capacity{power_supply=~"BAT.*"})` | Is below 30 | 1m |
| Disk almost full | the Disk usage query above | Is above 90 | 15m |
| Server rebooted | `changes(node_boot_time_seconds[15m])` | Is above 0 | 0s |

---

## 12. Get notified if the server goes offline

Grafana can't alert when the laptop is off or offline, because it runs on the laptop. An external service can: the server sends it a signal every 5 minutes, and you get an email or push notification if the signals stop.

This uses [healthchecks.io](https://healthchecks.io), which is free for a few checks.

1. Create an account, then **Add Check**. Set **Period** to 5 minutes and **Grace** to 10 minutes.
2. Copy the ping URL, which looks like `https://hc-ping.com/xxxxxxxx-xxxx-...`.
3. In **Integrations**, add email or the mobile app.
4. On the laptop, replace `YOUR_PING_URL` below with your URL:

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

**Check:** the check turns green on healthchecks.io within a minute.

The ping URL is private: don't commit it to a public repo.

---

## 13. Monitor internet speed

A script runs an internet speed test every 2 hours. It saves each result to a CSV file and sends it to the homelab stack, so you can graph download, upload, ping and jitter in Grafana.

Nothing in the homelab project changes: the OTel Collector already accepts metrics on port 4318 and forwards them to Prometheus.

> Each test downloads and uploads roughly 1–2 GB at fiber speeds, and briefly uses the whole connection. Don't run it more often than every hour.

### 13.1 Install the speed test client

The official Ookla client is accurate on fast connections:

```bash
sudo snap install speedtest
```

### 13.2 Create the script

Find your Tailscale IP with `tailscale ip -4`, and replace `100.80.98.112` below with it:

```bash
sudo tee /usr/local/bin/internet-speedtest >/dev/null <<'EOF'
#!/usr/bin/env bash
# internet-speedtest — measure internet speed, log it to CSV, and send it to Grafana (via the OTel Collector)
set -euo pipefail

OTLP_URL="http://100.80.98.112:4318/v1/metrics"   # your Tailscale IP (BIND_ADDR) + port 4318
CSV=/var/log/internet-speedtest.csv
SPEEDTEST=${SPEEDTEST:-/snap/bin/speedtest}

result=$("$SPEEDTEST" --accept-license --accept-gdpr --format=json)

payload=$(python3 - "$result" "$CSV" <<'PY'
import json, sys, time, os
r, csv_path = json.loads(sys.argv[1]), sys.argv[2]
down = r["download"]["bandwidth"] * 8 / 1e6
up   = r["upload"]["bandwidth"] * 8 / 1e6
ping = r["ping"]["latency"]
jitter = r["ping"]["jitter"]
loss = r.get("packetLoss")

# 1) CSV log (kept even if the stack is down)
new = not os.path.exists(csv_path)
with open(csv_path, "a") as f:
    if new:
        f.write("time,download_mbps,upload_mbps,ping_ms,jitter_ms,packet_loss_pct\n")
    f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')},{down:.1f},{up:.1f},{ping:.1f},{jitter:.1f},{'' if loss is None else loss}\n")

# 2) OTLP JSON for the collector
now = str(time.time_ns())
def gauge(name, value):
    return {"name": name, "gauge": {"dataPoints": [{"asDouble": float(value), "timeUnixNano": now}]}}
metrics = [gauge("internet_download_mbps", down), gauge("internet_upload_mbps", up),
           gauge("internet_ping_ms", ping), gauge("internet_jitter_ms", jitter)]
if loss is not None:
    metrics.append(gauge("internet_packet_loss_percent", loss))
print(json.dumps({"resourceMetrics": [{
    "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "speedtest"}}]},
    "scopeMetrics": [{"scope": {"name": "speedtest"}, "metrics": metrics}]}]}))
PY
)

if curl -fsS -m 10 -o /dev/null -H 'Content-Type: application/json' -d "$payload" "$OTLP_URL"; then
  echo "Sent to Grafana: $(tail -n1 "$CSV")"
else
  echo "Stack not reachable, saved to CSV only: $(tail -n1 "$CSV")"
fi
EOF
sudo chmod +x /usr/local/bin/internet-speedtest
```

### 13.3 Test it once

Start the stack first (`make up`), then:

```bash
sudo internet-speedtest
```

It takes about 30 seconds and prints:

```
Sent to Grafana: 2026-09-16 16:10:22,927.3,928.1,1.7,0.1,0
```

The columns are: time, download (Mbit/s), upload (Mbit/s), ping (ms), jitter (ms), packet loss (%).

If it prints `Stack not reachable`, check the OTel Collector still publishes port 4318: `docker port otel-collector`.

**Check** the data reached Prometheus: open `http://<tailscale-ip>:9090`, run `{__name__=~"internet.*"}`, and look at the **Table** tab. You should see `internet_download_mbps`, `internet_upload_mbps`, `internet_ping_ms` and `internet_jitter_ms`.

### 13.4 Run it every 2 hours

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

**Check:**

```bash
systemctl list-timers internet-speedtest.timer     # shows the next run
journalctl -u internet-speedtest -n 5              # output of the last runs
```

To change the frequency, edit `OnUnitActiveSec=` in the timer file (e.g. `4h`), then run `sudo systemctl daemon-reload && sudo systemctl restart internet-speedtest.timer`.

### 13.5 Create the Grafana dashboard

1. Open Grafana, then **Dashboards → New → New dashboard → Add visualization**, and select **Prometheus**.
2. On the right of the query editor, switch from **Builder** to **Code**.
3. Paste the first query of the panel, open **Options** under it, and set:
   - **Type:** `Range` (with `Instant`, you get no graph)
   - **Legend:** `Custom`, with the name from the table
4. For the second query of the same panel, click **+ Add query** and repeat step 3.
5. Set the panel title, and the unit in **Standard options → Unit**.
6. Click **Back to dashboard**, then **Add → Visualization** for the second panel.
7. **Save** the dashboard as `Internet speed`.

| Panel title | Query | Legend | Unit |
|---|---|---|---|
| Speed | `last_over_time(internet_download_mbps[3h])` | `Download` | Megabits/sec |
|  | `last_over_time(internet_upload_mbps[3h])` | `Upload` |  |
| Latency | `last_over_time(internet_ping_ms[3h])` | `Ping` | Milliseconds (ms) |
|  | `last_over_time(internet_jitter_ms[3h])` | `Jitter` |  |

Tips:

- `last_over_time(...[3h])` keeps the line continuous between tests. Without it, Prometheus shows each value for only 5 minutes after the test, and the graph looks almost empty.
- In **Graph styles → Show points**, choose **Always** to see each test as a dot.
- This dashboard is stored in Grafana's database, not in the homelab repo. It survives restarts, but `make clean` deletes it.

### 13.6 Read the history from the terminal

The CSV keeps every result, including tests run while the stack was stopped (those don't appear in Grafana):

```bash
column -s, -t /var/log/internet-speedtest.csv | tail -n 20
```

### 13.7 Understand the results

| Value | Good | Notes |
|---|---|---|
| Download / Upload | close to your plan | A laptop's 1 Gbit/s Ethernet port can't exceed about 940 Mbit/s, even on a faster plan |
| Ping | under 30 ms | Time for a message to reach the test server and come back |
| Jitter | under 5 ms | How much the ping varies; high jitter makes calls stutter |
| Packet loss | 0 % | Sometimes empty: some test servers can't measure it |

Speeds much lower than usual at some hours often mean your ISP is congested then, or something on your network was using the connection during the test.

### 13.8 Undo the speed test

```bash
sudo systemctl disable --now internet-speedtest.timer
sudo rm -f /etc/systemd/system/internet-speedtest.service /etc/systemd/system/internet-speedtest.timer
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/internet-speedtest
```

Optionally, also:

```bash
sudo rm -f /var/log/internet-speedtest.csv     # delete the history
sudo snap remove speedtest                     # uninstall the Ookla client
```

In Grafana, delete the dashboard from **Dashboards → Internet speed → ⋮ → Delete**. The data already stored in Prometheus disappears on its own after its retention period (30 days by default).

---

## 14. Final test

Do all of these once. Tick each line.

**Reboot and lid**

- [ ] `sudo reboot`, don't log in, close the lid.
- [ ] After 5 minutes, from your phone on **mobile data** with Tailscale on: `ssh youruser@<tailscale-ip>` works.
- [ ] `systemctl is-active tailscaled` → `active`, `systemctl is-active docker` → `inactive`.

**Stack and monitoring**

- [ ] `cd homelab-infra && make up`
- [ ] Grafana opens at `http://<tailscale-ip>:3000` and the Server health dashboard shows temperatures and battery.

**Network**

- [ ] Unplug the Ethernet cable for 1 minute: the laptop stays reachable over Wi-Fi (if you set up section 7).
- [ ] Plug it back: `ip route show default` uses Ethernet again.

**Tailscale recovery**

- [ ] `sudo systemctl stop tailscaled`, wait 5 minutes.
- [ ] `journalctl -t tailscale-watchdog` shows "Restarting tailscaled" and `tailscale status` works again.

**Freeze recovery** (the laptop crashes on purpose and reboots)

- [ ] Run `make down` first so databases shut down cleanly.
- [ ] Run:
  ```bash
  echo c | sudo tee /proc/sysrq-trigger
  ```
- [ ] The laptop reboots by itself within about a minute, and Tailscale is back.

**Power**

- [ ] Unplug the charger for 2 minutes: the laptop keeps running, and the Grafana panel shows ON BATTERY.

---

## 15. Troubleshooting and undo

### The laptop still sleeps with the lid closed

```bash
systemctl status sleep.target                   # must be masked
cat /etc/systemd/logind.conf.d/server.conf      # must exist
systemd-analyze cat-config systemd/logind.conf | grep -i lid
```

Some laptops also have a lid option in the BIOS: disable any "sleep on lid close".

### The laptop rebooted and I don't know why

```bash
journalctl -b -1 -e                          # end of the previous boot
journalctl -t tailscale-watchdog             # reboots triggered by the watchdog
last -x reboot | head                        # reboot history
```

### Tailscale doesn't come back after reboot

```bash
systemctl status tailscaled
sudo tailscale up
```

If `tailscale status` says `Logged out`, key expiry is still on: see section 2.

### It reboots in a loop

Boot, and before 5 minutes pass, disable the automatic reboots:

```bash
sudo systemctl disable --now tailscale-watchdog.timer
sudo rm /etc/systemd/system.conf.d/watchdog.conf
sudo rm /etc/sysctl.d/99-server-autoreboot.conf
sudo reboot
```

Then find the cause with `journalctl -b -1 -e`.

### The speed test shows no data in Grafana

1. Check the data exists in Prometheus: open `http://<tailscale-ip>:9090` and run `{__name__=~"internet.*"}`.
2. If it's there: in Grafana, select the **Prometheus** data source, set the query **Type** to **Range**, and make sure the time range includes the time of the test.
3. If it's not there: run `sudo internet-speedtest` with the stack up, and watch `make logs S=otel-collector` for an error.

### Undo everything

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
