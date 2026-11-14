# Darwin ASIC boards

`hw_vdf_client` opens one timelord connection per bit set in `--vdfs-mask`. A
non-zero mask is used as given. The timelord needs three connections, so masks
follow the board count, in ID order: one board uses 7, two boards use 3 on the
lowest ID and 1 on the other, and three boards use 1 each. `N_VDFS` is the
popcount of that mask. Frequency stays 1540, voltage stays 1.0, and the optional
`chia_darwin_hw_vdf_max_freq` and `chia_darwin_hw_vdf_auto_freq_period` flags
are passed only when greater than zero. `vdf_threads` and `proof_threads` stay
12 and 11 unless that board sets them.

## Where the board list comes from

With `chia_darwin_enable_hw_vdf` true, precedence is:

1. A non-empty `chia_darwin_hw_vdf_boards` list is used as written. It pins
   each board and skips discovery.
2. An empty list with a non-empty `chia_darwin_hw_vdf_expected_serial` keeps
   the legacy single-board path: mask from `chia_darwin_hw_vdf_mask`, no
   `--device-loc`, and no discovery.
3. An empty list with both unset auto-discovers attached boards with
   `hw_vdf_client --list` after chiavdf is installed.

`hw_vdf_client --list` is the same source chiavdf uses for `--device-loc`.
chiavdf 1.2.2 `FtdiDriver::List()` prints only FT4222H interfaces whose
description ends in `A`, in the row format
`Device N: '<description>', loc <id>, serial '<serial>'`
([source](https://github.com/Chia-Network/chiavdf/blob/1.2.2/src/hw/ftdi_driver.cpp)).
It does not filter serial numbers to Chia boards. Auto-discovery keeps only
serials matching `^CHIA[0-9]{10}A$`: the `CHIA` prefix, ten digits, and a
trailing `A`. That serial pattern is the owner-confirmed factory format for
these boards; chiavdf does not enforce it. Rows for other FT4222 devices,
including rows with an empty serial, are valid output and are ignored.
`--expected-serial` accepts either the printed `CHIA...A` form or the base
form without that final `A`.

Claimed wrappers and `--list` rows are matched directly, without the serial
pattern deciding identity. A stored serial matches a listed serial when they
are equal, or when the listed serial ends in `A` and the stored serial equals
it without that `A`. A stored full serial does not match a shorter listed
serial, and other final characters are never dropped. The pattern only selects
which visible rows are Chia boards.
Newly discovered boards keep the full serial printed by `--list`, and an
already claimed wrapper keeps the SERIAL spelling it already has. That keeps
existing wrappers stable while a wrapper written from an explicit full
`CHIA...A` inventory still matches the same visible board instead of being
counted twice.

A board held open by a running `hw_vdf_client` does not appear in `--list`.
Discovery therefore treats this role's installed wrappers at the role-owned
slot paths as the persisted board inventory. It reads them as text; it never
sources or executes them. A wrapper is a claim when it is at one of those exact
paths and carries the role's management marker and a `DEVICE_LOC` assignment.
Whitespace around the assigned value and a trailing `#` comment are accepted.
Merge is by serial:

- A claimed board keeps its existing ID. If `--list` can see it, the printed
  `loc` replaces the stored one. If it is hidden, the stored location is kept.
- A new serial takes the next free ID, in serial order when several boards are
  new. Existing IDs are not renumbered.
- A board that is removed or detached stays claimed by its wrapper, so the
  board count and masks do not change until an explicit board list retires it.
  Adding a board increases the count and can change masks naturally. IDs do not
  move.

Auto-discovery also takes over legacy and hand-written wrappers. With an empty
board list and an empty legacy serial, any readable wrapper at a role slot
that is not a managed per-board claim becomes a takeover candidate. For each
candidate, one `grep` checks every `<launchd_dir>/*.plist` for that wrapper.
Discovery fails closed when the directory or a plist cannot be read, or when
any plist other than `<label>.plist` runs the wrapper. Otherwise it boots out
that slot's LaunchDaemon and waits for it to unload before running `--list`,
so a board the old client was holding becomes visible. After `--list`, every
takeover candidate's stored `SERIAL` must be visible; a still-hidden serial
means another job or process, inside or outside the configured LaunchDaemons
directory, holds the board (for example a LaunchAgent or a manual run), the
plist's actual `Label` differs, or the board is detached, so discovery fails
closed and restores the old jobs. This catches holders the plist grep cannot
see without scanning the whole filesystem. A hand-written takeover wrapper
without a nonempty `SERIAL` is refused after its job has been stopped and
restored, because the visibility check cannot match it. Set
`chia_darwin_hw_vdf_boards` explicitly to configure that no-`SERIAL` board; an
explicit list does not take it over. Wrappers written by this role always
contain `SERIAL`, including the legacy single-board wrapper.

The stop, enumerate, and restore-attempt window for previously loaded takeover
slots covers `--list`, the visibility check, and the restore attempts; a failed
restore or an interrupted run can leave jobs unloaded. Discovery restarts every
stopped job in an `always` block through the normal restart helper (`enable`,
`bootstrap`, then `disable` when `start_on_boot` is false), whether the takeover
succeeds or fails. Each label gets its own attempt, so one failed restart does
not skip the remaining labels. After those attempts, one `launchctl print` per
stopped label verifies that it is loaded. Any label still down fails the run and
is named in the failure, even when the other jobs came back. The old plist and
wrapper stay until the normal install or retire step replaces or removes them.
Restored processes keep running after a later task fails, but a crash or reboot
after some wrapper or plist writes and before the run completes can start an
incomplete new on-disk set. A later ordered-handler stop/start failure can leave
changed jobs unloaded; otherwise that handler's brief window is after it stops
changed boards and before it starts them in ID order. `KeepAlive` can respawn a
process while its files are being rewritten. This is not an all-role
transaction; each step has its own failure window. A managed per-board claim is
left running and keeps its ID, which is how held-board reruns stay stable.
Explicit `chia_darwin_hw_vdf_boards` and the legacy serial path do not take
anything over and keep the existing ownership refusal.

This preserves IDs, masks, wrappers, and loaded jobs when every board is held
(header-only `--list`) or only some are held. Discovery fails when the merged
set is empty or has more than the allowed slots, when `--list` exits non-zero
(including `No FTDI devices connected.`), when it exceeds its 30-second task
timeout, or when its output cannot be parsed.
A zero exit with only the header is success when wrappers already claim
boards; with no claimed boards it fails as an empty merged set. It also fails
when a takeover wrapper is still hidden after its job stops, when a
role-owned wrapper cannot be read, or when a per-board wrapper has an invalid
SERIAL or DEVICE_LOC, so a partial read cannot silently retire a board.

Limitations: a held board's location cannot be refreshed because `--list`
cannot see it, so it keeps the location from its wrapper. A claimed board that
is no longer attached also stays in the set; remove it intentionally with an
explicit `chia_darwin_hw_vdf_boards` list. If a retained claim blocks a new
board at the same location or leaves no free slot, discovery names the hidden
claim and says to use an explicit list. Those hidden claims may be running
boards, not only removed ones.

Example `--list` output in the format printed by chiavdf 1.2.2
(`Chia-Network/chiavdf`, `src/hw/ftdi_driver.cpp`, `FtdiDriver::List()`, after
`src/hw/hw_vdf_client.cpp` prints the header). Serials and locations are
synthetic; this is example-format output, not a capture from real hardware:

```text
List of available devices:
Device 0: 'Example Chia ASIC A', loc 1101, serial 'CHIA9999999001A'
Device 1: 'Example Chia ASIC A', loc 1102, serial 'CHIA9999999002A'
Device 2: 'Other FT4222 A', loc 1103, serial 'FT4222999999003A'
```

The last row is not a Chia board, so auto-discovery ignores it.

For an explicit list, copy each `device_loc` and `expected_serial` from
`hw_vdf_client --list`. Location IDs change when cables or hubs change.
`--expected-serial` checks the board opened at `--device-loc` and the client
exits before it writes clock or voltage on a mismatch. `0` means the first
interface-A device and is allowed only for one board. Each entry may contain
only `id`, `device_loc`, `expected_serial`, `vdf_threads`, and `proof_threads`.

An empty list keeps one LaunchDaemon, `<prefix>.hw-vdf`, with
`chia_darwin_hw_vdf_mask` (default 7) and no `--device-loc` when the legacy
serial is set. Do not set that scalar serial and the list together. ID 1 is
`<prefix>.hw-vdf`. IDs 2 and 3 are `<prefix>.hw-vdf-2` and
`<prefix>.hw-vdf-3`. IDs do not have to be contiguous. With IDs 1 and 3, ID 1
still runs two engines.

```yaml
chia_darwin_hw_vdf_expected_serial: ""
chia_darwin_hw_vdf_boards:
  - id: 1
    device_loc: 1101
    expected_serial: FIX-BOARD-0001
    vdf_threads: 8
    proof_threads: 4
  - id: 2
    device_loc: 1102
    expected_serial: FIX-BOARD-0002
  - id: 3
    device_loc: 1103
    expected_serial: FIX-BOARD-0003
```

Omit `vdf_threads` and `proof_threads` to keep 12 and 11. One engine on each of
two boards would leave a chain with no client.

Every wrapper waits until the timelord port is listening, sleeps
`chia_darwin_hw_vdf_settle_seconds` (3), then each later board waits another
`chia_darwin_hw_vdf_open_stagger` seconds (15) before opening USB. Set the
stagger to 0 to open every board after the shared settle. A board that launchd
restarts by itself does not wait for the others. `--device-loc` is an option
before the port and `N_VDFS` arguments.

Retrying one board that is not loaded starts that board and leaves the daemon,
full node, timelord, and the other boards running. A change to those service
files, or to the shared runtime scripts, stops the ASIC boards first, restarts
the service jobs, and then starts the boards again in ID order. Outside the
auto-discovery takeover above, a loaded label this role does not own is left
alone. A second run does not bootstrap boards that are already loaded.

| ID  | Label suffix | Wrapper                | Client log     |
| --- | ------------ | ---------------------- | -------------- |
| 1   | `.hw-vdf`    | `chia-hw-vdf-run.sh`   | `hw-vdf.log`   |
| 2   | `.hw-vdf-2`  | `chia-hw-vdf-2-run.sh` | `hw-vdf-2.log` |
| 3   | `.hw-vdf-3`  | `chia-hw-vdf-3-run.sh` | `hw-vdf-3.log` |

The prefix is `chia_darwin_launchd_prefix` (`net.chia.timelord` by default).
Launchd also writes `<name>.out.log` and `<name>.err.log`. Client logs are under
`chia_darwin_log_dir`. Removing a board from an explicit
`chia_darwin_hw_vdf_boards` list, or switching back to the legacy single-board
path, retires that slot. It stops the job and deletes the LaunchDaemon plist
when the plist path greps to this role's wrapper or discovery took the slot
over. It removes the wrapper only when the wrapper carries the role header or
discovery took the slot over, including a marked orphan whose plist is already
gone. An unmarked wrapper that a role-label plist merely runs is left in place;
that plist is removed and the wrapper remains. A managed board that is only
physically detached remains claimed by its wrapper, so auto-discovery keeps it
and its masks until an explicit list retires it. If an enabled label already
has some other plist, the run fails until
`chia_darwin_hw_vdf_claim_existing` is true. `start_now` and `start_on_boot`
apply to every enabled board. The restart handler waits for each job's
`ExitTimeOut` plus `chia_darwin_restart_unload_margin` before bootstrap.

Rollout: leave `chia_darwin_hw_vdf_boards` empty and clear
`chia_darwin_hw_vdf_expected_serial` to let the role discover boards with
`hw_vdf_client --list` and its installed wrappers. A first auto-discovery run
from the legacy single-board path takes over slot 1: it stops the old job,
re-enumerates, and replaces or retires the legacy wrapper and plist at the
normal install point, so slot 1 goes to whichever board discovery assigns. If
the merge fails, it restarts the old job. It also takes over hand-written
wrappers at the other role slots. To pin locations, run
`hw_vdf_client --list`, set
`chia_darwin_hw_vdf_boards`, and clear `chia_darwin_hw_vdf_expected_serial`.
Use an explicit list to remove a board that discovery still sees in a retained
wrapper. ID 1 keeps `<prefix>.hw-vdf`. Confirm three client connections on
`chia_timelord_launcher_port` (8000 unless you changed it). Roll back to one
board by leaving a single explicit inventory entry, or by clearing the list
and setting only the scalar serial (which omits `--device-loc` and retires the
other role-owned wrappers). Attaching one board for auto-discovery is not a
rollback: the other wrappers still claim their boards, so the set stays
larger. `remote-node` still has no local full node, and every ASIC client
still connects to the local timelord.

## Timelord.app

`chia_darwin_timelord_implementation: timelord-app` replaces the role's Python
timelord and `hw_vdf_client` jobs with the signed Timelord.app supervisor. The
default is `chia-blockchain`; the app release is pinned by
`chia_darwin_timelord_app_version` and `chia_darwin_timelord_app_sha256`. The app
is arm64-only, requires macOS 14 or later, and is verified with
`codesign --verify --deep --strict` before it is moved into
`/Applications/Timelord.app`. The upstream repository is private: set
`chia_darwin_timelord_app_github_token` to use the GitHub API asset
(`chia_darwin_timelord_app_asset_id`), use
`chia_darwin_timelord_app_dmg_url` for an internal mirror, or set
`chia_darwin_timelord_app_download: false` and pre-stage the pinned DMG at
`chia_darwin_timelord_app_dmg`. The checksum is always verified.

The app owns the timelord worker and every ASIC USB client, so the role refuses
`timelord-app` with `chia_darwin_enable_hw_vdf: true` (the derived default is
false). Board discovery, automatic tuning, and the
`automatic-profiles.json` state belong to the app. The role does not render a
board list; the app adds visible boards at client ports starting at 18110.

Topology behavior:

- `local-external` keeps the role-managed daemon and full
  node. The app reads the timelord peer identity from CHIA_ROOT with
  `timelord-service local-node`. For `local-external`, `~/.chia` and CHIA_ROOT
  are real directories on the internal disk; only `<chia_root>/db` is a symlink
  to the volume. Identities, config, and the wallet database stay internal. The
  app process does not need Full Disk Access to read those internal identities.
  Full Disk Access is needed only for the shared `/bin/zsh` shebang interpreter
  and the full node's real Homebrew Python binary for the volume DB directory.
  The volume still must be mounted for the full node, so mount it before
  relying on unattended proof production after a reboot.
- `remote-node` installs no Homebrew Python, virtualenv, chia-blockchain, daemon,
  or full node. The app imports a connection bundle with
  `timelord-service import-node`. Set `chia_darwin_timelord_app_bundle_path` for
  a bundle already on the Mac, or `chia_darwin_timelord_app_bundle_src` for a
  controller directory copied to `chia_darwin_timelord_app_bundle_dest`. The
  bundle contains `connection.toml` plus the dedicated peer/RPC client
  identities created on the full-node host.

The vendor installer registers the fixed label
`net.chia.timelord.supervisor`. It is intentionally not built from
`chia_darwin_launchd_prefix`. Worker status is `127.0.0.1:9257`. The app config
lives at `~/Library/Application Support/Timelord/config.toml`.

The app serves the timelord Prometheus metrics directly; no chia-exporter is
needed for IPS or proof telemetry. The `chia_timelord_*` series include
`estimated_ips`, per-chain and raw engine IPS, verified-proof and submission
progress, board temperatures/voltages/frequencies, recoveries, chain
availability, tuning state, and the supervisor's own metrics. With
`chia_darwin_timelord_app_expose_observability: true` (the default, matching the
Linux timelord monitoring posture), the role writes:

```toml
[service]
observability_listen = "0.0.0.0:9258"
allow_remote_observability = true
supervisor_observability_listen = "0.0.0.0:9259"
```

Set `chia_darwin_timelord_app_expose_observability: false` for a loopback-only
deployment; the app then omits the 9258 deployment listener and keeps the
supervisor on `127.0.0.1:9259`. The listeners have no built-in authentication or
TLS, so restrict them to a private monitoring network or use an authenticated
reverse proxy. Scrape them as separate jobs:

```yaml
- job_name: timelord-app
  honor_labels: true
  static_configs:
    - targets: ["<mac>:9258"]
- job_name: timelord-supervisor
  honor_labels: true
  static_configs:
    - targets: ["<mac>:9259"]
```

The app's series replace the legacy timelord exporter for the same logical
instance; do not scrape both as one instance or aggregate duplicate IPS series.
Local full-node `chia_full_node_*` metrics still come from `chia-exporter`.
The role applies these service listeners to an existing app config through
`timelord-service configure`, so adopting a GUI-created config does not require
discarding board state.

The role writes the full app config only when it is missing or
`chia_darwin_timelord_app_force_config: true`. Normal runs update only the node
connection with the app's own command and leave app-written board and tuning
state alone. Remote bundle imports are gated by a content fingerprint, and
`chia_darwin_timelord_app_prune_identities` removes older imported identity
directories while preserving references from the live config and the
supervisor's `last-good.toml`.

In app mode `chia-exporter` remains enabled only when a local full node exists.
`chia-healthcheck` also remains enabled on local topologies, but only its
`/full_node` and `/full_node/ports` endpoints are used. Its `/timelord` endpoint
is a Chia daemon websocket consumer that only recognizes `finished_pot` from
`chia_timelord`; the Rust app does not implement that RPC protocol. This is not
a monitoring gap: the app exposes equivalent and richer `chia_timelord_*` IPS,
proof, submission, thermal, recovery, chain, and supervisor metrics, plus
`/healthz` and `/readyz`. The watchdog uses
`http://127.0.0.1:9259/healthz` for the supervisor and
`http://127.0.0.1:9257/healthz` for the worker. `remote-node` app deployments
disable `chia-healthcheck` because they have no local full node or `CHIA_ROOT`.
A supervisor or worker failure for `chia_darwin_watchdog_fail_cycles` cycles
restarts only the app service. For local topologies the watchdog also verifies
that the role's full-node LaunchDaemon is running and restarts the full stack
when it is not.

Switching back to `chia-blockchain` runs the vendor installer's `remove`
operation only when this role left its managed marker. The app bundle, config,
identities, and learned state are preserved.

## Companion services

The role also owns the LaunchDaemons that the Linux timelord hosts run next to
chia. They use the same `net.chia.timelord.*` prefix, the same service account,
and the same restart path as the core jobs:

| Job                | Label suffix        | Default port | Notes                                  |
| ------------------ | ------------------- | ------------ | -------------------------------------- |
| `chia-exporter`    | `.chia-exporter`    | 9914         | `CHIA_ROOT` may be a read-only copy.   |
| `chia-healthcheck` | `.chia-healthcheck` | 9950         | Serves `/full_node` and `/timelord`.   |
| `node-exporter`    | `.node-exporter`    | 9100         | Host metrics.                          |
| `periodic-connect` | `.periodic-connect` | none         | Runs `chia peer full_node` on a timer. |
| `watchdog`         | `.watchdog`         | none         | Runs as root; see below.               |

Set `chia_darwin_enable_chia_exporter`, `chia_darwin_enable_chia_healthcheck`,
`chia_darwin_enable_node_exporter`, or `chia_darwin_enable_watchdog` to false to
remove the role's job at that label; installed binaries and wrappers are left
in place. Companion jobs replace the plist at the same label; unlike the ASIC
slots, they have no ownership guard, so enabling one takes over a hand-written
companion plist with that label.
On Darwin this role replaces the Linux `chia-exporter`, `chia-healthcheck`, and
`prometheus-node-exporter` roles; do not include those roles in the same play or
they will try to manage the same ports with systemd or Homebrew services.
Central logs and SMART metrics remain separate roles (`alloy` and
`smartctl-exporter`), which now have Darwin paths.

The `periodic-connect` job is installed only when `chia_periodic_connect_peers`
is nonempty and the topology has a local full node (`local-external`). It runs
as the service user on a launchd `StartInterval` of
`chia_darwin_periodic_connect_interval_seconds` (default 300) and runs
`chia peer full_node -a <peer>:<full_node_port>` for each entry, matching the
Linux cron job.

Binary versions are pinned by `chia_darwin_chia_exporter_version`,
`chia_darwin_chia_healthcheck_version`, and
`chia_darwin_node_exporter_version`. Each has a matching `*_sha256` for the
published darwin-arm64 archive. `chia_darwin_install_companion_binaries: false`
skips downloading and keeps whatever is already in
`chia_darwin_companion_bin_dir`. The wrappers pipe output through `rotpipe.py`
with `chia_darwin_companion_rotpipe_max_bytes` and
`chia_darwin_companion_rotpipe_backups`.

`chia_darwin_companion_chia_root` is the `CHIA_ROOT` the exporter and
healthcheck use. It defaults to `chia_root`. A host can point it at a read-only
config copy instead. Companions do not wait for the database volume because
`local-external` keeps CHIA_ROOT, including the wallet database, on the internal
disk and only `<chia_root>/db` on the volume. Only the full-node wrapper waits
on the volume; it lists the on-volume DB directory with `/bin/ls`.

Full Disk Access is needed only for `/bin/zsh` (launchd uses it as the shebang
interpreter for every job wrapper, so the grant is shared by every wrapped job)
and the full node's Python interpreter, meaning the real Homebrew binary that
the venv `python3.13` resolves to, for example
`/opt/homebrew/Cellar/python@3.13/<ver>/Frameworks/Python.framework/Versions/3.13/bin/python3.13`.
That Python grant is tied to the Cellar version path; a Homebrew Python upgrade
changes the path and the node loses DB access until the grant is added for the
new binary. Do not add companion binaries, tailscaled, alloy, exporters, hw-vdf,
the watchdog, Bash, or healthcheck to Full Disk Access for this layout. Ansible
and this role cannot grant TCC Full Disk Access; see the `FULL-DISK-ACCESS.txt`
note the role writes on the Mac, which prints the resolved Python path.

Operator note: on a Mac full-node timelord, keep `~/.chia` on the internal disk
and put only the blockchain DB directory on the external drive. This avoids
grants for helper binaries and is the `local-external` layout the role enforces.

## Watchdog

`chia-watchdog` is the macOS equivalent of the Linux monit configuration. It
runs as root from `<prefix>.watchdog`, checks every 60 seconds, and mirrors the
Linux triggers:

- `/full_node` or `/timelord` not returning 200 for three cycles restarts the
  daemon, full node, timelord, and every enabled `hw-vdf` board.
- `/full_node/ports` not returning 200 for three cycles also restarts the full
  stack when `chia_darwin_watchdog_check_full_node_ports` is true (the Darwin
  default).
- The VDF port having the expected number of established connections and every
  enabled `hw-vdf` job running is the board-health check. A failure restarts
  all enabled boards in ID order.
- The exporter ports not listening for three cycles kickstart that exporter
  job.
- If the healthcheck itself is unreachable, only the healthcheck is restarted.
- After `chia_darwin_watchdog_log_debug_threshold` failed `/full_node` or
  `/timelord` checks, the watchdog calls the full-node and timelord RPCs to set
  DEBUG. When the healthcheck succeeds again it restores
  `log_level` (set `INFO` for the Linux fleet's default).

Board restarts enable the job before bootstrap and disable it again when
`start_on_boot` is false, matching the role's restart helper. The role's own
ordered restart stops the watchdog first and restores it even when a service or
board restart fails, so a failed apply does not leave monitoring down.

The watchdog uses two separate graces. `chia_darwin_watchdog_grace` (default
3600, matching the Linux monit start delay) delays the first check after the
watchdog starts. `chia_darwin_watchdog_restart_grace` (default 600) delays
checks after a watchdog-initiated restart and lengthens by 300 seconds after
repeated restarts, capped at +900. The watchdog never stops checking. The
driver and thresholds are `chia_darwin_watchdog_cycle` and
`chia_darwin_watchdog_fail_cycles`. The expected VDF count is computed from the
enabled board masks, and the `/full_node` and `/full_node/ports` checks are
enabled only when the service job list contains `full-node`.

Alerting uses `/usr/local/etc/chia-watchdog/alert-token` and `webhook-url`.
The role creates the root-only directory and writes either file only when
`chia_darwin_watchdog_alert_token` or `chia_darwin_watchdog_webhook_url` is
nonempty. The two values must be set together; a half-configured sink is
refused. Keep those values in private inventory; both writes use `no_log`.
When both are empty the role removes any stale files, and the watchdog logs the
skipped alert description to `chia-watchdog.log` instead of discarding it.

## Managing several Macs

One inventory entry per Mac is enough. The role is generic; do not copy role
code or add per-host templates for additional Macs. The controller connects
over SSH as an account with passwordless sudo. Keep that account separate from
`user`, the non-admin service account the LaunchDaemons run as. If a different
account owns the Homebrew prefix, set `chia_darwin_brew_user` to that owner.

```yaml
all:
  children:
    mac_timelords:
      hosts:
        mac-timelord-1:
          ansible_host: "<lan-or-tailscale-address>"
        mac-timelord-2:
          ansible_host: "<lan-or-tailscale-address>"
        mac-timelord-3:
          ansible_host: "<lan-or-tailscale-address>"
      vars:
        ansible_user: "<admin-user>"
        ansible_become_method: sudo
        user: "<service-user>"
        chia_darwin_brew_user: "<homebrew-owner>"
        network: mainnet
        log_level: INFO
        target_outbound_peer_count: 30
        chia_darwin_topology: local-external
        chia_darwin_db_volume: /Volumes/<database-volume>
        chia_darwin_pip_version: "2.7.5"
        chia_darwin_enable_hw_vdf: true
        chia_darwin_hw_vdf_boards: []
        chia_darwin_hw_vdf_expected_serial: ""
```

If the only practical SSH login is the service account, set
`chia_darwin_allow_root_capable_service_user: true`. That is a weaker posture
than the Linux split because the network-facing service account is then
root-capable. The role refuses that posture by default.

Any `/etc/sudoers.d/` rule for the service account, for example a leftover
`/etc/sudoers.d/<service-user>-ansible`, trips that guard. Remove it so only
the separate admin account has sudo. Exception: when the service account is
also the CI or SSH automation login and
`chia_darwin_allow_root_capable_service_user: true`, keep a NOPASSWD
`/etc/sudoers.d/` fragment for that service user, still outside the admin group.
That is a weaker posture than the Linux split and is off by default. The role
does not edit `/etc/sudoers.d`.

The playbook targets `mac_timelords`, not `localhost` with
`connection: local`. A controller with a checkout of this repository can run:

```bash
ansible-playbook -i inventory.yml playbooks/mac-timelords.yml
```

That controller may be a Mac or a Linux host. GitHub holds the reviewed role
code and CI; an always-on controller pulls `main` and applies it over SSH. No
self-hosted runner is installed on the timelord. The Mac equivalent of the
Linux SSH-managed host is the same privilege model: the admin account gets
passwordless sudo and Ansible runs commands through it. A one-time fragment
like this matches the Linux timelords:

```sudoers
# /etc/sudoers.d/<admin-user>
<admin-user> ALL=(ALL) NOPASSWD: ALL
```

The role does not edit `/etc/sudoers.d`. Apply that fragment only after the
owner approves the exact policy for the host. SSH should stay public-key only.
