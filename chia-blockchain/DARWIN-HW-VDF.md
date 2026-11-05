# Darwin ASIC boards

`hw_vdf_client` drives one Chia VDF ASIC. Each board has three engines. The
client opens one connection to the timelord for each engine bit set in
`--vdfs-mask`. A non-zero mask is used as given; the positional `N_VDFS`
does not change it. The timelord needs three connections.

This role does not discover USB devices. Read `hw_vdf_client --list` and put
the location id and serial in inventory. Location ids change when cables or
hubs change. `--expected-serial` checks the board opened at that location and
exits before the client writes clock or voltage if the serial does not match.
It does not search the bus for a serial. `0` is the first interface-A device,
not a stable id.

Frequency, voltage, and checkpoint stay the role defaults for every board
(1540 MHz, 1.0 V, checkpoint 500000). Those are not the chiavdf defaults.
`vdf_threads` and `proof_threads` are host threads **per engine** and stay 12
and 11 unless a board entry overrides that pair. A two-engine board therefore
uses about twice the CPU of a one-engine board. The role does not derive a
new pair from the engine count.

## One board

Leave `chia_darwin_hw_vdf_boards` empty and set the scalar serial. The role
keeps one LaunchDaemon, `<prefix>.hw-vdf`, does not pass `--device-loc`, and
uses `chia_darwin_hw_vdf_mask` (default 7, three engines).

```yaml
chia_darwin_hw_vdf_boards: []
chia_darwin_hw_vdf_expected_serial: FIX-BOARD-0001
```

Or name the board. One entry uses mask 7 and passes `--device-loc`, including
`0`. Do not set the scalar serial as well.

```yaml
chia_darwin_hw_vdf_expected_serial: ""
chia_darwin_hw_vdf_boards:
  - id: 1
    device_loc: 1101
    expected_serial: FIX-BOARD-0001
```

`id: 1` is the existing label `<prefix>.hw-vdf`. Ids 2 and 3 are
`<prefix>.hw-vdf-2` and `<prefix>.hw-vdf-3`.

## Two boards

The lowest id runs engines 0 and 1 (mask 3, `N_VDFS` 2). The other runs
engine 0 (mask 1, `N_VDFS` 1). That is three connections. One engine on each
board would leave a chain with no client. The example below also sets a
smaller thread pair on the two-engine board; omit those keys to keep 12 and 11.

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

Each board runs engine 0 (mask 1, `N_VDFS` 1).

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

Ids do not have to be contiguous. With ids 1 and 3, id 1 still runs two
engines and `<prefix>.hw-vdf-2` is stopped if this role owns it.

## Startup order

`--device-loc` selects the board. The client can still enumerate the FTDI bus
while it opens that location. On macOS, enumerating from two processes at once
has dropped the USB devices. Each later wrapper waits until the previous
board's client log shows `Connected to timelord` after this role's
`opening USB` line. The wait also reads the first rotated log. Board id order
is the start order, including boot.

`chia_darwin_hw_vdf_sequence_opens` defaults to true.
`chia_darwin_hw_vdf_peer_wait_attempts` defaults to 0, which waits the same
way the wrappers wait for the timelord port. Set it to a positive number to
make the wrapper exit so launchd's `ThrottleInterval` can retry. A board that
is waiting has not opened USB. launchd does not treat that wait as a crash.

## Logs, plists, and wrappers

| Id | Label suffix | Wrapper | Client log | launchd stdout/stderr |
| --- | --- | --- | --- | --- |
| 1 | `.hw-vdf` | `chia-hw-vdf-run.sh` | `hw-vdf.log` | `hw-vdf.out.log`, `hw-vdf.err.log` |
| 2 | `.hw-vdf-2` | `chia-hw-vdf-2-run.sh` | `hw-vdf-2.log` | `hw-vdf-2.out.log`, `hw-vdf-2.err.log` |
| 3 | `.hw-vdf-3` | `chia-hw-vdf-3-run.sh` | `hw-vdf-3.log` | `hw-vdf-3.out.log`, `hw-vdf-3.err.log` |

The prefix is `chia_darwin_launchd_prefix` (`net.chia.timelord` by default).
Client logs are under `chia_darwin_log_dir`. Removing a board stops its job
and deletes the role-owned plist and wrapper. The log files are left in place.
A LaunchDaemon whose plist does not contain this role's wrapper path is not
stopped, disabled, or deleted.

`start_now` and `start_on_boot` apply to every enabled board the same way they
apply to the daemon, full node, and timelord. The restart handler waits for
each job's `ExitTimeOut` plus `chia_darwin_restart_unload_margin` before it
bootstraps that job again.

## Rollout and rollback

1. Run `hw_vdf_client --list` and copy each location and serial. Do not put
   another machine's ids in inventory.
2. Set `chia_darwin_hw_vdf_boards` and clear
   `chia_darwin_hw_vdf_expected_serial`. The role refuses both.
3. Run the playbook. Id 1 keeps `<prefix>.hw-vdf`. New ids are created. Slots
   you dropped are removed only when this role wrote them.
4. Confirm the timelord has three client connections on
   `chia_timelord_launcher_port` (8000 unless you changed it).

Rollback to one specific board: leave a single inventory entry for that board
(mask 7, with its `device_loc` and serial) and run again. Clearing the list
and setting only `chia_darwin_hw_vdf_expected_serial` also returns to one job,
but that path omits `--device-loc` and opens the first device.

Switching between one, two, and three boards is a rerun. Engine masks are
reassigned from the count. `remote-node` is unchanged: there is still no local
full node, and every ASIC client still connects to the local timelord.

## External watchdog

This role does not install, query, or update an external watchdog. A watchdog
that already expects three VDF connections, and that only restarts
`<prefix>.hw-vdf` (board id 1), keeps doing only that. Boards 2 and 3 come
back through launchd `KeepAlive`. Adding or removing boards does not change
the watchdog. Keep the board that watchdog restarts as id 1.

## What this was not tested against

CI uses a fake `launchctl` and rendered scripts. It does not open USB, load a
real LaunchDaemon, or run `hw_vdf_client` against a board. Before relying on a
Mac, check:

- `--list` locations match inventory, and a wrong serial exits without
  changing that board's clock or voltage.
- One board still publishes three connections with mask 7.
- Two boards publish two connections and one connection, and the second
  process does not open USB until the first has connected.
- Three boards each publish one connection, including after reboot.
- Removing a board removes only that role-owned job and wrapper.
- `start_now` and `start_on_boot` match the other LaunchDaemons.
- The external watchdog still restarts only id 1, and ids 2 and 3 recover
  through launchd.
