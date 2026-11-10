# smartctl-exporter

Installs and runs [smartctl_exporter](https://github.com/prometheus-community/smartctl_exporter)
so Prometheus can scrape S.M.A.R.T. disk metrics.

## Linux

The role installs `smartmontools` with the system package manager, downloads
the pinned `linux-amd64` release to `/opt/smartctl_exporter`, and runs the
`smartctl_exporter` systemd service on port `9633`.

## Darwin

The role installs `smartmontools` with Homebrew (so `smartctl` exists for the
Apple Silicon disk stack) and runs a root LaunchDaemon named
`net.chia.smartctl_exporter` on port `9633`. The exporter binary is a pinned
`darwin-arm64` (or `darwin-amd64`) release with a SHA-256 checksum.

| Variable                                   | Default                      | Description                                       |
| ------------------------------------------ | ---------------------------- | ------------------------------------------------- |
| `smartctl_exporter_version`                | `0.14.0`                     | Linux release version.                            |
| `smartctl_exporter_port`                   | `9633`                       | Web listen port on both platforms.                |
| `smartctl_exporter_darwin_version`         | `0.15.0`                     | Darwin release version.                           |
| `smartctl_exporter_darwin_homebrew_prefix` | `/opt/homebrew`              | Homebrew prefix.                                  |
| `smartctl_exporter_darwin_brew_user`       | `""`                         | Homebrew prefix owner when the SSH login differs. |
| `smartctl_exporter_darwin_launchd_label`   | `net.chia.smartctl_exporter` | LaunchDaemon label.                               |

The Darwin job runs as root because `smartctl` needs raw disk access. Set
`smartctl_exporter_darwin_brew_user` when the controller logs in as an account
that does not own the Homebrew prefix.
