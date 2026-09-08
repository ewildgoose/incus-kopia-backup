# Server setup

The server is `media`. Site values:

```text
DNS:        kopia.nippynetworks.lan, kopia.nippynetworks.com
addresses:  192.168.8.6 now, 192.168.81.6 later
port:       51515
repository: /srv/backup/kopia (filesystem backend, XFS)
Kopia:      0.23.1 (app-backup/kopia-bin)
```

Every step is idempotent unless marked "once".

## 1. Install

`app-backup/kopia-bin` installs the static binary and the `kopia-server`
OpenRC service. `app-backup/incus-kopia-backup` with USE=server installs the
helpers and the cron entry. Both live in the local overlay.

```bash
echo 'app-backup/incus-kopia-backup **' >> /etc/portage/package.accept_keywords/incus-kopia-backup
echo 'app-backup/incus-kopia-backup server -client' >> /etc/portage/package.use/incus-kopia-backup
emerge --ask app-backup/kopia-bin app-backup/incus-kopia-backup
```

The package is a live ebuild fetched from the private git server over SSH.
If the `portage` user has no key for it, build from a local checkout:

```bash
EGIT_OVERRIDE_REPO_INFRA_INCUS_KOPIA_BACKUP=file:///usr/src/incus-kopia-backup emerge --ask app-backup/incus-kopia-backup
```

## 2. Secrets and repository (once)

```bash
install -d -m 0700 /etc/kopia
(umask 077; openssl rand -base64 48 > /etc/kopia/repository.password)
(umask 077; openssl rand -base64 48 > /etc/kopia/server-control.password)
install -d -m 0700 /srv/backup/kopia
KOPIA_PASSWORD="$(cat /etc/kopia/repository.password)" \
kopia --config-file=/etc/kopia/repository.config --no-persist-credentials \
  repository create filesystem --path=/srv/backup/kopia \
  --override-username=root --override-hostname=media
```

`kopia-admin` reads the password from the file on every call, so the config
file does not need persisted credentials. The identity `root@media` becomes
the maintenance owner; the server runs maintenance under it.

## 3. TLS certificate

Clients pin the certificate fingerprint, so a self-signed certificate is
enough. Include every name and address a client might use:

```bash
cat > /etc/kopia/san.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = kopia.nippynetworks.com
[ext]
subjectAltName = DNS:media,DNS:kopia.nippynetworks.lan,DNS:kopia.nippynetworks.com,IP:127.0.0.1,IP:192.168.8.6,IP:192.168.81.6
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
EOF
openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
  -keyout /etc/kopia/server.key -out /etc/kopia/server.crt -config /etc/kopia/san.cnf
chmod 0600 /etc/kopia/server.key
kopia-server-fingerprint
```

Write the fingerprint into `KOPIA_SERVER_FINGERPRINT` in `/etc/incus-backup.conf`
on every host. When you renew the certificate, repeat that on every host.

## 4. Service

Edit `/etc/conf.d/kopia-server`:

```sh
KOPIA_LISTEN_ADDRESS="0.0.0.0:51515"
KOPIA_LOG_DIR="/var/log/kopia"
KOPIA_SERVER_OPTIONS="--no-ui --refresh-interval=1m"
```

`--refresh-interval=1m` matters: with Kopia's default of 4 hours the server
ignores users and ACLs written by `kopia-server-add-host` and
`incus-backup-provision` for up to 4 hours. Then:

```bash
rc-update add kopia-server default
rc-service kopia-server restart
ss -lntp | grep ':51515'
tail -50 /var/log/kopia-server.log
```

`rc-service kopia-server reload` sends SIGHUP and makes the server re-read
users, ACLs and policies at once.

## 5. Harden the repository

```bash
kopia-server-init
rc-service kopia-server reload
```

This replaces Kopia's default wildcard ACLs with:

```text
*@*  APPEND  type=content
*@*  READ    type=policy,policyType=global
*@*  READ    type=policy,policyType=host,hostname=OWN_HOST
*@*  READ    type=policy,username=OWN_USER,hostname=OWN_HOST
*@*  APPEND  type=snapshot,username=OWN_USER,hostname=OWN_HOST
```

and sets the global policy to `oneFileSystem=true`, `ignoreCacheDirs=false`,
no `ignoreDotFiles`, `noParent=true`. See [gotchas.md](gotchas.md) for why
each of these matters. Check the result:

```bash
kopia-admin server acl list
kopia-admin policy show --global
```

## 6. Trusted hosts

For each container host:

```bash
kopia-server-add-host cl1.nippynetworks.com
rc-service kopia-server reload
```

The command prints the password of `admin@cl1.nippynetworks.com` once. Store it
on `cl1` as `/etc/incus-backup/admin.password` (mode 0600). Re-running the
command keeps the password and refreshes the ACLs; `--reset-password` rotates
it.

## 7. Cron

`/etc/cron.d/kopia-server` (installed by the package) runs `kopia-pin-guard`
and then `kopia-expire-snapshots` every night. Logs go to `/var/log/kopia/`.
Remove the older hand-made entry `/etc/cron.d/kopia-expire`. Tune the guard
buckets in `/etc/kopia/pin-guard.conf`. Try it first with:

```bash
kopia-pin-guard --dry-run
```

## 8. Maintenance

The server runs Kopia maintenance itself when its identity owns it:

```bash
kopia-admin maintenance info
```

Expected: `Owner: root@media` with quick and full cycles scheduled. If the
owner differs, set it:

```bash
kopia-admin maintenance set --owner=root@media
```

## 9. Repository safety net

The pin guard protects against clients; it does not protect against the
server's disk. `/srv/backup` is XFS, so there are no cheap filesystem
snapshots. Copy the repository to a second disk or NAS nightly:

```bash
kopia-admin repository sync-to filesystem --path=/mnt/offsite/kopia
```

The command copies only new blobs and is safe while the server runs. Without
`--delete` it never removes blobs from the copy, which is the safer default.

## 10. Reload versus refresh interval

Users, ACLs and policies written from a host through the server become visible
to the server on the next refresh (every minute with the settings above) or
immediately after `rc-service kopia-server reload`. `incus-backup-provision`
waits up to `PROVISION_AUTH_TIMEOUT` seconds for a new backup user to become
usable, so the one-minute interval is enough in practice.
