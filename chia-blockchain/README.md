# chia-blockchain

## Darwin companion services

The Darwin tasks own the timelord stack's companion LaunchDaemons as well as
the chia services: `chia-exporter` (9914), `chia-healthcheck` (9950),
`node-exporter` (9100), and the root-run `chia-watchdog` that mirrors the Linux
monit checks. Binaries are pinned GitHub release artifacts, not Homebrew
services, and run as the same non-admin service account as the daemons. Set
`chia_darwin_enable_chia_exporter`, `chia_darwin_enable_chia_healthcheck`,
`chia_darwin_enable_node_exporter`, or `chia_darwin_enable_watchdog` to false to
boot out and remove the role's plist at that label; installed binaries and
wrappers are left in place.

The role also documents the SSH-managed controller pattern used by the Linux
timelords. Run the playbook against an inventory of Macs over SSH as an account
with passwordless sudo; do not install a self-hosted runner on the timelord.
Keep that SSH/sudo account separate from the service account. If the only
practical SSH login is the service account, set
`chia_darwin_allow_root_capable_service_user: true` and accept the weaker
posture. By default, remove any `/etc/sudoers.d/` rule for the service account
so only the separate admin account has sudo. Exception: when the service account
is also the CI or SSH automation login and
`chia_darwin_allow_root_capable_service_user: true`, keep a NOPASSWD fragment
for it, still outside the admin group. That weaker posture is off by default and
the role does not edit `/etc/sudoers.d`. Set `chia_darwin_brew_user` so Homebrew
runs as the prefix owner. The same inventory entry shape covers additional Macs.
See [DARWIN-HW-VDF.md](DARWIN-HW-VDF.md#companion-services) for the service table,
watchdog behavior, binary pins, and Full Disk Access for the companion binaries.
See [DARWIN-HW-VDF.md](DARWIN-HW-VDF.md#managing-several-macs) for the
approved-sudoers note and leftover service-account sudoers fragments.

With `chia_darwin_timelord_implementation: chia-blockchain`, the role can also
run a `vdf-only` topology: only the ASIC `hw-vdf` board jobs are installed. Set `chia_darwin_hw_vdf_ip` to the remote timelord's VDF server.
There is no local daemon, full node, timelord, chia-exporter, or healthcheck.
The watchdog still supervises the board LaunchDaemons and checks the remote VDF
connection count through `chia_darwin_hw_vdf_port`.

## Timelord.app (optional implementation)

| Topology         | What runs                                                                        |
| ---------------- | -------------------------------------------------------------------------------- |
| `local-internal` | Role-managed daemon/full node plus the app and its ASIC clients.                 |
| `local-external` | Same, with `~/.chia` on `chia_darwin_db_volume`; Full Disk Access still applies. |
| `remote-node`    | The app only. No Python, chia-blockchain, daemon, full node, or local CHIA_ROOT. |
| `vdf-only`       | Refused with `timelord-app`; use `chia-blockchain` for ASIC-only Macs.           |

Remote-node deployments require a connection bundle created on the full-node host:

```yaml
chia_darwin_timelord_implementation: timelord-app
chia_darwin_topology: remote-node
# A directory already on the Mac:
chia_darwin_timelord_app_bundle_path: "/Users/timelord/timelord-connection"
# Or a controller directory copied to the Mac:
# chia_darwin_timelord_app_bundle_src: "files/timelord-mainnet-connection"
```

See [DARWIN-HW-VDF.md](DARWIN-HW-VDF.md#timelordapp) for download options,
configuration, observability, and pruning.

The Darwin watchdog matches the Linux monit defaults more closely than earlier
releases: `chia_darwin_watchdog_grace` is the 3600-second boot delay, and
`chia_darwin_watchdog_restart_grace` is the 600-second post-restart delay. The
watchdog checks `/full_node/ports` only when a local full node exists, and it
raises Chia to DEBUG after `chia_darwin_watchdog_log_debug_threshold` failed
health checks. Set `chia_darwin_watchdog_alert_token` and
`chia_darwin_watchdog_webhook_url` together; a half-configured sink is refused.
The role removes stale alert files when both are empty, and logs the skipped
alert description to the watchdog log. Set `chia_periodic_connect_peers` to
install the launchd periodic full-node peer connect job (every
`chia_darwin_periodic_connect_interval_seconds`).

Darwin hosts use the shared `log_level` and `target_outbound_peer_count`
inventory variables. Set them in the Darwin host or group vars (for example,
`log_level: INFO` and `target_outbound_peer_count: 30` to match the Linux
timelord fleet); the role does not override them.

The role also applies the Linux-style VDF tuning flags:
`chia_darwin_hw_vdf_max_freq` and `chia_darwin_hw_vdf_auto_freq_period` are
passed to `hw_vdf_client` when greater than zero.

## Darwin full-node database seeding

Darwin `local-internal` and `local-external` full nodes can optionally seed from
the uncompressed S3 snapshot layout used by the Linux tasks. This is initial
seeding, not integrity repair or an ongoing refresh, and the role does not check
the health of an existing large database. `remote-node` and `vdf-only` never
seed because they have no local full node. The seed reuses `download_blockchain_db`,
`blockchain_backup_bucket`, `network` (S3 prefix and
`blockchain_<db_version>_<network>.sqlite` filename), and `db_version`, and is
skipped when seeding is disabled or the bucket is empty.

| Darwin variable                  | Default                 | Purpose                                             |
| -------------------------------- | ----------------------- | --------------------------------------------------- |
| `chia_darwin_aws`                | `/opt/homebrew/bin/aws` | AWS CLI binary.                                     |
| `chia_darwin_awscli_formula`     | `awscli`                | Formula installed only when a seed is needed.       |
| `chia_darwin_db_seed_stub_bytes` | `10240`                 | Largest regular file treated as a `chia init` stub. |

The bucket needs `blockchain_<db_version>_<network>.sqlite`, `height-to-hash`,
and `sub-epoch-summaries` under `<network>/`. Chia can regenerate the caches, but
this role requires all three downloads to succeed so an old cache is not left
beside a new main database. Credentials use the AWS CLI's normal discovery as the
service user (`user`); the role never creates, copies, or prints them. For
`local-external`, the volume must already be mounted and readable, and the role
never falls back to writing the database on the internal disk.

The role seeds only when the topology is local, seeding is enabled, the bucket is
nonempty, and the main database is absent or a regular file of at most
`chia_darwin_db_seed_stub_bytes`. An existing larger database, or a directory or
symlink at the main database path, is left untouched and the seed is skipped; a
directory or symlink at a cache path is refused rather than deleted. A stub is
replaced only after the whole snapshot downloads successfully. If the full-node
LaunchDaemon is loaded, the role fails before touching the database:

```sh
sudo launchctl bootout system/net.chia.timelord.full-node
```

All three objects are downloaded to a hidden staging directory under the
destination `db` directory, sharing a filesystem with the final paths. Each file
is published with an atomic rename, main database last. Stale `-wal`, `-shm`,
and `-journal` sidecars beside the stub are removed before that main rename.
Publish steps run as the service user with mode `0644`, for consistent
ownership. A failed or interrupted download leaves the previous database (or the
stub) in place; the next run removes its leftover staging directory and retries.

The volume needs room for the whole snapshot while staging; after the renames
the staged copy becomes the database. After a failure, check S3 access as the
service user, free disk space, and for `local-external` that the volume is
mounted. A refused cache directory or symlink must be moved aside by the
operator before retry. A second successful run finds a non-stub database,
downloads nothing, changes no files, and does not restart services.
