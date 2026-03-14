# Architecture Notes

This repo is built around a runner/observer split.

## Runner

`hdd_validate.sh` is the operator-facing workflow.

- Builds a disk inventory
- Runs SMART tests
- Runs destructive badblocks passes when requested
- Writes persistent state to `/var/lib/hdd_burnin`
- Writes logs to `/var/log/hdd_validate_<timestamp>/`

Main safety controls:

- root-disk detection
- mounted-disk refusal
- explicit destructive confirmation
- temperature abort thresholds
- file locking to prevent overlapping runs

## Observer

`badblocks_state_update.sh` runs independently of the validator.

- Scans active `badblocks` processes
- Derives progress and throughput
- Writes per-drive JSON state
- Exports Prometheus metrics
- Optionally reads `/var/lib/hdd_burnin/orchestrator_state.json`

This separation keeps dashboards and alerting independent from the burn-in workflow itself.

## Visualizers and integrations

- `setup_conky_overlay.sh` provides an on-box visual status display
- `setup.sh` installs the Checkmk agent and local-check integration
- `install_badblocks_monitor_holistic.sh` integrates the monitor with node_exporter textfile collection

## Repo organization

- Top-level non-versioned scripts are the stable entrypoints
- Top-level versioned scripts are the current implementations behind those entrypoints
- `archive/old-scripts` holds superseded historical revisions
- `archive/extras` holds side material that is not part of the main burn-in flow

## Cleanup notes

- The README previously referenced filenames that did not exist in the repo
- Legacy material lived beside current scripts without a clear boundary
- Architecture notes were moved under `docs/`