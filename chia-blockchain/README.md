# chia-blockchain

## Darwin full-node database seeding

Darwin `local-internal` and `local-external` full nodes can optionally seed from
the uncompressed S3 snapshot layout used by the Linux tasks. This is initial
seeding, not integrity repair or an ongoing refresh, and the role does not check
the health of an existing large database. `remote-node` never seeds because it
has no local full node. The seed reuses `download_blockchain_db`,
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
`chia_darwin_db_seed_stub_bytes`. An existing larger database and its caches are
left untouched; a directory or symlink at the main or cache path is refused
rather than deleted. A stub is replaced only after the whole snapshot downloads
successfully. If the full-node LaunchDaemon is loaded, the role fails before
touching the database:

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
mounted. A refused destination directory or symlink must be moved aside by the
operator before retry. A second successful run finds a non-stub database,
downloads nothing, changes no files, and does not restart services.
