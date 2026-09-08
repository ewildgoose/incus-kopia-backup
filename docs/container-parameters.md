# Instance parameters

All settings are Incus/LXD `user.backup.*` keys on the instance. They are
host-side metadata: a guest cannot change them. The scripts read the expanded
configuration, so keys set in a profile apply to every instance that uses the
profile. Only `user.backup.hostname` must be set per instance.

| Key                                  | Default       | Read by             | Meaning                                                                 |
|--------------------------------------|---------------|---------------------|-------------------------------------------------------------------------|
| `user.backup.enabled`                | (unset = off) | scheduler           | `true`, `yes`, `on` or `1` lets the scheduler back up the instance      |
| `user.backup.hostname`               | required      | all                 | stable FQDN of the thing backed up; identity is `backup@<this>`         |
| `user.backup.interval`               | `24h`         | scheduler           | minimum time since the last complete success; suffix `s m h d w`        |
| `user.backup.root`                   | `true`        | provision, worker   | snapshot `/`                                                            |
| `user.backup.volumes`                | `auto`        | provision, worker   | `auto`, `none`, or a comma-separated list of disk device names          |
| `user.backup.policy.root`            | `root-server` | provision, worker   | policy class for `/`                                                    |
| `user.backup.policy.data`            | `data`        | provision, worker   | policy class for every custom volume                                    |
| `user.backup.exclude`                | (none)        | provision           | extra ignore patterns for every source, comma-separated                 |
| `user.backup.exclude.root`           | (none)        | provision           | extra ignore patterns for `/`                                           |
| `user.backup.exclude.data`           | (none)        | provision           | extra ignore patterns for custom volumes                                |
| `user.backup.pre`                    | (none)        | worker              | shell command run in the guest before the snapshots; failure aborts     |
| `user.backup.post`                   | (none)        | worker              | shell command run in the guest after the snapshots; failure is logged   |
| `user.backup.runtime_dir`            | `/run/incus-backup` | worker        | guest directory for the injected files; must allow execution           |
| `user.backup.cache.metadata_mb`      | `64`          | worker              | guest metadata cache soft size                                          |
| `user.backup.cache.metadata_limit_mb`| `128`         | worker              | guest metadata cache hard limit                                         |
| `user.backup.cache.content_mb`       | `32`          | worker              | guest content cache soft size                                           |
| `user.backup.cache.content_limit_mb` | `64`          | worker              | guest content cache hard limit                                          |

Keys read by `provision` need `incus-backup-provision <instance>` after a
change. Keys read only by the worker or scheduler apply on the next run.

## Identity

```bash
incus config set www11 user.backup.hostname=www11.nippynetworks.com
```

Kopia identity: `backup@www11.nippynetworks.com`. Credential file on the host:
`/etc/incus-backup/credentials/www11.nippynetworks.com`. The value is
lowercased. Use the permanent name of the service, not the Incus host.

## Sources

`user.backup.volumes=auto` selects every expanded `disk` device that has a
`pool`, a `source` and a `path` other than `/`. That matches Incus custom
storage volumes and excludes the root disk, host bind mounts (no pool),
cloud-init disks and block volumes without a path. Example device:

```yaml
www:
  type: disk
  pool: vs_slow
  source: www11-data
  path: /var/www
```

gives the sources `backup@www11.nippynetworks.com:/` and
`backup@www11.nippynetworks.com:/var/www`. The root snapshot does not descend
into `/var/www` because every policy sets `oneFileSystem=true`.

```bash
incus config set www11 user.backup.volumes=auto          # root plus every custom volume
incus config set www11 user.backup.volumes=none          # root only
incus config set www11 user.backup.volumes=www,uploads   # only these device names
incus config set some-container user.backup.root=false   # volumes only
```

A device name in the list that is not attached produces a warning and is
skipped.

## Policy classes and exclusions

Classes are files in `/etc/incus-backup/policies.d/`; see
[policy-classes.md](policy-classes.md).

```bash
incus config set mail1 user.backup.policy.data=critical
```

Ad-hoc exclusions use Kopia ignore syntax. A leading `/` anchors the pattern
to the source root, a trailing `/` matches directories only. Separate patterns
with commas.

```bash
incus config set www11 user.backup.exclude='/srv/scratch/,/root/tmp-build/'
incus config set www11 user.backup.exclude.root='/opt/disposable/'
incus config set www11 user.backup.exclude.data='lost+found/'
incus-backup-provision www11
```

Nothing inside the guest can add exclusions. `.kopiaignore` files and
`CACHEDIR.TAG` markers are ignored by the global policy.

## Consistency hooks

```bash
incus config set db1 user.backup.pre='mysqldump --all-databases --single-transaction > /var/lib/backup/mysql.sql'
```

The command runs as root in the guest with `sh -c`. Keep the dump target out
of excluded directories (`/var/backup/` is excluded by `root-server`;
`/var/lib/backup/` is not).

## Cache

The guest keeps the Kopia cache in `/var/cache/kopia`, which every root class
excludes. A warm cache turns a 1.2 GB, 54k-file root backup from about 11
seconds and 1.2 GB uploaded into a near-instant metadata-only run. Mail stores
and other file-heavy volumes need larger caches:

```bash
incus config set mail1 user.backup.cache.metadata_mb=256
incus config set mail1 user.backup.cache.metadata_limit_mb=512
incus config set mail1 user.backup.cache.content_mb=128
incus config set mail1 user.backup.cache.content_limit_mb=256
```

Limits must be at least as large as the soft values.

## Complete example

```bash
incus config set www11 user.backup.enabled=true
incus config set www11 user.backup.hostname=www11.nippynetworks.com
incus config set www11 user.backup.interval=6h
incus config set www11 user.backup.root=true
incus config set www11 user.backup.volumes=auto
incus config set www11 user.backup.policy.root=root-server
incus config set www11 user.backup.policy.data=data
incus-backup-provision www11
```
