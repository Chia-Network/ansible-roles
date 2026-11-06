# Darwin ASIC boards

`hw_vdf_client` drives one Chia VDF ASIC. Each board has three engines. The
client opens one timelord connection per engine bit set in `--vdfs-mask`. A
non-zero mask is used as given. The timelord needs three connections, so this
role assigns masks by how many boards are listed, in ID order:

| Boards | Masks                      |
| ------ | -------------------------- |
| 1      | 7                          |
| 2      | 3 on the lowest ID, then 1 |
| 3      | 1, 1, 1                    |

`N_VDFS` is the number of bits in that mask. It does not change the mask.
Frequency stays 1540 and voltage stays 1.0 on every board. `vdf_threads` and
`proof_threads` stay 12 and 11 per engine unless that board sets them. A
two-engine board uses about twice the CPU of a one-engine board at the same
pair. The role does not invent a new pair from the engine count.

This role does not discover USB devices. Read `hw_vdf_client --list` and copy
each location and serial into inventory. Location IDs change when cables or
hubs change. `--expected-serial` checks the board opened at `--device-loc`
and the client exits before it writes clock or voltage when the serial does
not match. It does not search the bus for a serial. `0` means the first
interface-A device, not a stable ID, and is allowed only when one board is
listed.

Each entry may contain only `id`, `device_loc`, `expected_serial`,
`vdf_threads`, and `proof_threads`.

## One board

Leave the list empty and set the scalar serial. The role keeps one
LaunchDaemon, `<prefix>.hw-vdf`, does not pass `--device-loc`, and uses
`chia_darwin_hw_vdf_mask` (default 7).

```yaml
chia_darwin_hw_vdf_boards: []
chia_darwin_hw_vdf_expected_serial: FIX-BOARD-0001
```

Or name the board. One entry uses mask 7 and passes `--device-loc`. Do not
set the scalar serial as well.

```yaml
chia_darwin_hw_vdf_expected_serial: ""
chia_darwin_hw_vdf_boards:
  - id: 1
    device_loc: 1101
    expected_serial: FIX-BOARD-0001
```

ID 1 is `<prefix>.hw-vdf`. IDs 2 and 3 are `<prefix>.hw-vdf-2` and
`<prefix>.hw-vdf-3`.

## Two boards

The lowest ID runs engines 0 and 1 (mask 3). The other runs engine 0 (mask
1). One engine on each board would leave a chain with no client. The optional
thread keys below apply only to that board; omit them to keep 12 and 11.

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
```

## Three boards

Each board runs engine 0 (mask 1).

```yaml
chia_darwin_hw_vdf_expected_serial: ""
chia_darwin_hw_vdf_boards:
  - id: 1
    device_loc: 1101
    expected_serial: FIX-BOARD-0001
  - id: 2
    device_loc: 1102
    expected_serial: FIX-BOARD-0002
  - id: 3
    device_loc: 1103
    expected_serial: FIX-BOARD-0003
```

IDs do not have to be contiguous. With IDs 1 and 3, ID 1 still runs two
engines. `<prefix>.hw-vdf-2` is stopped only when this role wrote that plist.

## Startup order

Every wrapper waits until the timelord port is listening, then sleeps
`chia_darwin_hw_vdf_settle_seconds` (3). The first board in ID order then
opens USB. Each later board waits another
`chia_darwin_hw_vdf_open_stagger` seconds (15) before it opens USB. Two
processes therefore do not enumerate FTDI at the same time on boot or when
they are started in one pass. A board that launchd restarts by itself does
not wait for the others. Set the stagger to 0 to open every board after the
shared settle.

Adding a board, or retrying when an enabled board is not loaded, stops the
loaded role-owned hw-vdf jobs and waits until they have exited. The restart
handler then starts every enabled board that is down, in ID order, after the
timelord. A loaded label this role does not own does not block that start,
and a second run does not bootstrap boards that are already loaded.
`--device-loc` is an option before the port and `N_VDFS` arguments.

## Logs, plists, and wrappers

| ID  | Label suffix | Wrapper                | Client log     | launchd stdout and stderr              |
| --- | ------------ | ---------------------- | -------------- | -------------------------------------- |
| 1   | `.hw-vdf`    | `chia-hw-vdf-run.sh`   | `hw-vdf.log`   | `hw-vdf.out.log`, `hw-vdf.err.log`     |
| 2   | `.hw-vdf-2`  | `chia-hw-vdf-2-run.sh` | `hw-vdf-2.log` | `hw-vdf-2.out.log`, `hw-vdf-2.err.log` |
| 3   | `.hw-vdf-3`  | `chia-hw-vdf-3-run.sh` | `hw-vdf-3.log` | `hw-vdf-3.out.log`, `hw-vdf-3.err.log` |

The prefix is `chia_darwin_launchd_prefix` (`net.chia.timelord` by default).
Client logs are under `chia_darwin_log_dir`. Removing a board stops its job
and deletes the plist and wrapper only when that plist runs this role's
wrapper. Other LaunchDaemons are not stopped or disabled. Old log files stay
where they are.

`start_now` and `start_on_boot` apply to every enabled board the same way
they apply to the daemon, full node, and timelord. The restart handler waits
for each job's `ExitTimeOut` plus `chia_darwin_restart_unload_margin` before
it bootstraps that job again.

If an enabled label already has a plist that does not run this role's
wrapper, the run fails and leaves that plist in place. Set
`chia_darwin_hw_vdf_claim_existing` to true to replace it.

## Rollout and rollback

1. Run `hw_vdf_client --list` and copy each location and serial.
2. Set `chia_darwin_hw_vdf_boards` and clear
   `chia_darwin_hw_vdf_expected_serial`. The role refuses both.
3. Run the playbook. ID 1 keeps `<prefix>.hw-vdf`. Dropped slots are removed
   only when this role wrote them.
4. Confirm the timelord has three client connections on port
   `chia_timelord_launcher_port` (8000 unless you changed it).

Rollback to one chosen board: leave a single inventory entry for that board
and run again. Clearing the list and setting only
`chia_darwin_hw_vdf_expected_serial` also returns to one job, without
`--device-loc`, so it opens the first device.

`remote-node` is unchanged. There is still no local full node, and every
ASIC client still connects to the local timelord.

## External watchdog

This role does not install or change an external watchdog. A watchdog that
expects three VDF connections and only restarts the ID 1 job
(`<prefix>.hw-vdf`) keeps doing only that. Boards 2 and 3 come back through
launchd `KeepAlive`. Keep the board that watchdog restarts as ID 1.

## What was not tested on hardware

CI uses a fake `launchctl` and rendered scripts. It does not open USB or load
a real LaunchDaemon. On a Mac, still check that `--list` matches inventory,
that a wrong serial exits before clock or voltage writes, that one, two, and
three boards publish 3, 2+1, and 1+1+1 connections, that the later boards
wait out the stagger, and that removing a board removes only that role-owned
job.
