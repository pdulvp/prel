#!/usr/bin/env bash
# build-deb.sh - Build the installable .deb of prel
#
# Usage: packaging/build-deb.sh [usage|<x.y.z>]
#
# Not in scripts/: prel.sh sources every scripts/*.sh and turns it into a
# command, and a build script there would ship a 'prel build-deb' to everyone
# who installs the package - a command about prel's own clone, in the hands of
# people who do not have one.
#
# prel is shell, so there is nothing to compile and the package is
# Architecture: all. The repository tree goes to /usr/share/prel unchanged and
# /usr/bin/prel is a symlink into it, which is why no path inside any script
# has to know whether it is running from a clone or from an install.

set -euo pipefail

# What the package is called, and who answers for it.
PKG_NAME="prel"
PKG_MAINTAINER="pdulvp <pdulvp@laposte.net>"
PKG_HOMEPAGE="https://github.com/pdulvp/prel"

# The payload, named one by one. A whitelist rather than a blacklist: a
# top-level directory added to the repository later has to be named here
# before it ships, instead of shipping the day it appears.
PAYLOAD=(
	prel.sh
	scripts
	configs
	skills
	memory
	.githooks
)

_bd_usage() {
	cat <<EOF
build-deb - Build the installable .deb of prel

Usage:
  packaging/build-deb.sh            Build at the version in the VERSION file
  packaging/build-deb.sh <x.y.z>    Build at that version instead
  packaging/build-deb.sh usage      Show this help

Description:
  Writes build/${PKG_NAME}_<version>_all.deb, staging the package tree in
  build/${PKG_NAME}_<version>_all/ beside it. Both are gitignored.

  The package installs the repository tree to /usr/share/prel and symlinks
  /usr/bin/prel to /usr/share/prel/prel.sh, so an installed prel shares the
  hooks, the skill and the memories from there.

  'prel release' calls this through prel.buildCommand, which passes the
  version being released as the argument - the VERSION file is already at that
  version by then, so either source gives the same answer.

  Install the result with apt, which resolves the dependencies:

    sudo apt install ./build/${PKG_NAME}_<version>_all.deb
EOF
}

# The three numbers and nothing else, the same shape 'prel release' accepts.
_bd_valid_version() {
	[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]
}

main() {
	if [ "${1-}" = "usage" ] || [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then
		_bd_usage
		return 0
	fi

	local repo_root
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
		echo "Error: not in a git repository" >&2
		return 1
	}
	cd "$repo_root"

	command -v dpkg-deb >/dev/null 2>&1 || {
		echo "Error: dpkg-deb not found; install the 'dpkg' package to build" >&2
		return 1
	}

	# The argument wins over the file, so a release names the version it is
	# making rather than relying on the file having been written first.
	local version origin
	if [ -n "${1-}" ]; then
		version="$1"
		origin="given"
	elif [ -f VERSION ]; then
		version=$(tr -d '[:space:]' < VERSION)
		origin="from VERSION"
		[ -n "$version" ] || {
			echo "Error: VERSION is empty, so there is no version to build at" >&2
			return 1
		}
	else
		echo "Error: no version given and no VERSION file to read one from" >&2
		return 1
	fi

	_bd_valid_version "$version" || {
		echo "Error: '$version' is not a version; expected x.y.z" >&2
		return 1
	}

	local stage="build/${PKG_NAME}_${version}_all"
	local deb="build/${PKG_NAME}_${version}_all.deb"

	# Built from nothing every time: a stale file left in the staging tree
	# would go into the package without ever appearing in a diff.
	rm -rf "$stage" "$deb"
	mkdir -p "$stage/DEBIAN" "$stage/usr/share/${PKG_NAME}" \
		"$stage/usr/bin" "$stage/usr/share/doc/${PKG_NAME}"

	local item
	for item in "${PAYLOAD[@]}"; do
		[ -e "$item" ] || {
			echo "Error: $item is in the payload list but not in the tree" >&2
			return 1
		}
		cp -a "$item" "$stage/usr/share/${PKG_NAME}/"
	done

	# Relative, so the link is correct under a dpkg --instdir or inside a
	# chroot as well as at /.
	ln -s "../share/${PKG_NAME}/prel.sh" "$stage/usr/bin/${PKG_NAME}"

	cp -a README.md "$stage/usr/share/doc/${PKG_NAME}/"

	# Named 'copyright' rather than 'LICENSE': Debian policy puts the licence
	# of a package at that exact path, and tools look for it there.
	cp -a LICENSE "$stage/usr/share/doc/${PKG_NAME}/copyright"

	# The package sets its own modes instead of inheriting the clone's. Files
	# here are group-writable and some are mode 770, which installed
	# root-owned under /usr/share would leave /usr/share/prel/prel.sh
	# unreadable to every user but root - the package would install cleanly
	# and then refuse to run. Executable is the one bit worth carrying over,
	# so it decides between 755 and 644.
	find "$stage" -type d -exec chmod 0755 {} +
	find "$stage" -type f -perm /u+x -exec chmod 0755 {} +
	find "$stage" -type f ! -perm /u+x -exec chmod 0644 {} +

	# gh is Recommends, not Depends: only 'prel release' and
	# 'prel issue-from-plans' reach for it, and the rest of prel is useful on
	# a machine that has never heard of GitHub.
	cat > "$stage/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${version}
Section: vcs
Priority: optional
Architecture: all
Depends: bash (>= 4.0), git, coreutils
Recommends: gh
Maintainer: ${PKG_MAINTAINER}
Homepage: ${PKG_HOMEPAGE}
Description: Git management toolkit for commit attribution and hooks
 prel registers a set of git hooks, a skill and a set of memories with a
 repository, so that finished work plans are filed as GitHub issues and
 commits carry the attribution of whoever - or whatever - wrote them.
 .
 It also drives releases: moving a VERSION file on, tagging it, building the
 artifacts and publishing them to the GitHub release in one command.
EOF

	# --root-owner-group: the files belong to root in the package whatever the
	# building user happens to be, so no fakeroot and no surprise ownership.
	dpkg-deb --build --root-owner-group "$stage" "$deb" >/dev/null

	echo "Built $deb ($version, $origin)"
	echo "Install it with: sudo apt install ./$deb"
}

main "$@"
