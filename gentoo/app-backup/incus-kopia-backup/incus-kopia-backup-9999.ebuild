# Copyright 2026 Ed Wildgoose
# Distributed under the terms of the MIT license

EAPI=8

inherit git-r3

DESCRIPTION="Kopia repository-server backups of Incus/LXD containers"
HOMEPAGE="https://github.com/ewildgoose/incus-kopia-backup"
EGIT_REPO_URI="https://github.com/ewildgoose/incus-kopia-backup.git"
# The repository is private. Either give the portage user an SSH key for it,
# or build from a local checkout:
#   EGIT_OVERRIDE_REPO_INFRA_INCUS_KOPIA_BACKUP=file:///usr/src/incus-kopia-backup emerge ...

LICENSE="MIT"
SLOT="0"
IUSE="+client server"
REQUIRED_USE="|| ( client server )"
KEYWORDS="amd64 arm arm64"

# The client also needs the incus or lxc CLI. It comes with the container
# host itself, so it is not listed here.
RDEPEND="
	app-backup/kopia-bin
	>=app-shells/bash-5.1
	app-misc/jq
	sys-apps/util-linux
	dev-libs/openssl
	virtual/cron
	client? ( app-admin/logrotate )
"

src_install() {
	dodoc README.md docs/*.md

	if use client; then
		dosbin host/incus-backup-provision host/incus-backup-container \
			host/incus-backup-scheduler host/incus-backup-status host/incus-backup-shell

		insinto /usr/lib/incus-backup
		doins host/lib/common.sh

		insinto /etc
		doins host/incus-backup.conf

		insinto /etc/incus-backup/policies.d
		doins host/policies.d/*.conf

		keepdir /etc/incus-backup/credentials
		fperms 0700 /etc/incus-backup /etc/incus-backup/credentials

		keepdir /var/lib/incus-backup /var/log/incus-backup
		fperms 0750 /var/lib/incus-backup /var/log/incus-backup

		insinto /etc/cron.d
		newins "${FILESDIR}/incus-backup.crond" incus-backup

		insinto /etc/logrotate.d
		newins "${FILESDIR}/incus-backup.logrotate" incus-backup
	fi

	if use server; then
		dosbin server/kopia-admin server/kopia-server-fingerprint server/kopia-server-init \
			server/kopia-server-add-host server/kopia-expire-snapshots server/kopia-pin-guard

		insinto /etc/kopia
		doins server/pin-guard.conf

		keepdir /etc/kopia /var/log/kopia
		fperms 0700 /etc/kopia
		fperms 0750 /var/log/kopia

		insinto /etc/cron.d
		newins "${FILESDIR}/kopia-server.crond" kopia-server
	fi
}

pkg_postinst() {
	if use client; then
		elog "Container host setup (see host-setup.md in /usr/share/doc/${PF}):"
		elog "  1. Edit /etc/incus-backup.conf: server URL and certificate fingerprint."
		elog "  2. On the server: kopia-server-add-host $(hostname -f 2>/dev/null)"
		elog "     Store the printed password in /etc/incus-backup/admin.password (0600)."
		elog "  3. Per instance: set user.backup.* keys, then incus-backup-provision <instance>"
		elog "  4. Check: incus-backup-status"
		elog "  /etc/cron.d/incus-backup runs the scheduler every 15 minutes."
	fi
	if use server; then
		elog "Server setup (see server-setup.md in /usr/share/doc/${PF}):"
		elog "  1. /etc/conf.d/kopia-server: KOPIA_LISTEN_ADDRESS=0.0.0.0:51515 and"
		elog "     KOPIA_SERVER_OPTIONS=\"--no-ui --refresh-interval=1m\", then restart kopia-server."
		elog "  2. kopia-server-init        (restrict ACLs, harden the global policy)"
		elog "  3. kopia-server-add-host <container-host-fqdn>   for each trusted host"
		elog "  /etc/cron.d/kopia-server runs kopia-pin-guard and kopia-expire-snapshots nightly."
		elog "  Remove any older expiry cron entry such as /etc/cron.d/kopia-expire."
	fi
}
