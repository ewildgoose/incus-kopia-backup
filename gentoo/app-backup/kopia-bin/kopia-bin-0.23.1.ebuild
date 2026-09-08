# Copyright 2026 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

DESCRIPTION="Fast and secure backup/restore tool - prebuilt binary"
HOMEPAGE="https://kopia.io/ https://github.com/kopia/kopia"

SRC_URI="
	amd64? (
		https://github.com/kopia/kopia/releases/download/v${PV}/kopia-${PV}-linux-x64.tar.gz
			-> ${P}-linux-amd64.tar.gz
	)
	arm64? (
		https://github.com/kopia/kopia/releases/download/v${PV}/kopia-${PV}-linux-arm64.tar.gz
			-> ${P}-linux-arm64.tar.gz
	)
	arm? (
		https://github.com/kopia/kopia/releases/download/v${PV}/kopia-${PV}-linux-arm.tar.gz
			-> ${P}-linux-arm.tar.gz
	)
"

LICENSE="Apache-2.0"
SLOT="0"
KEYWORDS="amd64 arm arm64"

RESTRICT="strip"

BDEPEND="sys-devel/binutils"

QA_PREBUILT="usr/bin/kopia"

S="${WORKDIR}"

src_install() {
	local upstream_arch

	case ${ARCH} in
		amd64)
			upstream_arch="x64"
			;;
		arm64)
			upstream_arch="arm64"
			;;
		arm)
			upstream_arch="arm"
			;;
		*)
			die "Unsupported architecture: ${ARCH}"
			;;
	esac

	local bin="${WORKDIR}/kopia-${PV}-linux-${upstream_arch}/kopia"

	[[ -x ${bin} ]] || die "Kopia binary not found: ${bin}"

	# Kopia's official Linux binaries should be pure-Go static binaries.
	# Refuse to package one if upstream ever changes that.
	if readelf -l "${bin}" | grep -q 'Requesting program interpreter'; then
		die "Upstream Kopia binary is dynamically linked"
	fi

	if readelf -d "${bin}" 2>/dev/null | grep -q '(NEEDED)'; then
		die "Upstream Kopia binary has shared-library dependencies"
	fi

	dobin "${bin}"

	newinitd "${FILESDIR}/kopia-server.initd" kopia-server
	newconfd "${FILESDIR}/kopia-server.confd" kopia-server
}

pkg_postinst() {
	elog "Kopia repository server support has been installed."
	elog
	elog "The OpenRC service supports multiplexed instances, for example:"
	elog
	elog "  ln -s kopia-server /etc/init.d/kopia-server.backup"
	elog "  cp /etc/conf.d/kopia-server /etc/conf.d/kopia-server.backup"
	elog
	elog "Configure the instance in /etc/conf.d/kopia-server.backup,"
	elog "then start it with:"
	elog
	elog "  rc-service kopia-server.backup start"
	elog
	elog "Repository creation, credentials, TLS certificates and ACL policy"
	elog "are intentionally not created by the package and must be configured"
	elog "separately for each repository."
}

