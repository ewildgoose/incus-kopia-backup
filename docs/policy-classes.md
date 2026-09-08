# Policy classes

A policy class is a file `/etc/incus-backup/policies.d/<class>.conf` on the
container host. `incus-backup-provision` copies the class onto the concrete
Kopia policy of each source (`backup@<fqdn>:/path`), because Kopia has no
named policy inheritance. The package installs the classes, so every host
applies the same rules; local edits are protected by CONFIG_PROTECT.

## Included classes

| Class         | Use                                  | Exclusions                                                       | Retention (latest/hourly/daily/weekly/monthly/annual) |
|---------------|--------------------------------------|------------------------------------------------------------------|-------------------------------------------------------|
| `root-server` | root of an application server        | `/tmp/ /var/tmp/ /var/cache/ /var/backup/ /var/log/ /run/ /proc/ /sys/ /dev/ .ccache/ .recycle/ core.*` | 10/24/14/8/12/3 |
| `iot`         | root of a general or IoT machine     | as `root-server` without `/var/log/`                             | 10/24/14/8/12/3 |
| `data`        | custom data volumes                  | `.recycle/`                                                      | 10/24/14/8/12/3 |
| `critical`    | important data                       | `.recycle/`                                                      | 10/48/30/12/24/3 |

`/var/log/` is excluded from `root-server` because those servers ship their
logs centrally. Do not add it to the global policy: `iot` machines keep logs
locally.

## File format

The file is sourced by bash:

```sh
IGNORE=(
    "/tmp/"
    ".ccache/"
    "core.*"
)
ONE_FILE_SYSTEM="true"
IGNORE_CACHE_DIRS="false"
KEEP_LATEST=10
KEEP_HOURLY=24
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12
KEEP_ANNUAL=3
COMPRESSION="none"
```

Keep `ONE_FILE_SYSTEM="true"` and `IGNORE_CACHE_DIRS="false"` in every class:
the first keeps root snapshots out of mounted volumes and pseudo filesystems,
the second stops a guest from hiding a directory with a `CACHEDIR.TAG` file.
`COMPRESSION` accepts Kopia algorithm names (`none`, `zstd`, `zstd-fastest`,
`s2-default`, ...). Compression runs in the guest.

Anything a class does not set comes from the global policy on the server, and
from nothing else: the global policy has `noParent=true`, so Kopia's built-in
defaults do not apply.

## Retention semantics

Kopia counts buckets that contain snapshots, newest first, and keeps the
newest snapshot of each bucket. `KEEP_HOURLY=24` keeps the newest snapshot of
the 24 most recent hours that have a snapshot. With a 6-hour interval that is
24 snapshots over 6 days, not 24 hours. `KEEP_LATEST` counts snapshots
regardless of time. A snapshot is kept when any rule keeps it, or when it has a
pin (see `kopia-pin-guard`). The server applies retention after each client
snapshot; `kopia-expire-snapshots` sweeps the rest nightly.

## Adding or editing a class

1. Create or edit the file on every host (or in the package).
2. Re-provision each instance that uses the class:

```bash
for i in $(incus list --format=csv --columns=n); do
    incus config get -e "$i" user.backup.enabled | grep -qiE '^(true|yes|on|1)$' && incus-backup-provision "$i"
done
```

Retention changes apply on the server at the next snapshot. Exclusion changes
apply at the next backup.

## Checking the policy a client sees

The exclusions act in the guest, so the guest must be able to read its policy.
From the host:

```bash
incus-backup-shell www11 kopia policy show 'backup@www11.nippynetworks.com:/'
```

The output must list the class ignore rules with `(defined for this target)`
and must show no dot-ignore files.
