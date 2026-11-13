# tailscale

Darwin-only role that keeps a role-owned LaunchDaemon file for `tailscaled` at
`/Library/LaunchDaemons/net.chia.tailscaled.plist`. On Linux the role does
nothing.

This role never starts, stops, loads, bootstraps, kickstarts, or restarts
`tailscaled`. CI reaches the host over Tailscale SSH, so bouncing the daemon
would drop the session. The first cutover and every later daemon restart are
manual runbook steps; see `m6-tailscale-brew-paths.md`.

## Requirements

- macOS with Homebrew at `/opt/homebrew` (override with
  `tailscale_darwin_homebrew_prefix`).
- Ansible runs as the Homebrew prefix owner, normally the SSH connection user.
  Do not run the brew tasks as another account.
- The pinned `tailscale` formula. Install it only when missing, then pin it:

  ```sh
  brew install tailscale
  brew pin tailscale
  ```

  An unpinned upgrade would replace the binary and drop the Full Disk Access
  grant that the LaunchDaemon needs.

- A running `net.chia.tailscaled` LaunchDaemon, created by the manual M6
  runbook before this role is applied.

## Behavior

- Requires Homebrew at `{{ tailscale_darwin_brew }}`.
- Runs `brew list --versions tailscale` and installs the formula only when it
  is missing.
- Runs `brew list --pinned` and fails unless `tailscale` is pinned.
- Requires an executable `tailscaled` at
  `/opt/homebrew/opt/tailscale/bin/tailscaled`.
- Templates the LaunchDaemon as `root:wheel` with mode `0644` and validates it
  with `plutil -lint`.
- Fails if any competing job is present: `sh.brew.tailscale`,
  `homebrew.mxcl.tailscale`, or `com.tailscale.tailscaled`.
- Fails unless `net.chia.tailscaled` is running with a live process. It only
  verifies the job; it never starts it.

## Homebrew services

Never use `sudo brew services` for this formula. It chowns Homebrew keg paths to
`root:admin` and creates a competing job. A human running
`sudo brew services start tailscale` would resurrect that competing job, so the
role fails closed whenever `sh.brew.tailscale`, `homebrew.mxcl.tailscale`, or
`com.tailscale.tailscaled` is loaded.

## Secrets

This role stores no auth keys or secrets. Authenticate with `tailscale up`
manually as part of the runbook.

## Variables

| Variable                           | Default                                                               | Description                                   |
| ---------------------------------- | --------------------------------------------------------------------- | --------------------------------------------- |
| `tailscale_darwin_homebrew_prefix` | `/opt/homebrew`                                                       | Homebrew prefix.                              |
| `tailscale_darwin_brew`            | `{{ tailscale_darwin_homebrew_prefix }}/bin/brew`                     | Homebrew executable.                          |
| `tailscale_darwin_formula`         | `tailscale`                                                           | Formula name that must be pinned.             |
| `tailscale_darwin_binary`          | `{{ tailscale_darwin_homebrew_prefix }}/opt/tailscale/bin/tailscaled` | Required tailscaled binary.                   |
| `tailscale_darwin_launchd_dir`     | `/Library/LaunchDaemons`                                              | LaunchDaemon directory.                       |
| `tailscale_darwin_launchd_label`   | `net.chia.tailscaled`                                                 | Role-owned LaunchDaemon label.                |
| `tailscale_darwin_launchctl`       | `/bin/launchctl`                                                      | launchctl executable.                         |
| `tailscale_darwin_socket`          | `/var/run/tailscaled.socket`                                          | Socket passed to tailscaled.                  |
| `tailscale_darwin_log_dir`         | `/var/log`                                                            | Directory for the plist log paths.            |
| `tailscale_darwin_stdout_log`      | `{{ tailscale_darwin_log_dir }}/tailscaled.out.log`                   | Standard output log path.                     |
| `tailscale_darwin_stderr_log`      | `{{ tailscale_darwin_log_dir }}/tailscaled.err.log`                   | Standard error log path.                      |
| `tailscale_darwin_path`            | Homebrew bin plus system paths                                        | `PATH` in the LaunchDaemon environment.       |
| `tailscale_darwin_become`          | `true`                                                                | Use sudo for LaunchDaemon and launchctl work. |
| `tailscale_darwin_owner`           | `root`                                                                | Plist owner.                                  |
| `tailscale_darwin_group`           | `wheel`                                                               | Plist group.                                  |

The LaunchDaemon does not pass `--state` or `--statedir`; Darwin's default state
lives at `/Library/Tailscale/tailscaled.state`.
