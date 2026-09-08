# incus-kopia-backup

Backup of running Incus/LXD containers to a central Kopia repository server.

The container host injects a static Kopia binary into each container, snapshots
the container root and every attached custom volume from inside the container,
and removes the binary again. Nothing runs permanently inside a container. Each
container backs up under a stable identity, `backup@<fqdn>`, so it can move
between hosts and keep its history.

Everything runs on Gentoo. The `gentoo/` directory holds the ebuild. USE=server
installs the server side, USE=client installs the container-host side.

## Components

| Where  | Command                    | Purpose                                                           |
|--------|----------------------------|-------------------------------------------------------------------|
| server | `kopia-server` (OpenRC)    | Kopia repository server, TLS, port 51515 (from app-backup/kopia-bin)  |
| server | `kopia-admin`              | Run `kopia` with full access to the local repository              |
| server | `kopia-server-init`        | Restrict client ACLs and harden the global policy (idempotent)    |
| server | `kopia-server-add-host`    | Create the `admin@<host>` identity for a trusted container host   |
| server | `kopia-server-fingerprint` | Print the TLS fingerprint that clients pin                        |
| server | `kopia-pin-guard`          | Pin recent history so clients cannot expire it (cron)             |
| server | `kopia-expire-snapshots`   | Delete expired snapshots (cron)                                   |
| host   | `incus-backup-provision`   | Create the backup user and policies for one instance (idempotent) |
| host   | `incus-backup-container`   | Back up one instance now                                          |
| host   | `incus-backup-scheduler`   | Start due backups (cron, every 15 minutes)                        |
| host   | `incus-backup-status`      | Show the backup state of every instance                           |
| host   | `incus-backup-shell`       | Shell inside an instance with Kopia connected, for restores       |

## Quick start

1. Server: follow [docs/server-setup.md](docs/server-setup.md).
2. Each container host: follow [docs/host-setup.md](docs/host-setup.md).
3. Each instance:

```bash
incus config set www11 user.backup.enabled=true
incus config set www11 user.backup.hostname=www11.nippynetworks.com
incus-backup-provision www11
incus-backup-container www11
incus-backup-status
```

## Documents

- [docs/architecture.md](docs/architecture.md): design, trust model, verified Kopia behaviour, limits.
- [docs/server-setup.md](docs/server-setup.md): build the server.
- [docs/host-setup.md](docs/host-setup.md): prepare a container host.
- [docs/container-parameters.md](docs/container-parameters.md): every `user.backup.*` key.
- [docs/policy-classes.md](docs/policy-classes.md): exclusion and retention classes.
- [docs/operations.md](docs/operations.md): status, restore, rotate, decommission, troubleshoot.
- [docs/testing.md](docs/testing.md): acceptance tests.
- [docs/gotchas.md](docs/gotchas.md): behaviour that cost time; read before changing ACLs or policies.

## Repository layout

```text
host/       container-host commands, shared library, config template, policy classes
server/     server helpers and pin-guard.conf
gentoo/     ebuilds: app-backup/incus-kopia-backup (cron and logrotate files in files/)
            and app-backup/kopia-bin (Kopia binary and the kopia-server OpenRC service)
docs/       documentation
```

Install paths are listed in the ebuild. The scripts source
`/usr/lib/incus-backup/common.sh`; to run them from a checkout, create that
symlink to `host/lib/common.sh`.
