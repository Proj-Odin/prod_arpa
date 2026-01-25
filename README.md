# prod_arpa — HDD Burn-In + Monitoring Toolkit (Xubuntu + Checkmk RAW)

Detach safely:

Press Ctrl-b then d

Reattach later:

tmux attach -t burnin

This repo is a small “burn-in box” toolkit for validating refurbished HDDs before the return window closes.

It includes **three scripts**:

* **`setup.sh`** — one-time (idempotent) machine bootstrap + Checkmk agent/plugin + firewall/SSH
* **`hdd_validate.sh`** — interactive HDD validation with logging + historical TSV database + real-time status JSON
* **`setup_conky_overlay.sh`** — desktop overlay (Conky) showing live system + burn-in status

---

## Quick Start (recommended order)

### 1) Bootstrap the box (packages, SSH, UFW, Checkmk agent + plugins)

```bash
chmod +x setup.sh
sudo CMK_AGENT_DEB_URL="https://<checkmk-host>/<site>/check_mk/agents/<agent>.deb" \
     CMK_SERVER_IP="<checkmk-server-ip>" \
     ./setup.sh
```

Notes:

* **`CMK_AGENT_DEB_URL`** is the **agent .deb URL served by your Checkmk server** (from the Checkmk UI).
* **`CMK_SERVER_IP`** is optional but recommended so UFW only allows port **6556/tcp** from your Checkmk server.

Optional overrides:

* `SSH_PORT=1492` (default is 1492)
* `FORCE_CMK_AGENT=1` to reinstall the agent even if already installed

Example:

```bash
sudo SSH_PORT=1492 FORCE_CMK_AGENT=1 \
     CMK_AGENT_DEB_URL="https://cmk.local/mysite/check_mk/agents/check-mk-agent_2.3.0pXX_all.deb" \
     CMK_SERVER_IP="192.168.1.50" \
     ./setup.sh
```

---

### 2) Install the desktop overlay (Conky)

```bash
chmod +x setup_conky_overlay.sh
sudo ./setup_conky_overlay.sh
```

Start Conky immediately (no logout needed):

```bash
conky -c ~/.config/conky/conky.conf
```

What it shows:

* CPU/RAM/Disk/Network
* Burn-in status + selected drives (from `/var/lib/hdd_burnin/current_run.json`)
* Latest log line from the active run summary
* Per-drive temps for currently selected drives

---

### 3) Run the HDD validation (interactive)

```bash
chmod +x hdd_validate.sh
sudo ./hdd_validate.sh
```

You’ll get a menu:

* Phase 0 (non-destructive SMART triage)
* Phase B (destructive badblocks -w surface scan)
* Both (Phase 0 then Phase B)

---

## What each script does

## 1) `setup.sh` — bootstrap + Checkmk integration (idempotent)

### What it does

* Installs required packages (only if missing):
  `smartmontools`, `e2fsprogs`, `tmux`, `ufw`, `openssh-server`, `curl`, `perl`, etc.
* Configures **SSH** to listen on **port 1492** (or `SSH_PORT`)
* Configures **UFW** without resetting rules:

  * Allows SSH on your custom port
  * Allows Checkmk agent port **6556/tcp** (optionally restricted to `CMK_SERVER_IP`)
* Installs **Checkmk RAW agent (2.3+)** if `CMK_AGENT_DEB_URL` is provided
* Installs the **`smart_posix`** agent plugin (cached/async) so Checkmk discovers SMART services
* Installs/patches the Checkmk **local check** that reports burn-in outcomes and ensures:

  * `ABORTED` → **CRIT** (so it alerts)

### Checkmk local check output

After `setup.sh`, the agent will expose:

* SMART services from `smart_posix` (temps/stats) after discovery
* Local services:

  * `HDD_Burnin_CurrentRun` (real-time run status)
  * `HDD_Burnin_<SERIAL>` (latest result per drive)

---

## 2) `hdd_validate.sh` — interactive burn-in + evidence logs

### What it does

* Builds an inventory of disks sorted by size
* Shows device + model + serial + last run outcome
* Creates/maintains persistent history under:

  * `/var/lib/hdd_burnin/drives.tsv` — registry of seen drives
  * `/var/lib/hdd_burnin/runs.tsv` — append-only run history (audit trail)
* Writes real-time status to:

  * `/var/lib/hdd_burnin/current_run.json` — used by Conky + Checkmk
* Writes full run logs to:

  * `/var/log/hdd_validate_<timestamp>/...`

### Phases

#### Phase 0 (non-destructive): SMART triage

* SMART dump pre/post
* Runs: short + conveyance + long tests
* Records PASS/WARN/FAIL per drive

  * `WARN` if a SMART dump failed (instead of silently passing)

#### Phase B (destructive): surface scan

* Runs `badblocks -w` (ERASES data)
* Enforces max batch size (defaults to 4)
* Refuses OS/root disk and mounted disks
* Monitors temps and aborts if `MAX_TEMP` exceeded
* Records PASS/WARN/FAIL per drive

### Why it matters

This produces “return-window evidence”: logs + SMART snapshots + consistent outcomes per serial number.

---

## 3) `setup_conky_overlay.sh` — real-time desktop monitoring (Xubuntu)

### What it does

* Installs Conky + optional sensors
* Runs `sensors-detect`
* Writes a Conky config to `~/.config/conky/conky.conf`
* Adds an XFCE autostart entry so Conky starts on login
* Shows burn-in status and per-drive temps in real time

---

## Checkmk RAW setup notes (so services appear + alert)

### 1) Add the host in Checkmk

* Create a host for the burn-in box with its IP

### 2) Discovery

* Run **Service discovery** on the host
* You should see:

  * SMART-related services (from `smart_posix`)
  * Local services:

    * `HDD_Burnin_CurrentRun`
    * `HDD_Burnin_<SERIAL>`

### 3) Alerts for ABORTED runs

This repo’s local-check mapping intentionally treats:

* `ABORTED` → **CRIT (2)**

That means:

* If you Ctrl+C or a temp kill triggers, Checkmk will page/alert (by design).

---

## Files & paths

### Logs

* Run logs:
  `/var/log/hdd_validate_<timestamp>/`
* Summary file:
  `/var/log/hdd_validate_<timestamp>/SUMMARY.txt`

### Persistent state

* Drive registry (seen drives):
  `/var/lib/hdd_burnin/drives.tsv`
* Run history (append-only):
  `/var/lib/hdd_burnin/runs.tsv`
* Real-time status:
  `/var/lib/hdd_burnin/current_run.json`

---

## Common commands

### Run validation inside tmux

```bash
tmux new -s burnin
sudo ./hdd_validate.sh
```

Detach:

```bash
Ctrl+b then d
```

Reattach:

```bash
tmux attach -t burnin
```

### Confirm Checkmk agent output on the burn-in box

```bash
sudo check_mk_agent | sed -n '/<<<local>>>/,$p'
```

### Start Conky now

```bash
conky -c ~/.config/conky/conky.conf
```

---

## Safety reminders

* **Phase B is destructive** and will erase data on selected disks.
* The script refuses to run destructive tests on:

  * the OS/root disk
  * any disk/partition that is mounted
* If temps exceed `MAX_TEMP`, the run is marked **ABORTED** and (by design) becomes **CRIT** in Checkmk.

---
One more thing you’ll likely hit

Because Option B uses group permissions, your desktop user won’t see Conky burn-in status until they re-login.

After running setup:
```bash
id | grep -q burnin || echo "Log out/in so you actually join the burnin group."
```

How to use it

From the directory containing badblocks_state_update.sh:
```bas
sudo bash install_badblocks_monitor.sh install --interval 60
```

Or if the script lives elsewhere:
```bash
sudo bash install_badblocks_monitor.sh install --script /path/to/badblocks_state_update.sh --interval 60
```
