# tailscale

Darwin-only role that owns the `net.chia.tailscaled` LaunchDaemon file at
`/Library/LaunchDaemons/net.chia.tailscaled.plist`. On Linux the role does
nothing.

The `tailscale` Homebrew formula must stay pinned. An unpinned upgrade replaces
the binary and drops the Full Disk Access grant the daemon needs:

```sh
brew pin tailscale
```

Never use `sudo brew services` for this formula. It changes Homebrew keg
ownership and creates a competing job; the role fails if anything other than
`net.chia.tailscaled.plist` matches `/Library/LaunchDaemons/*tailscale*.plist`.

This role never starts, restarts, loads, or unloads `tailscaled`; it only
verifies the pin and the running job. Installing and authenticating the daemon
is a manual operator runbook step; this role does not perform it.

`files/net.chia.tailscaled.plist` is the single source for the unit. The role
stores no auth keys or secrets; authenticate with `tailscale up` in the runbook.

Brew commands run with `become: false` because the Darwin play may set
`become: yes`; Homebrew refuses to run as root.
