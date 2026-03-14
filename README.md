# prod_arpa

HDD burn-in and monitoring toolkit for a Linux validation box.

This repo now exposes stable entrypoints at the top level and keeps versioned implementations beside them. Use the non-versioned scripts first.

## Current entrypoints

- `setup.sh` -> system bootstrap, SSH/UFW, Checkmk agent/plugin, and burn-in state permissions
- `hdd_validate.sh` -> interactive SMART plus destructive badblocks validation flow
- `setup_conky_overlay.sh` -> Conky desktop overlay for live burn-in status
- `badblocks_state_update.sh` -> monitoring and export script for active badblocks runs
- `install_badblocks_monitor.sh` -> basic systemd installer for the monitor
- `install_badblocks_monitor_holistic.sh` -> fuller installer with node_exporter integration
- `check_badblocks_deps.sh` -> dependency check for the badblocks monitor path
- `checkmk_updater.sh` -> standalone updater for the Checkmk burn-in local check
- `checkmake_updater.sh` -> compatibility alias for `checkmk_updater.sh`

## Quick start

### 1. Bootstrap the host

```bash
chmod +x setup.sh
sudo CMK_AGENT_DEB_URL="https://<checkmk-host>/<site>/check_mk/agents/<agent>.deb" \
     CMK_SERVER_IP="<checkmk-server-ip>" \
     ./setup.sh
```

Optional environment overrides:

- `SSH_PORT=1492`
- `FORCE_CMK_AGENT=1`
- `WOL_IFACE=<nic>`
- `BURNIN_GROUP=burnin`

### 2. Install the Conky overlay

```bash
chmod +x setup_conky_overlay.sh
sudo ./setup_conky_overlay.sh
conky -c ~/.config/conky/conky.conf
```

### 3. Run validation

```bash
chmod +x hdd_validate.sh
sudo ./hdd_validate.sh
```

Menu options:

- `Phase 0` for non-destructive SMART triage
- `Phase B` for destructive `badblocks -w`
- `Both` to run Phase 0 and then Phase B

### 4. Install badblocks monitoring

```bash
chmod +x install_badblocks_monitor_holistic.sh
sudo ./install_badblocks_monitor_holistic.sh install --script ./badblocks_state_update.sh --interval 60
```

Status check:

```bash
sudo ./install_badblocks_monitor_holistic.sh status
```

### 5. Update Checkmk local check (standalone)

```bash
chmod +x checkmk_updater.sh
sudo ./checkmk_updater.sh install
```

## What each script manages

### `setup.sh`

- Installs required packages such as `smartmontools`, `e2fsprogs`, `tmux`, `ufw`, `openssh-server`, and helper tools
- Configures SSH on `SSH_PORT`
- Configures UFW without resetting unrelated rules
- Installs the Checkmk agent when `CMK_AGENT_DEB_URL` is provided
- Installs the `smart_posix` Checkmk plugin
- Creates and secures `/var/lib/hdd_burnin`

### `hdd_validate.sh`

- Inventories disks and blocks dangerous selections like the OS disk or mounted disks
- Runs SMART tests and records results
- Runs destructive badblocks passes with temperature monitoring
- Writes state to `/var/lib/hdd_burnin/current_run.json`
- Appends history to `/var/lib/hdd_burnin/drives.tsv` and `/var/lib/hdd_burnin/runs.tsv`
- Stores run logs under `/var/log/hdd_validate_<timestamp>/`

### `setup_conky_overlay.sh`

- Installs Conky and sensor packages
- Configures an XFCE autostart entry
- Displays host stats, burn-in status, and drive temperatures

### `badblocks_state_update.sh`

- Detects active `badblocks` processes
- Writes per-drive JSON state under `/var/lib/hdd_burnin/badblocks`
- Exports Prometheus metrics for node_exporter textfile collection
- Can enrich state with `/var/lib/hdd_burnin/orchestrator_state.json`

## Repository layout

```text
.
|- setup.sh
|- hdd_validate.sh
|- setup_conky_overlay.sh
|- badblocks_state_update.sh
|- install_badblocks_monitor.sh
|- install_badblocks_monitor_holistic.sh
|- checkmk_updater.sh
|- *_v*.sh
|- docs/
|  \- ARCHITECTURE.md
|- archive/
|  |- old-scripts/
|  \- extras/
\- LICENSE
```

## State and logs

- `/var/lib/hdd_burnin/drives.tsv`
- `/var/lib/hdd_burnin/runs.tsv`
- `/var/lib/hdd_burnin/current_run.json`
- `/var/lib/hdd_burnin/badblocks/`
- `/var/log/hdd_validate_<timestamp>/`

## Checkmk notes

After setup, discover services on the host. You should see:

- SMART services from `smart_posix`
- `HDD_Burnin_CurrentRun`
- `HDD_Burnin_NewDrives`
- `HDD_Burnin_<SERIAL>`

`ABORTED` burn-in runs are intentionally mapped to `CRIT`.
`HDD_Burnin_NewDrives` goes `WARN` while a run is actively burning drives with no prior run history.

## Safety reminders

- `Phase B` is destructive and erases selected drives.
- The validation flow refuses the root disk and mounted disks.
- Temperature aborts are treated as failed or aborted runs on purpose.

## Supporting docs

- Architecture notes: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Legacy material: [archive/README.md](archive/README.md)
