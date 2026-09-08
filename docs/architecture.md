# Architecture and trust model

## Goal

Reliable, reproducible backups of Incus/LXD containers on several Gentoo hosts
(`cl1`, `cl2`, `cl3`, legacy `sm3`) to one Kopia Repository Server (`media`).
Only running containers are backed up.

## Data flow

1. Cron on the host runs `incus-backup-scheduler` every 15 minutes.
2. The scheduler starts `incus-backup-container <instance>` for each running
   instance with `user.backup.enabled=true` whose last complete success is
   older than `user.backup.interval`.
3. The worker pushes three files into the guest under `/run/incus-backup`: the
   static `kopia` binary, the backup password, and a generated `run.sh`.
4. `run.sh` runs as guest root. It connects to the server with the identity
   `backup@<user.backup.hostname>`, keeps the Kopia cache in `/var/cache/kopia`,
   and snapshots `/` and each attached custom volume as separate sources.
5. The worker removes `/run/incus-backup` and records the result under
   `/var/lib/incus-backup/<instance>/`. `last_success` advances only when every
   source succeeded.

Policies (exclusions, retention) are written by `incus-backup-provision` from
the host, through the server, with the host's `admin@<host-fqdn>` identity.
Nothing in the guest chooses what is excluded.

## Identities

| Identity                    | Used by                        | Rights on the server                                              |
|-----------------------------|--------------------------------|-------------------------------------------------------------------|
| `backup@<container-fqdn>`   | the guest during a backup      | append content; append own snapshots; read global, host, own policies |
| `admin@<host-fqdn>`         | provision and status on a host | full on users and policies; read all snapshots; content as above  |
| direct access on `media`    | `kopia-admin`, cron helpers    | everything                                                        |

The container identity follows the thing backed up, not the physical host. A
container moved from `cl1` to `cl3` keeps its snapshot history. The password
for `backup@<fqdn>` is kept on the host in `/etc/incus-backup/credentials/<fqdn>`
and must move with the container (or be rotated on the new host).

## Trust model

- The Incus host is trusted. It holds all backup passwords and the admin
  identity.
- Containers are not trusted. A container only receives its own backup
  password, for the duration of one run.
- The server does not trust anybody by default: ACLs restrict what each
  identity can do. `kopia-server-init` installs and verifies them.

### What the design guarantees

1. A container cannot read, list, alter or delete another container's snapshots
   or policies. Snapshot and policy ACLs are scoped to `OWN_USER@OWN_HOST`.
2. A container cannot delete a snapshot directly. `snapshot delete` needs FULL
   access; clients have APPEND.
3. A container cannot change any policy. Exclusions and retention come from
   the host-side class files and `user.backup.*` keys.
4. Snapshots protected by `kopia-pin-guard` survive any retention run, because
   Kopia never expires a pinned snapshot and only the administrator can pin.
5. Losing a host does not lose backups: the repository is on `media`.

### What the design does not guarantee

1. A compromised container can produce a false backup of itself. Root inside
   the guest can replace the injected binary before it runs, ptrace it, or
   bind-mount an empty directory over data it wants to hide. The backup
   protects the container's history from destruction; it cannot prove the
   current content of a hostile container. Alerting on snapshot size and file
   counts (`incus-backup-status --server`) is the practical detection.
2. A container can fill the repository. Kopia has no per-user quota. Monitor
   free space on `media`.
3. A container can test whether a known file exists in the repository. Content
   is shared between all clients and addressed by an HMAC of the plaintext, and
   the server hands the HMAC secret to every client session. A client that
   already has the exact bytes can compute the ID and fetch it. It cannot
   enumerate or read unknown data, because it cannot read other snapshots.
4. A container can dilute its own unpinned history. A client with APPEND access
   may ask the server to apply retention to its own source (`ApplyRetentionPolicy`
   RPC) and may set `--start-time` on new snapshots. Fake snapshots with chosen
   timestamps can push genuine ones out of the retention buckets. This is why
   `kopia-pin-guard` exists.
5. Snapshots are not crash-consistent. Kopia reads a live filesystem. Use
   `user.backup.pre` to dump databases to disk before the snapshot.

## Kopia behaviour verified against the v0.23.1 source

These facts drive the design. File names refer to the Kopia repository.

- Retention is applied server-side for repository clients
  (`snapshot/policy/expire.go`, `internal/server/grpc_session.go`). The RPC
  needs APPEND on the client's own snapshots. Expired snapshots are deleted by
  the server after every `snapshot create`. Consequence: `kopia-expire-snapshots`
  on `media` is only a sweep for sources that stopped sending; and clients can
  trigger deletion through retention (see limit 4 above).
- Pinned snapshots are never expired (`expire.go`: kept when `len(s.Pins) > 0`).
  `snapshot pin` rewrites the manifest and therefore needs FULL access.
- Dot-ignore files: at the snapshot root Kopia loads every file named in the
  effective policy's `ignoreDotFiles` (`fs/ignorefs/ignorefs.go`,
  `buildContext`). `noParentDotFiles` does not remove `.kopiaignore` from that
  list. During policy merging the list is "first non-empty wins"
  (`policy_merge.go`, `mergeStringsReplace`), and the built-in default
  `[".kopiaignore"]` is merged last unless a policy in the chain has
  `noParent=true`. Consequence: to stop a guest from excluding its own files with
  `/.kopiaignore`, the global policy needs no `ignoreDotFiles` **and**
  `noParent=true`. `kopia-server-init` sets exactly that. A global policy with
  `ignoreDotFiles: [".kopiaignore"]` still honours the guest's file, whatever
  `noParentDotFiles` says.
- Cache directories: with `ignoreCacheDirs` true (Kopia default) any directory
  containing a `CACHEDIR.TAG` file with the standard signature is skipped. A
  guest could hide `/etc` that way. Every class sets `IGNORE_CACHE_DIRS="false"`
  and the global policy sets `ignoreCacheDirs=false`.
- Policy visibility: `FindManifests` and `GetManifest` filter by READ access on
  the manifest labels. A client with READ only on the global and host policies
  never sees its own `user@host:/path` policy, so class exclusions and
  compression would silently not apply. Clients therefore get READ on
  `type=policy,username=OWN_USER,hostname=OWN_HOST` (Kopia's default grants
  FULL there). Retention is unaffected because the server evaluates it.
- Server caches: the server re-reads users and ACLs from its repository view
  every 10 seconds, but that view only sees manifests written by other clients
  after a repository refresh: every `--refresh-interval` (Kopia default 4h),
  on SIGHUP, or on `kopia server refresh`. The OpenRC service sets the interval
  to 1 minute and `rc-service kopia-server reload` sends SIGHUP.
- Maintenance: the server runs repository maintenance itself when its identity
  owns maintenance (`internal/server/server.go`, `maybeStartMaintenanceManager`).
  Check with `kopia-admin maintenance info`.
- Credentials: `--persist-credentials` is a global flag (`cli/app.go`). The
  guest run uses `--no-persist-credentials`, so nothing but the pushed
  password file holds the secret, and the whole runtime directory is removed.
- Flags used by the scripts and verified: `repository connect server --url
  --server-cert-fingerprint --override-username --override-hostname
  --cache-directory --metadata-cache-size-mb --metadata-cache-size-limit-mb
  --content-cache-size-mb --content-cache-size-limit-mb --no-check-for-updates`;
  `snapshot create --fail-fast --force-disable-actions --tags`; `snapshot list
  --all --json --max-results --no-retention`; `snapshot pin --add --remove`;
  `snapshot expire --all --delete`; `policy set --clear-ignore --add-ignore
  --clear-dot-ignore --one-file-system --ignore-cache-dirs --keep-* --compression
  --inherit`; `policy export|import --global`; `server users add|set|info|delete
  --user-password`; `server acl add --user --target --access --overwrite`,
  `acl list --json`, `acl delete --delete`; `server start --address --tls-cert-file
  --tls-key-file --refresh-interval --no-ui`; global `--config-file --log-dir
  --no-persist-credentials`.

## Design decisions

- **Backup from inside the guest, not from the host.** The host could read the
  rootfs through the storage pool, but uid shifting, block-backed pools and
  the daemon's private mount namespace make that fragile. Inside the guest the
  view is exact. The price is the limit "a hostile guest can lie", which no
  in-guest agent can avoid.
- **Stable identity per container**, not per host, so migration keeps history.
- **One Kopia source per volume.** `oneFileSystem=true` keeps the root snapshot
  out of mounted volumes and pseudo filesystems; each custom volume is its own
  source with its own class.
- **Policy classes as files on the host**, copied onto concrete Kopia policies
  by provisioning. Kopia has no named policy inheritance. The package
  distributes the class files so every host applies the same rules.
- **Retention on the server, pins as the backstop.** Kopia's retention is kept
  as the working mechanism; the pin guard makes the recent history immutable
  from the client side.
- **No persistent agent and no SSH into guests.** Everything the guest needs is
  pushed for one run and removed. A read-only device mount of the host binary
  was considered: guest root can still unmount it, and a device add and remove
  per run costs more than it protects. Ease of use wins here.
- **Host-defined pre/post commands** (`user.backup.pre`, `user.backup.post`)
  give consistency hooks without trusting the guest: the host chooses them.

## Files

Server (`media`):

```text
/etc/kopia/repository.config         Kopia connection for the server and kopia-admin
/etc/kopia/repository.password       repository password (0600)
/etc/kopia/server-control.password   control API password (0600)
/etc/kopia/server.crt, server.key    TLS certificate and key
/etc/kopia/pin-guard.conf            kopia-pin-guard buckets
/etc/conf.d/kopia-server             service settings (service itself comes from app-backup/kopia-bin)
/var/log/kopia-server.log            service stdout/stderr
/var/log/kopia/                      Kopia log files, pin-guard.log, expire.log
/srv/backup/kopia                    the repository
```

Host (`cl1`, ...):

```text
/etc/incus-backup.conf                     host configuration
/etc/incus-backup/admin.password           password of admin@<host-fqdn> (0600)
/etc/incus-backup/admin.repository.config  Kopia connection written by provisioning
/etc/incus-backup/credentials/<fqdn>       password of backup@<fqdn> (0600)
/etc/incus-backup/policies.d/<class>.conf  policy classes
/var/lib/incus-backup/<instance>/          last_attempt, last_success, last_success_iso, last_result
/var/log/incus-backup/<instance>.log       worker log, including Kopia output
/var/log/incus-backup/scheduler.log        scheduler decisions
/var/log/incus-backup/kopia/               host-side Kopia logs
/run/incus-backup/*.lock                   per-instance and scheduler locks
```

Guest (during a run only): `/run/incus-backup/{kopia,password,run.sh,repository.config}`.
Guest (persistent): `/var/cache/kopia` (cache and Kopia logs).
