# Darwin ASIC boards

`hw_vdf_client` opens one timelord connection per bit set in `--vdfs-mask`. A
non-zero mask is used as given. The timelord needs three connections, so masks
follow the board count, in ID order: one board uses 7, two boards use 3 on the
lowest ID and 1 on the other, and three boards use 1 each. `N_VDFS` is the
popcount of that mask. Frequency stays 1540 and voltage stays 1.0. `vdf_threads`
and `proof_threads` stay 12 and 11 unless that board sets them.

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
It enumerates every FT4222 interface, not only Chia boards. Auto-discovery
keeps only interface-A Chia ASIC serials that match `^CHIA[0-9]{10}A$`: the
`CHIA` prefix, ten digits, and a trailing `A`. Rows for other FT4222 devices,
including rows with an empty serial, are valid output and are ignored.
`--expected-serial` accepts either the printed `CHIA...A` form or the base
form without that final `A`.

Claimed wrappers and `--list` rows are compared by one canonical interface-A
identity. A serial gains a final `A` only when the result matches the Chia
pattern; no other suffix is stripped or rewritten. Newly discovered boards
keep the base form that earlier releases wrote, and an already claimed
wrapper keeps the SERIAL spelling it already has. That keeps existing
wrappers stable while a wrapper written from an explicit full `CHIA...A`
inventory still matches the same visible board instead of being counted
twice.

A board held open by a running `hw_vdf_client` does not appear in `--list`.
Discovery therefore treats this role's installed wrappers at the three
role-owned slot paths as the persisted board inventory. It reads them as text;
it never sources or executes them. A wrapper is reused only when it is at one
of those exact paths and carries the role's management marker. Merge is by
serial:

- A claimed board keeps its existing ID. If `--list` can see it, the printed
  `loc` replaces the stored one. If it is hidden, the stored location is kept.
- A new serial takes the next free ID, in serial order when several boards are
  new. Existing IDs are not renumbered.
- Adding or removing a board changes the board count, so masks can change
  naturally. IDs do not move.

This preserves IDs, masks, wrappers, and loaded jobs when every board is held
(header-only `--list`) or only some are held. Discovery fails when the merged
set is empty or has more than 3 boards, when `--list` exits non-zero (including
`No FTDI devices connected.`), or when its output cannot be parsed. A zero exit
with only the header is success when wrappers already claim boards; with no
claimed boards it fails as an empty merged set. It also fails if a role-owned
wrapper cannot be read or a per-board wrapper has an invalid SERIAL or
DEVICE_LOC, so a partial read cannot silently retire a board. A legacy wrapper
without DEVICE_LOC is ignored.

Limitations: a held board's location cannot be refreshed because `--list`
cannot see it, so it keeps the location from its wrapper. A claimed board that
is no longer attached also stays in the set; remove it intentionally with an
explicit `chia_darwin_hw_vdf_boards` list.

Example `--list` output (example only, not captured from a real host):

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
the service jobs, and then starts the boards again in ID order. A loaded label
this role does not own is left alone. A second run does not bootstrap boards
that are already loaded.

| ID  | Label suffix | Wrapper                | Client log     |
| --- | ------------ | ---------------------- | -------------- |
| 1   | `.hw-vdf`    | `chia-hw-vdf-run.sh`   | `hw-vdf.log`   |
| 2   | `.hw-vdf-2`  | `chia-hw-vdf-2-run.sh` | `hw-vdf-2.log` |
| 3   | `.hw-vdf-3`  | `chia-hw-vdf-3-run.sh` | `hw-vdf-3.log` |

The prefix is `chia_darwin_launchd_prefix` (`net.chia.timelord` by default).
Launchd also writes `<name>.out.log` and `<name>.err.log`. Client logs are under
`chia_darwin_log_dir`. Removing a board stops its job and deletes the plist and
wrapper only when that plist runs this role's wrapper. If an enabled label
already has some other plist, the run fails until
`chia_darwin_hw_vdf_claim_existing` is true. `start_now` and `start_on_boot`
apply to every enabled board. The restart handler waits for each job's
`ExitTimeOut` plus `chia_darwin_restart_unload_margin` before bootstrap.

Rollout: leave `chia_darwin_hw_vdf_boards` empty and clear
`chia_darwin_hw_vdf_expected_serial` to let the role discover boards with
`hw_vdf_client --list` and its installed wrappers. To pin locations, run
`hw_vdf_client --list`, set `chia_darwin_hw_vdf_boards`, and clear
`chia_darwin_hw_vdf_expected_serial`. Use an explicit list to remove a board
that discovery still sees in a retained wrapper. ID 1 keeps
`<prefix>.hw-vdf`. Confirm three client connections on
`chia_timelord_launcher_port` (8000 unless you changed it). Rollback to one
board by leaving a single inventory entry, by clearing the list and setting
only the scalar serial (which omits `--device-loc`), or by attaching one board
for auto-discovery. `remote-node` still has no local full node, and every ASIC
client still connects to the local timelord.

This role does not install or change an external watchdog. A watchdog that
expects three VDF connections and only restarts the ID 1 job keeps doing only
that. Boards 2 and 3 come back through launchd `KeepAlive`. Keep the board that
watchdog restarts as ID 1.
