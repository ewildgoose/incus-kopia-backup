# Acceptance tests

Run these after the first installation and after upgrading Kopia. Test
container: `dr-test-xfs` on `cl1`, identity `backup@dr-test-xfs.nippynetworks.com`.
Every command block states where it runs.

## T1. Server is listening (media)

```bash
rc-service kopia-server status
ss -lntp | grep ':51515'
tail -20 /var/log/kopia-server.log
kopia-server-fingerprint
```

Expected: a listener on `0.0.0.0:51515`; the fingerprint equals
`KOPIA_SERVER_FINGERPRINT` on the hosts.

## T2. ACLs and global policy (media)

```bash
kopia-server-init
rc-service kopia-server reload
kopia-admin server acl list
kopia-admin policy show --global
```

Expected: exactly the five `*@*` entries listed in server-setup.md plus the
`admin@<host>` entries; the global policy shows one-file-system true, cache
directories not ignored, no dot-ignore files.

## T3. Provision and first backup (cl1)

```bash
incus config set dr-test-xfs user.backup.enabled=true
incus config set dr-test-xfs user.backup.hostname=dr-test-xfs.nippynetworks.com
incus config set dr-test-xfs user.backup.interval=6h
incus-backup-provision dr-test-xfs
incus-backup-container dr-test-xfs
incus-backup-status
```

Expected: provisioning reports "Server accepts backup@..."; the backup ends
with "backup complete"; status shows `LAST_RESULT ok`.

## T4. Client rights (cl1)

Run as the container's identity from the host. `jq` runs on the host; the
guest only needs `sh`.

```bash
S='incus-backup-shell dr-test-xfs'
$S kopia snapshot list && echo LIST-OK
$S kopia policy show 'backup@dr-test-xfs.nippynetworks.com:/'
ID=$($S kopia snapshot list --json | jq -r '.[0].id')
$S kopia snapshot delete "$ID" --delete && echo DELETE-ALLOWED-BAD
$S kopia policy set --global --keep-latest=1 && echo GLOBAL-POLICY-ALLOWED-BAD
$S kopia policy set / --keep-latest=1 && echo PATH-POLICY-ALLOWED-BAD
$S kopia snapshot list --all --json | jq -e '[.[] | select(.source.host != "dr-test-xfs.nippynetworks.com")] | length > 0' >/dev/null && echo OTHER-HOSTS-VISIBLE-BAD
```

Expected: `LIST-OK`; the policy shows the `root-server` ignore rules as
"defined for this target"; no line ending in `-BAD`.

## T5. Custom volume discovery and backup (cl1)

```bash
incus storage list
incus storage volume create <pool> dr-test-xfs-data
incus config device add dr-test-xfs data disk pool=<pool> source=dr-test-xfs-data path=/srv/data
incus exec dr-test-xfs -- sh -c 'echo hello > /srv/data/marker; echo root > /root/marker'
incus-backup-provision dr-test-xfs
incus-backup-container dr-test-xfs
```

Expected: provisioning prints `Custom volume: device=data path=/srv/data` and
applies class `data` to `backup@dr-test-xfs.nippynetworks.com:/srv/data`; the
backup snapshots `/` and `/srv/data`. Then check that root did not descend
into the volume:

```bash
S='incus-backup-shell dr-test-xfs'
R=$($S kopia snapshot list --json | jq -r '.[-1].rootEntry.obj')
V=$($S kopia snapshot list /srv/data --json | jq -r '.[-1].rootEntry.obj')
$S kopia ls "$R/srv/"; $S kopia ls "$R/srv/data/" 2>&1 | head -3
$S kopia ls "$V"
```

Expected: `marker` appears under the volume snapshot. In the root snapshot
`srv/data` is absent or empty, because `oneFileSystem` stops at the mount.

## T6. Exclusions (cl1)

```bash
incus exec dr-test-xfs -- sh -c 'mkdir -p /var/cache/junk /srv/scratch; echo x > /var/cache/junk/f; echo y > /srv/scratch/f'
incus config set dr-test-xfs user.backup.exclude.root='/srv/scratch/'
incus-backup-provision dr-test-xfs
incus-backup-container dr-test-xfs
S='incus-backup-shell dr-test-xfs'
R=$($S kopia snapshot list --json | jq -r '.[-1].rootEntry.obj')
echo "--- var/cache (class rule):"; $S kopia ls "$R/var/cache/"
echo "--- srv (ad-hoc rule):";      $S kopia ls "$R/srv/"
```

Expected: `/var/cache/` is empty in the snapshot and `scratch` is absent
from `/srv/`.

## T7. A guest cannot exclude its own files (cl1)

Kopia honours `.kopiaignore` files named in the effective policy and skips
directories with a `CACHEDIR.TAG` unless `ignoreCacheDirs` is false. Earlier
attempts with `noParentDotFiles` alone failed, so this test has three parts.

Part 1: the effective policy of the source must list no dot-ignore files and
must not ignore cache directories. From the guest's own view:

```bash
incus-backup-shell dr-test-xfs kopia policy show 'backup@dr-test-xfs.nippynetworks.com:/' --json | jq '{files: .files, noParent: .noParent}'
```

Expected: `.files` has no `ignoreDotFiles` key, `ignoreCacheDirs` is false,
`oneFileSystem` is true. (`noParent` is only set on the global policy, so it
may be absent here.)

Part 2: plant the three traps, back up, remove the traps, inspect:

```bash
incus exec dr-test-xfs -- sh -c 'echo "/*" > /.kopiaignore'
incus exec dr-test-xfs -- sh -c 'echo "*" > /etc/.kopiaignore'
incus exec dr-test-xfs -- sh -c 'mkdir -p /etc/hideme && printf "Signature: 8a477f597d28d172789f06886806bc55\n" > /etc/hideme/CACHEDIR.TAG && echo secret > /etc/hideme/f'
incus-backup-container dr-test-xfs
incus exec dr-test-xfs -- rm -r /.kopiaignore /etc/.kopiaignore /etc/hideme
S='incus-backup-shell dr-test-xfs'
R=$($S kopia snapshot list --json | jq -r '.[-1].rootEntry.obj')
$S kopia snapshot list | tail -2
echo "--- /etc must be populated:"; $S kopia ls "$R/etc/" | head -5
echo "--- hideme/f must exist:";   $S kopia ls "$R/etc/hideme/"
```

Expected: the run hashes the normal number of files (tens of thousands, not
zero), `/etc` is listed, and `f` is under `etc/hideme`.

Part 3: prove the trap works when the protection is off, so the test itself
is meaningful. On `media`, temporarily restore Kopia's default:

```bash
kopia-admin policy set --global --add-dot-ignore=.kopiaignore
```

Repeat part 2. Expected now: the snapshot is empty or `/etc` is missing.
Then restore the protection and confirm part 2 passes again:

```bash
kopia-server-init
```

If part 2 fails with the protection on, stop and report the `policy show`
output from part 1; do not proceed to the scheduler tests.

## T8. Locks and re-entry (cl1)

```bash
incus-backup-container dr-test-xfs & sleep 1; incus-backup-container dr-test-xfs; wait
```

Expected: the second invocation prints "backup already running; skipping" and
exits 0. The scheduler behaves the same with `/run/incus-backup/scheduler.lock`.

## T9. Scheduler (cl1)

```bash
incus-backup-scheduler; echo "rc=$?"
tail -5 /var/log/incus-backup/scheduler.log
```

Expected: nothing starts while the last success is younger than the interval.
Force a run:

```bash
rm /var/lib/incus-backup/dr-test-xfs/last_success
incus-backup-scheduler; tail -3 /var/log/incus-backup/scheduler.log
```

Expected: `dr-test-xfs: starting (last success never)` and `finished ok`.

## T10. Pin guard (media)

```bash
kopia-pin-guard --dry-run
kopia-pin-guard
kopia-admin snapshot list --all | grep -c guard-
```

Expected: the dry run lists `add guard-daily ...` for the newest snapshot per
source per day; after the real run the snapshots show `pins:guard-...`.

## T11. Restore round trip (cl1)

```bash
S='incus-backup-shell dr-test-xfs'
R=$($S kopia snapshot list --json | jq -r '.[-1].rootEntry.obj')
$S kopia restore "$R/root/marker" /tmp/marker.restored
incus exec dr-test-xfs -- cat /tmp/marker.restored
```

Expected: `root`.

## T12. Cleanup in the guest (cl1)

```bash
incus exec dr-test-xfs -- ls -la /run/incus-backup /root/.cache/kopia 2>&1
incus exec dr-test-xfs -- du -sh /var/cache/kopia
```

Expected: the first two paths do not exist; only the cache remains.
