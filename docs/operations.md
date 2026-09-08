# Operations

## Daily checks

On a host:

```bash
incus-backup-status            # local state: last success, age, due, last result
incus-backup-status --server   # plus newest snapshot per source as the server sees it
tail -50 /var/log/incus-backup/scheduler.log
```

`LAST_RESULT` is `ok`, `failed` or `running`. A failed run does not advance
`LAST_SUCCESS`, so the instance stays due and the scheduler retries it on the
next cron run. The scheduler prints failures, so cron mails them to root.

On the server:

```bash
kopia-admin snapshot list --all          # every source, retention reasons and pins
kopia-admin server acl list
kopia-admin maintenance info
tail -20 /var/log/kopia/pin-guard.log /var/log/kopia/expire.log
df -h /srv/backup
```

## Run a backup now

```bash
incus-backup-container www11
```

The worker exits 0 and prints "already running" when a backup of that
instance is in progress, and exits 0 with "not running" for a stopped
instance. Everything it does is in `/var/log/incus-backup/www11.log`.

## Restore

### Into the running container

`incus-backup-shell` injects Kopia, connects it as the container's identity
and gives you a shell inside the guest. The connection has read access to the
container's own snapshots.

```bash
incus-backup-shell www11
kopia snapshot list                         # snapshots of /
kopia snapshot list /var/www                # snapshots of a volume
kopia ls -l k1a2b3c4d5e6f7/etc              # browse a snapshot by its root object ID
kopia restore k1a2b3c4d5e6f7/etc/nginx /root/restore-nginx
exit
```

`kopia snapshot list` prints the root object ID of each snapshot. Append a
path to it to restore part of a snapshot. Restore into a scratch directory
first, then move files into place. Single commands work too:

```bash
incus-backup-shell www11 kopia snapshot list --all
```

### Into a new container (disaster recovery)

1. Create the new container. Give it the same `user.backup.hostname` as the
   lost one, so it uses the same identity and history.
2. Copy the credential file from the old host if you still have it, otherwise
   run `incus-backup-provision --reset-password <new>`; then
   `incus-backup-provision <new>`.
3. `incus-backup-shell <new>`, then `kopia restore <root-object-id> /` for the
   root, or restore volume snapshots into the mounted volume paths. Stop
   services first; restoring over a live system replaces files in place.
4. Reboot the container.

### From the server

```bash
kopia-admin snapshot list --all
kopia-admin restore k1a2b3c4d5e6f7/home/user /srv/restore/user
```

Then push the files to the target with `incus file push -r`.

## Rotate passwords

```bash
incus-backup-provision --reset-password www11           # on the host: one backup user
kopia-server-add-host --reset-password cl1.nippynetworks.com   # on media: a host admin
```

After rotating a host admin password, write the new value to
`/etc/incus-backup/admin.password` on that host and reload the server.

## Decommission a container

On the host:

```bash
incus config set old1 user.backup.enabled=false
rm /etc/incus-backup/credentials/old1.nippynetworks.com
rm -r /var/lib/incus-backup/old1
```

The snapshots stay in the repository under normal retention, and pinned ones
stay until the pin guard rotates them out. To delete the history on `media`:

```bash
kopia-admin snapshot list backup@old1.nippynetworks.com:/ --all
kopia-admin snapshot delete --all-snapshots-for-source 'backup@old1.nippynetworks.com:/' --delete
kopia-admin policy remove 'backup@old1.nippynetworks.com:/'
kopia-admin server users delete backup@old1.nippynetworks.com
```

Repeat the delete and policy remove for each volume path. Space is reclaimed
by the next full maintenance run.

## Renew the TLS certificate

Create the new certificate as in server-setup.md, restart the service, then
run `kopia-server-fingerprint` and update `KOPIA_SERVER_FINGERPRINT` on every
host. Backups fail with a certificate error until the hosts are updated.

## Upgrade Kopia

Upgrade the server first, then the hosts; keep them on the same version. After
a server upgrade run `kopia-server-init` again and re-check the tests in
testing.md that cover `.kopiaignore` and `CACHEDIR.TAG`, because those rely on
Kopia internals.

## Troubleshooting

| Symptom                                                        | Cause and action                                                                                                   |
|----------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| `connect: connection refused`                                  | Server not listening. On media: `rc-service kopia-server status`, `ss -lntp \| grep 51515`, `tail /var/log/kopia-server.log`. |
| certificate or fingerprint error                               | `KOPIA_SERVER_FINGERPRINT` differs from `kopia-server-fingerprint` on media.                                       |
| `invalid credentials` right after provisioning                 | Server has not refreshed its user list. `rc-service kopia-server reload` on media, or wait one refresh interval.    |
| `invalid credentials` for an old instance                      | Credential file and server disagree. `incus-backup-provision --reset-password <instance>`.                         |
| `access denied` on `policy set` from a host                    | `admin@<host>` lacks ACLs. `kopia-server-add-host <host-fqdn>` on media, then reload.                              |
| guest prints `Permission denied` running `kopia`               | Runtime directory is mounted `noexec`. Set `user.backup.runtime_dir` to an executable location.                    |
| `unknown policy class`                                         | `user.backup.policy.*` names a class without a file in `/etc/incus-backup/policies.d/`.                             |
| exclusions not applied                                         | Client cannot read its policy. `kopia-admin server acl list` must show READ on `type=policy,username=OWN_USER,hostname=OWN_HOST`; run `kopia-server-init`. |
| `backup already running` for a long time                       | A worker hangs. `ps aux \| grep incus-backup-container`, inspect the log, kill the worker. The lock releases when the process exits. |
| first backup is slow                                           | Expected: the whole filesystem is hashed and uploaded once. Later runs use the cache in `/var/cache/kopia`.         |
| `ACLs already enabled` from `kopia server acl enable`          | Not needed; `kopia-server-init` manages entries individually.                                                      |
| snapshot list shows unexpected sizes or file counts            | Investigate the guest. A compromised guest can produce a false backup (architecture.md).                            |
