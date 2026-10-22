#!/usr/bin/env bash
# build.sh - Run the build a release would run, and nothing else
#
# Can be run directly or sourced from prel.sh
# Usage: prel build [usage|<x.y.z> [options]]
#        OR: ./scripts/build.sh [usage|<x.y.z> [options]]
#
# releaseBuildCommand in prel.config.json is the command 'prel release' runs
# between the tag and the push. This runs the same command, from the same
# directory, with the same two variables, and leaves the commit, the tag and
# the push out of it: a build worth depending on at release time is one that
# has been run before the release depends on it.
#
# The settings are the release's settings, read by release.sh - the version
# file the version comes from, the tag prefix it gets, the build command
# itself. Nothing here is configured separately: the point is to run what a
# release would run.

# The build command itself, from the repository root, with $version and $tag
# as shell variables. "packaging/build-deb.sh ${version}" is a string the
# shell expands, which is how a build is told which version it is building;
# the two names are documented, so both 'prel build' and the build step of
# 'prel release' come through here rather than each expanding its own.
_prel_build_eval() {
	local version="$1" tag="$2" command="$3" root
	root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	# In a subshell, so the directory it builds from is its own and an
	# exported variable or a trap it leaves behind is not prel's to carry.
	( cd "$root" && eval "$command" )
}

build() {
	local version="" origin="" dry_run=0
	local repo_root version_file tag command rc=0

	if [ "${1-}" = "usage" ]; then
		cat <<'USAGE'
build - Run the build a release would run, without releasing anything

Usage:
  prel build usage        Show this help
  prel build              Build at the version the version file reads
  prel build <x.y.z>      Build at a version not yet in the file
  prel build -n           Show what would run, run nothing

Description:
  releaseBuildCommand in prel.config.json is the command 'prel release' runs
  between the tag and the push - see 'prel config'. This runs that command
  and stops there: nothing is committed, tagged, pushed or published, so a
  build can be tried as often as it takes.

    { "releaseBuildCommand": "packaging/build-deb.sh ${version}" }

  The command runs from the repository root, with $version set to the version
  being built and $tag to the tag it would get, which is how a build is told
  which version it is building. ${version} and ${tag} are filled in by the
  shell, so the whole of it is a shell command.

  The version comes from the version file as it reads now, or from the
  argument where the build is for a version the file has not reached yet -
  'prel build 1.0.1' builds what 'prel release 1.0.1' would build.

  The exit status is the build's own, so a script can gate on it. Where
  artifacts is set, what its patterns match is printed afterwards as a
  report; 'prel release artifacts' is the command that answers with its exit
  status whether every pattern matched.
USAGE
		return 0
	fi

	while [ $# -gt 0 ]; do
		case "$1" in
			-n|--dry-run) dry_run=1 ;;
			-*)
				echo "Error: Unknown option '$1' for build" >&2
				echo "Try: prel build usage" >&2
				return 1
				;;
			*)
				if [ -n "$version" ]; then
					echo "Error: one version at a time, got '$version' and '$1'" >&2
					return 1
				fi
				version="$1"
				;;
		esac
		shift
	done

	repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$repo_root" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$repo_root" || return 1

	# A config worth reporting on before it is read for a command to run.
	_prel_config_ok_verbose || return 1

	# Nothing to build is the ordinary case - most projects release a tag and
	# no files - and not a failure. Said with the key to set, since a 'prel
	# build' that printed nothing would look like a build that did nothing.
	command=$(_rel_build_command) || return 1
	if [ -z "$command" ]; then
		echo "releaseBuildCommand is not set in prel.config.json: there is no build"
		echo "to run here. Set it with, say:"
		echo ""
		echo '  { "releaseBuildCommand": "packaging/build-deb.sh ${version}" }'
		return 0
	fi

	if [ -n "$version" ]; then
		if ! _rel_is_version "$version"; then
			echo "Error: '$version' is not a version of three numbers (1.0.1, 1.0.1-rc1)" >&2
			return 1
		fi
		origin="given"
	else
		# What the file reads now: the version the tree is at, which is the
		# version its build produces. Taken as it reads rather than checked -
		# a version worth refusing is refused by the release itself.
		version_file=$(_rel_version_file) || return 1
		if [ ! -f "$version_file" ]; then
			echo "Error: no $version_file in $repo_root to take the version from" >&2
			echo "       pass one, as in 'prel build 1.0.1'" >&2
			return 1
		fi
		version=$(tr -d '[:space:]' < "$version_file")
		if [ -z "$version" ]; then
			echo "Error: $version_file is empty, so there is no version to build at" >&2
			echo "       pass one, as in 'prel build 1.0.1'" >&2
			return 1
		fi
		origin="from $version_file"
	fi

	tag="$(_rel_tag_prefix)$version" || return 1

	echo "build:        $command"
	echo "version:      $version ($origin)"
	echo "tag:          $tag"

	if [ "$dry_run" = "1" ]; then
		echo ""
		echo "prel build: nothing run, -n"
		return 0
	fi

	echo ""
	_prel_build_eval "$version" "$tag" "$command"
	rc=$?
	echo ""
	if [ "$rc" != "0" ]; then
		echo "Error: the build failed (exit $rc); nothing here was going to be" >&2
		echo "       released, so there is nothing to undo" >&2
		return $rc
	fi

	# What the release would upload, where the project names any: the build
	# just ran, so this is the one moment the patterns can be held against
	# the files they are meant to match. A report rather than a verdict -
	# 'prel release artifacts' is the one that exits non-zero over a pattern
	# that matched nothing.
	_rel_artifacts || return 0
	if [ ${#_REL_PATTERNS[@]} -gt 0 ]; then
		local -a patterns=("${_REL_PATTERNS[@]}")
		if _rel_expand_artifacts "$version" "$tag" "${patterns[@]}"; then
			echo "artifacts:"
			printf '  %s\n' "${_REL_ASSETS[@]}"
		else
			echo "artifacts:"
			[ ${#_REL_ASSETS[@]} -gt 0 ] && printf '  %s\n' "${_REL_ASSETS[@]}"
			printf '  %s (matched no file)\n' "${_REL_MISSING[@]}"
			echo "'prel release artifacts' says the same and exits non-zero over it."
		fi
		echo ""
	fi

	echo "prel build: $version built"
	return 0
}

# If this script is run directly (not sourced), call the function. Sourced
# from prel.sh its siblings are already loaded; run directly, the config
# reader and the release settings have to be loaded here - each script guards
# its own direct-run block, so sourcing them only defines their functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_build_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	for _build_sibling in config.sh release.sh; do
		# shellcheck source=/dev/null
		[ -r "$_build_dir/$_build_sibling" ] && source "$_build_dir/$_build_sibling"
	done
	build "$@"
fi
