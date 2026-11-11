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
posture. Set `chia_darwin_brew_user` so Homebrew runs as the prefix owner. The
same inventory entry shape covers additional Macs. See
[DARWIN-HW-VDF.md](DARWIN-HW-VDF.md#companion-services) for the service table,
watchdog behavior, binary pins, and the approved-sudoers note.

With `chia_darwin_timelord_implementation: chia-blockchain`, the role can also
run a `vdf-only` topology: only the ASIC `hw-vdf` board jobs are installed. Set `chia_darwin_hw_vdf_ip` to the remote timelord's VDF server.
There is no local daemon, full node, timelord, chia-exporter, or healthcheck.
The watchdog still supervises the board LaunchDaemons and checks the remote VDF
connection count through `chia_darwin_hw_vdf_port`.

## Timelord.app (optional Darwin implementation)

Set `chia_darwin_timelord_implementation: timelord-app` to run the signed
[Timelord.app](https://github.com/Chia-Network/timelord-app/releases/tag/v1.0.0)
instead of the Python timelord. The default remains `chia-blockchain`, so
existing plays are unchanged. The app is arm64-only and requires macOS 14 or
later. The role pins version `1.0.0` and its DMG checksum, verifies the bundle
with `codesign --verify --deep --strict`, and installs it at
`/Applications/Timelord.app`. The upstream repository is private. Set
`chia_darwin_timelord_app_github_token` (read access to the private repository)
to use the pinned GitHub API asset (`chia_darwin_timelord_app_asset_id`), override
`chia_darwin_timelord_app_dmg_url` with an internal mirror, or set
`chia_darwin_timelord_app_download: false` and place the pinned DMG at
`chia_darwin_timelord_app_dmg` before the play. The role still verifies its
SHA256.

The app owns both the timelord worker and the bundled `hw_vdf_client` ASIC
clients. Role-managed `hw-vdf` jobs are refused in this mode, and the app's
hardware registry and learned tuning stay app-owned. The app config is
`~/Library/Application Support/Timelord/config.toml`; the vendor LaunchDaemon
label is fixed at `net.chia.timelord.supervisor`, independent of
`chia_darwin_launchd_prefix`. Worker status listens on `127.0.0.1:9257`.

The app is the timelord monitoring source, including the Linux IPS series:
`chia_timelord_estimated_ips`, `chain_estimated_ips`, `raw_ips`, verified-proof
counters, submission timestamps, thermals, recoveries, chain availability, and
the supervisor metrics. `chia_darwin_timelord_app_expose_observability` defaults
to true, which enables the app deployment listener on `0.0.0.0:9258` and the
supervisor listener on `0.0.0.0:9259` with `allow_remote_observability = true`.
Set it false to keep the supervisor and probes on loopback and omit the 9258
listener. The listeners have no authentication or TLS; restrict them to a
private monitoring network or put an authenticated reverse proxy in front.

A scrape configuration mirroring the upstream examples:

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

Do not keep scraping a legacy timelord exporter as the same logical instance;
the app's `chia_timelord_*` series replaces it. Re-point timelord probes from
`chia-healthcheck`'s `/timelord` to the app's `/healthz` (liveness) or
`/readyz` (readiness) on 9258/9259, which mirrors the Linux probe semantics.
Full-node metrics still come from `chia-exporter` on local topologies.

| Topology         | What runs                                                                        |
| ---------------- | -------------------------------------------------------------------------------- |
| `local-internal` | Role-managed daemon/full node plus the app and its ASIC clients.                 |
| `local-external` | Same, with `~/.chia` on `chia_darwin_db_volume`; Full Disk Access still applies. |
| `remote-node`    | The app only. No Python, chia-blockchain, daemon, full node, or local CHIA_ROOT. |
| `vdf-only`       | Refused with `timelord-app`; use `chia-blockchain` for ASIC-only Macs.           |

`local-*` app deployments still install the role-managed full node and daemon.
`remote-node` app deployments skip the Homebrew Python, virtualenv,
chia-blockchain install, and CHIA_ROOT setup entirely. They require a connection
bundle created on the full-node host:

```yaml
chia_darwin_timelord_implementation: timelord-app
chia_darwin_topology: remote-node
# A directory already on the Mac:
chia_darwin_timelord_app_bundle_path: "/Users/timelord/timelord-connection"
# Or a controller directory copied to the Mac:
# chia_darwin_timelord_app_bundle_src: "files/timelord-mainnet-connection"
```

The bundle must contain `connection.toml` and the dedicated peer and optional
RPC identities. Create it with the node's Chia Python as described in
[the upstream connection-bundle guide](https://github.com/Chia-Network/timelord-app/blob/v1.0.0/docs/connection-bundles.md).
The role imports it with `timelord-service import-node` only when the bundle
content fingerprint changes, so repeated runs do not create a new identity
directory. Role-managed `local-*` deployments use
`timelord-service local-node` against the existing CHIA_ROOT instead.

The role renders the complete app config only when it is missing or
`chia_darwin_timelord_app_force_config: true`. Node changes then use the app's
own `local-node`/`import-node` commands and a reload, preserving app-written
boards and learned tuning. Setting `force_config` replaces that state.
`chia_darwin_timelord_app_prune_identities` (default true) removes identity
directories left by earlier imports while keeping references from the live
config and the supervisor's `last-good.toml`.

In app mode the role keeps `chia-exporter` only for a local full node's
`chia_full_node_*` metrics. It also keeps `chia-healthcheck` on local
topologies for `/full_node` and `/full_node/ports`. Its `/timelord` endpoint is
not a generic HTTP check: it subscribes to the Chia daemon websocket and only
recognizes `finished_pot` from `chia_timelord`. The app is not that RPC service,
so this is a protocol mismatch rather than a missing app metric. The app's own
`/healthz`, `/readyz`, and `chia_timelord_*` series cover the timelord and use
the same IPS/proof metric names, so dashboards and alerts carry over; only the
probe and scrape targets change. `remote-node` app deployments disable
`chia-healthcheck` entirely because there is no local full node or `CHIA_ROOT`
to check. The watchdog also checks the app supervisor and worker `/healthz`
endpoints and, for local topologies, that the full-node LaunchDaemon is still
running. Restarting the app is done through
`launchctl kickstart system/net.chia.timelord.supervisor`; the supervisor then
replaces its worker. Switching back to `chia-blockchain` unregisters the app
service if this role registered it, but leaves the app bundle, config, and
credentials in place.

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
