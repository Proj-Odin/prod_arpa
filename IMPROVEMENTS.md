# HDD / SMART tooling improvements backlog

Scope: `Proj-Odin/prod_arpa`. These are proposed follow-up changes, **not** changes already implemented in `hdd_validate_v4.5.sh`.

## P0 — Correctness and safety before further burn-in use

- [ ] **Sequence firmware self-tests.** `phase0()` starts a short test and immediately requests a conveyance test on each drive. Wait for the short test to finish and verify its result before requesting another; skip conveyance if unsupported or unnecessary. A new self-test request can interrupt the prior one.
- [ ] **Check `smartctl` commands and their exit bitmasks.** The `smart_try()` helper currently applies `|| true` inside command substitution before reading `$?`, obscuring failures. Do not decide success merely from nonempty output. Preserve the real code, inspect bits 0–2 for command errors, and record failures explicitly.
- [ ] **Verify completion, not just absence of “in progress.”** The long-test polling loop may conclude too early when `smartctl -c` fails, USB/SAT bridges omit progress, or output wording differs. Record test start, expected type, progress/read failures, final self-test log entry, completion state, and first-error LBA. Missing evidence is `UNKNOWN`, never `PASS`.
- [ ] **Re-audit the destructive `badblocks -w` exclusion checks.** Resolve the OS, swap, mounted, mdraid, LVM, and other mapped-device ancestors/descendants before permitting Phase B. Test the guardrails with fixtures; refuse ambiguous devices and any active/mounted storage. Require a serial/model/size confirmation, not only the word `ERASE`.
- [ ] **Use a reliable transaction/lock strategy for persistent TSV files.** `db_upsert_drive()` locks the TSV inode but replaces it with `mv`, allowing another process to lock the new inode independently. Use a stable dedicated lock file with atomic replacement and verified permissions, or move to SQLite.

## P1 — Reliability and useful reporting

- [ ] **Distinguish transport limitations from drive health.** Include explicit USB SAT/SCSI, SAS, and NVMe handling; surface incomplete ATA register responses instead of equating the attribute-based `PASSED` string with a clean drive.
- [ ] **Use structured SMART output where available.** Prefer `smartctl -j` for self-test progress, errors, temperature, reallocated, pending, uncorrectable, CRC, and power-on-hour fields. Mark unavailable values `UNKNOWN` rather than coercing them to zero; support non-ATA layouts.
- [ ] **Improve thermal checks.** Record missing sensor data as `UNKNOWN` and make the policy explicit (warn, stop, or require operator choice). Preserve temperature history per drive and avoid silently missing hot devices if a SMART probe times out.
- [ ] **Track results per drive and command.** Record test requested, accepted, completed, failed, unsupported, or interrupted; preserve `smartctl` stdout/stderr and exit status. Do not suppress failures with unconditional `|| true` in result-critical paths.
- [ ] **Add automated regression tests.** Use mocked `smartctl`, `lsblk`, and mount output to cover SMART bitmask handling, running-test detection, USB/SAT behavior, failed/read-only health queries, interrupted runs, and Phase B refusal of active disks. Run `bash -n` and ShellCheck in CI.
- [ ] **Update README / operator guidance.** Document `smart-selftest.sh` as the non-destructive path and reserve `hdd_validate.sh` Phase B for explicitly authorized destructive testing. Include examples for USB (`--type sat`), NVMe, long-test progress, logs, and `tmux`.

## Shipped separately

- `smart-selftest.sh`: a standalone, non-destructive SMART CLI; supports `list`, `short`, `long`, `status`, and `report`. It does **not** run `badblocks` or alter the v4.5 burn-in workflow.
