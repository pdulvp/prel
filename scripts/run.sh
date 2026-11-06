#!/usr/bin/env bash
# run.sh - Run one of the named commands of prel.config.json
#
# Can be run directly or sourced from prel.sh
# Usage: prel run [usage|-n <name> [args...]]
#        OR: ./scripts/run.sh [usage|-n <name> [args...]]
#
# prel.config.json names the commands a project wants one word away, in its
# "commands" list - each an object with a "name" and the "launch" shell
# command to run under it. 'prel run <name>' runs the launch of the command
# called <name>, and the arguments after the name are appended to the launch,
# so 'prel run test unit' runs the launch of "test" with "unit" on its command
# line.
#
# The launch runs from the repository root with $version and $tag set the way
# 'prel build' sets them, so "${version}" in a launch is the version the
# version file reads - the same convention as the two build commands.

# A launch string, run the way 'prel build' runs a build command: from the
# repository root, in a subshell so the directory and anything it exports are
# its own, with $version and $tag in scope and the remaining arguments
# appended to the command line one by one, %q-quoted, so an argument holding
# a space stays one argument.
_prel_run_eval() {
	local version="$1" tag="$2" launch="$3"
	shift 3
	local root args=""
	root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	if [ $# -gt 0 ]; then
		args=$(printf '%q ' "$@")
	fi
	( cd "$root" && eval "$launch $args" )
}

run() {
	local name="" dry_run=0

	if [ "${1-}" = "usage" ]; then
		cat <<'USAGE'
run - Run one of the named commands of prel.config.json

Usage:
  prel run usage              Show this help
  prel run                    List the named commands of the repository
  prel run <name>             Run the command called <name>
  prel run <name> [args...]   Run it with the remaining arguments appended
  prel run -n <name> [args]   Show what would run, run nothing

Description:
  commands in prel.config.json is a list of named commands, each an object
  with a "name" and the "launch" shell command run under that name:

    { "commands": [
        { "name": "deb", "launch": "packaging/build-deb.sh ${version}" },
        { "name": "test", "launch": "make test" }
    ] }

  'prel run deb' runs the launch of the command named "deb". 'prel run test
  unit' runs the launch of "test" with "unit" appended to the command line:
  every argument after the name is added to the launch, quoted one by one,
  so an argument holding a space stays one argument. The exit status is the
  command's own, so a script can gate on it.

  The launch runs from the repository root, in a subshell, with $version set
  to the version the version file reads and $tag to the tag it would get -
  the same two 'prel build' gives its build command - so "${version}" in a
  launch is filled in by the shell. Where the repository has no version
  file, the two are empty rather than an error: a command that never mentions
  them does not need one.

  A name the file does not define is an error, and the names it does define
  are listed. With no name at all, 'prel run' lists them and runs nothing.
  With no commands in the file, it says how to add one.
USAGE
		return 0
	fi

	# The first word is the name; everything after it belongs to the command
	# being run, options included, and is passed on untouched.
	while [ $# -gt 0 ] && [ -z "$name" ]; do
		case "$1" in
			-n|--dry-run) dry_run=1 ;;
			-*)
				echo "Error: Unknown option '$1' for run" >&2
				echo "Try: prel run usage" >&2
				return 1
				;;
			*) name="$1" ;;
		esac
		shift
	done

	local repo_root
	repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$repo_root" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$repo_root" || return 1

	# A config worth reporting on before it is read for a command to run.
	_prel_config_ok_verbose || return 1

	local -a entries=()
	mapfile -t entries < <(_prel_config_commands)

	# No name: the list of what can be run, and nothing else.
	if [ -z "$name" ]; then
		if [ ${#entries[@]} -eq 0 ]; then
			echo "commands is not set in prel.config.json: there is no named command"
			echo "to run. Add a list like:"
			echo ""
			echo '  "commands": ['
			echo '    { "name": "deb", "launch": "packaging/build-deb.sh ${version}" }'
			echo '  ]'
			return 0
		fi
		echo "Named commands in prel.config.json:"
		local entry
		for entry in "${entries[@]}"; do
			printf '  %-16s %s\n' "${entry%%$'\t'*}" "${entry#*$'\t'}"
		done
		echo ""
		echo "Run one with: prel run <name> [args...]"
		return 0
	fi

	local launch
	launch=$(_prel_config_command_launch "$name")
	case $? in
		0) ;;
		1)
			echo "Error: no command named '$name' in prel.config.json" >&2
			if [ ${#entries[@]} -gt 0 ]; then
				echo "Named commands:" >&2
				local entry
				for entry in "${entries[@]}"; do
					printf '  %s\n' "${entry%%$'\t'*}" >&2
				done
			else
				echo "commands is not set in prel.config.json at all" >&2
			fi
			return 1
			;;
		*) return 2 ;;
	esac

	# The version and the tag a launch may name, read by release.sh's settings
	# like 'prel build' reads them. Not an error where the file is absent: the
	# variables are simply empty.
	local version="" tag version_file
	version_file=$(_rel_version_file) || return 1
	if [ -f "$version_file" ]; then
		version=$(tr -d '[:space:]' < "$version_file")
	fi
	tag="$(_rel_tag_prefix)$version" || return 1

	printf '%-21s %s\n' "command:" "$name"
	printf '%-21s %s\n' "launch:" "$launch"
	[ $# -gt 0 ] && printf '%-21s %s\n' "args:" "$(_prel_list_line "$@")"
	printf '%-21s %s\n' "version:" "${version:-none}"
	printf '%-21s %s\n' "tag:" "${tag:-none}"

	if [ "$dry_run" = "1" ]; then
		echo ""
		echo "prel run $name: nothing run, -n"
		return 0
	fi

	echo ""
	_prel_run_eval "$version" "$tag" "$launch" "$@"
	local rc=$?
	echo ""
	if [ "$rc" != "0" ]; then
		echo "Error: command '$name' failed (exit $rc)" >&2
		return $rc
	fi

	echo "prel run: '$name' done"
	return 0
}

# If this script is run directly (not sourced), call the function. Sourced
# from prel.sh its siblings are already loaded; run directly, the config
# reader and the release settings have to be loaded here - each script guards
# its own direct-run block, so sourcing them only defines their functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_run_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	for _run_sibling in config.sh release.sh; do
		# shellcheck source=/dev/null
		[ -r "$_run_dir/$_run_sibling" ] && source "$_run_dir/$_run_sibling"
	done
	run "$@"
fi
