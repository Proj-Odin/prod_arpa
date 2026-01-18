# prod_arpa

chmod +x setup_conky_overlay.sh
sudo ./setup_conky_overlay.sh

# Start Conky immediately (without logging out)
conky -c ~/.config/conky/conky.conf

# Checkmk
sudo chmod +x /usr/lib/check_mk_agent/local/hdd_burnin_status.sh

sudo CMK_AGENT_DEB_URL="https://<checkmk-host>/<site>/check_mk/agents/<agent>.deb" \
     CMK_SERVER_IP="<checkmk-server-ip>" \
     ./setup.sh


### 1) `setup.sh` (one-time bootstrap for the burn-in box)

What it does:

* Installs the baseline packages you need (smartmontools, badblocks deps, tmux, ufw, ssh, curl, perl, etc.), **but only if missing**.
* Sets **SSH to port 1492** (or whatever `SSH_PORT` is) using an sshd drop-in when possible.
* Configures **UFW firewall** in a *non-destructive* way (does **not** reset rules), and adds:

  * allow SSH on your custom port
  * allow Checkmk agent port **6556/tcp** (optionally restricted to `CMK_SERVER_IP`)
* Installs **Checkmk RAW agent (2.3+)** if you provide `CMK_AGENT_DEB_URL`
* Installs the **smart_posix** agent plugin (async cached every 300s) so Checkmk discovers SMART temp/stats
* Installs/patches the Checkmk **local check** that reads your burn-in history and ensures **`ABORTED => CRIT`**

When you run it:

* Once per machine (or re-run safely; it checks before changing things)

How you run it:

```bash
sudo CMK_AGENT_DEB_URL="https://<checkmk-host>/<site>/check_mk/agents/<agent>.deb" \
     CMK_SERVER_IP="<checkmk-server-ip>" \
     ./setup.sh
```

---

### 2) `hdd_validate.sh` (interactive drive validation + history DB)

What it does:

* Shows an interactive menu listing all disks (sorted by size) including:

  * device path, model, serial, and “last run” summary from history
* Maintains persistent records under:

  * `/var/lib/hdd_burnin/drives.tsv` (registry of seen drives)
  * `/var/lib/hdd_burnin/runs.tsv` (append-only run results)
* Writes full logs per run to:

  * `/var/log/hdd_validate_<timestamp>/...`

Phases:

* **Phase 0 (non-destructive)**: SMART triage

  * captures SMART pre/post logs
  * runs short/conveyance/long tests
  * marks per-drive outcome PASS/WARN/FAIL
  * WARN happens if SMART dumps fail (per-drive, fixed for multi-drive)
* **Phase B (destructive)**: `badblocks -w` surface scan

  * enforces max batch size (your config)
  * refuses to touch the OS/root disk or mounted disks
  * monitors temps and aborts if a drive crosses your `MAX_TEMP`
  * captures SMART pre/post
  * records PASS/WARN/FAIL in `runs.tsv`

Why it matters:

* It’s your “return-window evidence”: you get logs + a clear PASS/FAIL outcome per serial number.

How you run it:

```bash
sudo ./hdd_validate.sh
```

Then pick drives by number and choose Phase 0 / Phase B / Both.

---

### 3) `setup_conky_overlay.sh` (desktop overlay HUD for Xubuntu)

What it does:

* Installs **Conky** and optional sensor tooling
* Runs `sensors-detect` (safe/automatic)
* Creates a Conky overlay config that sits on your desktop showing:

  * CPU, RAM, disk usage, network rates, and drive temps
* For drive temps it uses:

  * `smartctl` (best per-drive), optionally with sudo NOPASSWD
* Adds an **XFCE autostart entry**, so the overlay starts when you log in.

Why it matters:

* While badblocks is running for days, you can glance at the desktop and see temps/system load instantly.

How you run it:

```bash
chmod +x setup_conky_overlay.sh
sudo ./setup_conky_overlay.sh
```

Then (optional immediate start):

```bash
conky -c ~/.config/conky/conky.conf
```

---

If you want, I can also make them “fit together” even tighter by:

* having `hdd_validate.sh` write a `current_run.json` (selected drives + phase + pids)
* adding that to Conky + the Checkmk local check so both show “Phase B running on sda/sdb/sdc” in real time.
