# chia-blockchain

## Darwin full-node database seeding

Darwin `local-internal` and `local-external` full nodes can optionally start
from the same uncompressed S3 snapshot layout the Linux tasks use. This is
initial seeding, not integrity repair and not an ongoing snapshot refresh. The
role never replaces an existing non-stub database, and it does not check the
health of a large existing database.

`remote-node` never seeds because it does not run a local full node. If
`download_blockchain_db` is false or `blockchain_backup_bucket` is empty, the
node keeps its normal syncing behavior.

### Variables

The Darwin seed reuses the existing Linux variables:

| Variable                   | Purpose                                                                            |
| -------------------------- | ---------------------------------------------------------------------------------- |
| `download_blockchain_db`   | Enables initial database seeding. Defaults to `true`.                              |
| `blockchain_backup_bucket` | S3 bucket holding `<network>/` snapshots. Defaults to empty, which skips seeding.  |
| `network`                  | Selects the S3 prefix and the `blockchain_<db_version>_<network>.sqlite` filename. |
| `db_version`               | Database version in the filename. Defaults to `v2`.                                |

Darwin-specific settings:

| Variable                         | Default                 | Purpose                                                                      |
| -------------------------------- | ----------------------- | ---------------------------------------------------------------------------- |
| `chia_darwin_aws`                | `/opt/homebrew/bin/aws` | AWS CLI binary used by the seed.                                             |
| `chia_darwin_awscli_formula`     | `awscli`                | Homebrew formula installed when seeding is needed and the binary is missing. |
| `chia_darwin_db_seed_stub_bytes` | `10240`                 | Largest regular file treated as a `chia init` stub.                          |
| `chia_darwin_mount_binary`       | `/sbin/mount`           | Command used to confirm the external volume is mounted.                      |

### Prerequisites and credentials

The snapshot bucket must contain these three objects under `<network>/`:

- `blockchain_<db_version>_<network>.sqlite` - main blockchain database
- `height-to-hash` - height-to-hash cache
- `sub-epoch-summaries` - sub-epoch summary cache

Chia can regenerate the two caches if they are missing, but this role requires
all three copies to succeed before publishing anything. When replacing a
database, the caches are replaced with the matching snapshot so an old cache is
not left beside a new main database.

The AWS CLI is installed with Homebrew only when a seed is actually needed.
Credentials use the AWS CLI's normal discovery as the service user (`user`), for
example that user's `~/.aws` files, environment variables supplied by the
operator, or another standard AWS credential source. The role does not create,
copy, or print credentials.

For `local-external`, the external volume must already be mounted and readable.
The role checks the mount before staging anything and never falls back to
writing the database on the internal disk.

### Skip and overwrite rules

The role seeds only when all of these are true:

- topology is `local-internal` or `local-external`
- `download_blockchain_db` is true
- `blockchain_backup_bucket` is nonempty
- the main database is absent, or is a regular file of at most
  `chia_darwin_db_seed_stub_bytes`

An existing larger database is left untouched, including its caches. A
directory or symlink at the main database path is also left untouched. A small
regular file (the stub created by `chia init`) is replaced only after the whole
snapshot has downloaded successfully. Cache paths that are directories or
symlinks are refused rather than deleted.

If the full-node LaunchDaemon is already loaded when a seed is needed, the role
fails before touching the database. Stop that job and rerun:

```sh
sudo launchctl bootout system/net.chia.timelord.full-node
```

A second run after a successful seed finds a non-stub database, downloads
nothing, changes no files, and does not restart services.

### Staging, disk space, and recovery

All three objects are downloaded into a hidden staging directory under the
destination `db` directory, on the same filesystem as the final paths. Each file
is then published with an atomic rename, with the main database last. A failed
or interrupted download therefore leaves the previous database (or the stub)
in place; the next run retries. Ownership is set to the service user and group
with mode `0644`.

While staging, the volume needs free space for the whole snapshot in addition to
the existing files. Once the files are renamed, the staged copy becomes the
database, so the extra space is only needed during the seed. Replacing an
existing stub adds no meaningful old-database space.

After a failure, check S3 access as the service user, available disk space, and
(for `local-external`) that the volume is mounted. Remove nothing by hand:
rerunning the role removes its own leftover staging directory and starts over.
