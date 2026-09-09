# Host setup

Applies to every Incus/LXD host: `cl1`, `cl2`, `cl3`, `sm3`. The commands use
`incus`; on LXD hosts use `lxc` with the same arguments. The scripts detect
which CLI is installed.

## 1. Install

```bash
echo 'app-backup/incus-kopia-backup **' >> /etc/portage/package.accept_keywords/incus-kopia-backup
echo 'app-backup/incus-kopia-backup client -server' >> /etc/portage/package.use/incus-kopia-backup
emerge --ask app-backup/kopia-bin app-backup/incus-kopia-backup
```

The package is a live ebuild fetched from the private git server over SSH.
If the `portage` user has no key for it, build from a local checkout:

```bash
EGIT_OVERRIDE_REPO_INFRA_INCUS_KOPIA_BACKUP=file:///usr/src/incus-kopia-backup emerge --ask app-backup/incus-kopia-backup
```

The package installs the commands in `/usr/sbin`, the library in
`/usr/lib/incus-backup`, the policy classes in `/etc/incus-backup/policies.d`,
the cron entry `/etc/cron.d/incus-backup` and a logrotate rule. The cron entry
needs a cron daemon that reads `/etc/cron.d` (cronie does).

## 2. Configure

Edit `/etc/incus-backup.conf`:

```text
KOPIA_SERVER_URL          https://kopia.nippynetworks.lan:51515
KOPIA_SERVER_FINGERPRINT  output of kopia-server-fingerprint on media
KOPIA_ADMIN_HOSTNAME      the FQDN you gave to kopia-server-add-host, for
                          example cl1.nippynetworks.com
```

The default `KOPIA_ADMIN_HOSTNAME` uses `hostname -f`, which
derives it from the first entry on the 127.0.0.1 line. Use eg:

```text
127.0.0.1     cl1.nippynetworks.lan cl1 localhost
```

```bash
rm -f /usr/local/sbin/incus-backup-* && hash -r && type incus-backup-provision
```

## 3. Admin identity

On `media`:

```bash
kopia-server-add-host cl1.nippynetworks.com
rc-service kopia-server reload
```

On `cl1`, store the printed password:

```bash
install -d -m 0700 /etc/incus-backup
(umask 077; printf '%s\n' 'PASTE-THE-PASSWORD' > /etc/incus-backup/admin.password)
```

Without this file, `incus-backup-provision` prompts for the password.

## 4. Configure and provision an instance

Set the keys described in [container-parameters.md](container-parameters.md).
Minimum:

```bash
incus config set www11 user.backup.enabled=true
incus config set www11 user.backup.hostname=www11.nippynetworks.com
```

Then:

```bash
incus-backup-provision www11
incus-backup-container www11
incus-backup-status
```

Provisioning creates `backup@www11.nippynetworks.com` on the server, stores its
password in `/etc/incus-backup/credentials/www11.nippynetworks.com`, and writes
one Kopia policy per source. Re-run it after changing `user.backup.hostname`,
`user.backup.root`, `user.backup.volumes`, `user.backup.policy.*` or
`user.backup.exclude*`, and after editing a policy class file. Re-running
never changes a password unless you pass `--reset-password`.

## 5. Schedule

`/etc/cron.d/incus-backup` runs `incus-backup-scheduler` every 15 minutes. The
scheduler prints a line on failure, so cron mails failures to root. Success is
silent and logged in `/var/log/incus-backup/scheduler.log`.

Host-wide defaults in `/etc/incus-backup.conf`:

```text
DEFAULT_INTERVAL      24h   used when user.backup.interval is unset
MAX_JOBS              1     backups running at the same time
MAX_NORMALIZED_LOAD   1.25  no new backup when load / CPUs is at or above this
```

## 6. Logs

```text
/var/log/incus-backup/<instance>.log   worker log with Kopia output
/var/log/incus-backup/scheduler.log    what the scheduler started and why
/var/log/incus-backup/kopia/           Kopia's own logs for host-side commands
```

Inside each guest, Kopia writes its logs to `/var/cache/kopia/logs`.

## 7. Moving a container to another host

The identity stays the same, so the history continues. The new host needs the
credential file:

```bash
scp cl1:/etc/incus-backup/credentials/www11.nippynetworks.com /etc/incus-backup/credentials/
chmod 0600 /etc/incus-backup/credentials/www11.nippynetworks.com
incus-backup-provision www11
```

If the file cannot be copied, run `incus-backup-provision --reset-password
www11` on the new host. The old host's copy then stops working, which is what
you want.
