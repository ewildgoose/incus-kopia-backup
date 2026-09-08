# Gotchas

Short reminders of behaviour that cost time. Each item was checked against
the Kopia v0.23.1 source or against a running system. Re-check the Kopia items
after a Kopia upgrade.

## Kopia policies

- **Empty lists never win.** When Kopia merges policies (path, then user,
  then host, then global) a list field such as `ignoreDotFiles` takes the
  first non-empty value. Setting a list to empty on any level does nothing.
  After the global policy, Kopia merges its built-in defaults, which include
  `ignoreDotFiles: [".kopiaignore"]`.
- **`noParentDotFiles` does not remove `.kopiaignore`.** It only clears the
  inherited dot-file list inside a directory context, and the list is filled
  again from the same policy. At the snapshot root Kopia loads every file
  named in the effective `ignoreDotFiles`.
- **`noParent=true` on the global policy is the switch that stops the
  built-in defaults.** Merging returns before the defaults, so an absent
  `ignoreDotFiles` stays absent. Everything else the built-in defaults would
  supply must then be present in the global policy. The global policy created
  by `repository create` has all sections. `kopia-server-init` sets this with
  `policy export --global | jq | policy import --global` because the CLI has
  no flag for `ignoreDotFiles=none`; `policy set --inherit=false` sets
  `noParent` but does not clear the list.
- **`ignoreCacheDirs` defaults to true.** Any directory with a `CACHEDIR.TAG`
  file carrying the standard signature is skipped. A guest can hide `/etc`
  that way. Every class file and the global policy set it to false.
- **Retention counts buckets that contain snapshots**, newest first, and
  keeps the newest snapshot per bucket. `keep-hourly 24` with a 6-hour
  interval keeps 24 snapshots over 6 days.
- **The client evaluates `ignore`, `oneFileSystem`, `compression`; the server
  evaluates retention.** So the client must be able to read its own policy
  (next section), but retention works even if it cannot.

## Kopia ACLs

- **Target rules are label subsets.** `type=policy,username=OWN_USER,hostname=OWN_HOST`
  matches both the `user@host` policy and every `user@host:/path` policy.
  `OWN_USER` and `OWN_HOST` are replaced by the connecting identity.
- **Reads are filtered per manifest.** `FindManifests` silently drops
  manifests the identity cannot READ. A client without READ on its own path
  policy sees no error; it just backs up without the exclusions.
- **APPEND lets a client apply retention to its own source.** `snapshot
  create` ends with a server-side retention run for that source, and the RPC
  only requires APPEND on the client's snapshots. Combined with
  `snapshot create --start-time`, a client can expire its own genuine
  snapshots. Pins are the defence: `snapshot pin` needs FULL, and expiry
  never removes a pinned snapshot. `kopia-pin-guard` maintains the pins.
- **`acl add` on an existing user and target replaces the entry** when the
  new access is not lower; with `--overwrite` it always replaces. `acl enable`
  fails with "ACLs already enabled" once any entry exists; do not use it.
- **`acl list` prints target labels in random order.** Compare entries by
  sorted labels (`kopia-server-init` does).
- **Content is shared.** Every client has APPEND on `type=content`, which
  includes read by content ID. IDs are HMACs of plaintext with a repository
  secret that every client session receives. A client can confirm a known
  file exists; it cannot enumerate content.

## Kopia server

- **Users and ACLs written by other clients are invisible until the server
  refreshes its repository view**: every `--refresh-interval` (default 4h),
  on SIGHUP (`rc-service kopia-server reload`), or via `kopia server refresh`
  with the control password. The 10-second caches inside the server read
  from that view, so they do not help.
- **The server runs maintenance** when its identity is the maintenance
  owner (`kopia-admin maintenance info`). No maintenance cron is needed.
- **`--override-username` and `--override-hostname` are hidden flags.** They
  do not appear in `--help` but work on every `repository connect` variant.
- **`--persist-credentials` is a global flag** (before the subcommand). With
  the default `true` and no keyring, `repository connect` writes
  `<config>.kopia-password` next to the config file. Use
  `--no-persist-credentials` and pass `KOPIA_PASSWORD` in the environment, or
  delete the sidecar.
- **`server users add --user-password` puts the password in the process
  argument list.** Only root logs in on the hosts; accepted.
- **`(global)`** is the key Kopia uses for the global policy in
  `policy export` and `policy import`.

## Incus and the guest

- **`incus query /1.0/instances/<name>` returns the instance object directly**
  (no `metadata` wrapper); `expanded_config` and `expanded_devices` include
  profile values. `incus config get` without `-e` shows instance-local
  values only.
- **Custom volumes are `disk` devices with `pool`, `source` and `path`.**
  Bind mounts have no `pool`; the root disk has `path: /`.
- **`oneFileSystem` skips mount points entirely.** In the root snapshot a
  volume's mount directory is absent or empty. That is why volumes are
  separate sources.
- **The guest runtime directory must allow execution.** Some images mount
  `/run` with `noexec`; set `user.backup.runtime_dir` on such instances.
- **`user.backup.hostname` is lowercased.** Kopia identities are case
  sensitive; keep them lowercase everywhere.
- **The guest cannot be prevented from lying.** Root in the guest can replace
  the injected binary between push and exec, ptrace it, or mount over data.
  A read-only device mount of the host's binary was considered and rejected:
  guest root can still unmount it, and the extra device add/remove slows every
  run. Detection, not prevention: watch sizes and file counts.

## Host scripts

- **`last_success` holds the start time of the run**, not the end time, so
  the interval measures from the moment the data was read.
- **A failed source does not stop the other sources** in the same run, but
  the run is marked failed and `last_success` does not advance.
- **The scheduler needs bash 5.1** (`wait -n -p`). Gentoo has 5.2 or later.
- **`hostname -f` decides `KOPIA_ADMIN_HOSTNAME`** unless set explicitly.
  The value must equal the FQDN given to `kopia-server-add-host`.
