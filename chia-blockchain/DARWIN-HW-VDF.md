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

This role does not install or change an external watchdog. A watchdog that
expects three VDF connections and only restarts the ID 1 job keeps doing only
that. Boards 2 and 3 come back through launchd `KeepAlive`. Keep the board that
watchdog restarts as ID 1.
