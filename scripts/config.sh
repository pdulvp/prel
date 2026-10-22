#!/usr/bin/env bash
# config.sh - prel.config.json, the settings a repository gives prel
#
# Can be run directly or sourced from prel.sh
# Usage: prel config [usage]
#        OR: ./scripts/config.sh [usage]
#
# The settings prel invented for itself live in prel.config.json at the
# repository root, not in .git/config: a file can be committed, so the version
# file, the build commands and the artifacts of a project travel with the clone
# instead of being set once per machine by hand.
#
# git's own settings - commit.coauthor, core.hooksPath, include.path,
# commit.cleanup - are not here. They are read by git itself, or by the
# configs/.gitconfig-* includes, and belong where git looks for them.

# Every key prel reads, and what it means where the file says nothing. 'list'
# is the one array, 'text' the plain strings; the type is what _prel_config_check
# holds a value against.
_PREL_CONFIG_KEYS=(versionFile tagPrefix buildCommand releaseBuildCommand \
	artifacts plansDir)
_PREL_CONFIG_TYPES=(text text text text list text)
_PREL_CONFIG_DEFAULTS=(VERSION v "" "" "" docs/plans)

# The old git config keys, by the name they had, each with the prel.config.json
# key it became. Read no more - a repository still carrying one is told about it
# rather than quietly obeying it.
#
# prel.buildCommand was read by the release, so releaseBuildCommand is where it
# goes - not buildCommand, which is the ordinary build 'prel build' runs.
_PREL_CONFIG_GIT_KEYS=(prel.versionFile prel.tagPrefix prel.buildCommand \
	prel.artifacts prel.plansDir)
_PREL_CONFIG_GIT_NEW=(versionFile tagPrefix releaseBuildCommand \
	artifacts plansDir)

_prel_config_path() {
	local root
	root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	printf '%s/prel.config.json\n' "$root"
}

# The name to call it in a message: relative to the repository root, the way
# every path prel reports is, since that is where the file is looked for.
_prel_config_name() {
	local file root
	file=$(_prel_config_path) || return 1
	root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
	if [ -n "$root" ]; then
		printf '%s\n' "${file#"$root"/}"
	else
		printf '%s\n' "$file"
	fi
}

# Whether there is a file to read at all. Most repositories have none and take
# every default, which is why nothing here needs jq until one appears.
_prel_config_exists() {
	local file
	file=$(_prel_config_path) || return 1
	[ -f "$file" ]
}

# The whole file as one JSON object: 0 with it on stdout, 1 where there is no
# file, 2 where there is one that cannot be read. Silent on every one of the
# three - a reader is called from inside a command substitution, so a message
# from here would come out once per setting asked for, and once more for the
# next. _prel_config_check is the one voice, and the commands run it first.
_prel_config_read() {
	local file
	file=$(_prel_config_path) || return 1
	[ -f "$file" ] || return 1
	command -v jq >/dev/null 2>&1 || return 2
	jq -e 'if type == "object" then . else error("not an object") end' "$file" 2>/dev/null \
		|| return 2
}

# One text setting by key: printed and 0 where the file sets it, 1 where it
# does not, 2 where the file is there and unreadable. The three answers are
# worth keeping apart - "tagPrefix": "" means a bare tag, which is not the
# same as no tagPrefix at all.
_prel_config_get() {
	local key="$1" json out
	json=$(_prel_config_read) || return $?
	# 'v' or 'u' in front rather than a separator between: the value is
	# arbitrary text, and nothing has to be chosen that it cannot contain.
	out=$(printf '%s' "$json" | jq -r --arg k "$key" \
		'if has($k) and .[$k] != null then "v" + (.[$k] | tostring) else "u" end' 2>/dev/null) \
		|| return 2
	[ "$out" = "u" ] && return 1
	printf '%s\n' "${out#v}"
}

# The one list setting, an element a line: an array as it stands, a string
# split on whitespace the way the git config value was. 1 where the file does
# not set it, 2 where it cannot be read. An array of nothing prints nothing
# and returns 0 - a project saying it has no artifacts has said something.
_prel_config_list() {
	local key="$1" json
	json=$(_prel_config_read) || return $?
	printf '%s' "$json" | jq -er --arg k "$key" '
		if has($k) and .[$k] != null then
			if (.[$k] | type) == "array" then .[$k][] | tostring
			else .[$k] | tostring | [splits("[[:space:]]+")] | map(select(length > 0)) | .[]
			end
		else error("absent") end' 2>/dev/null
	local rc=${PIPESTATUS[1]}
	# jq -e exits 1 on an empty result as well as on the error above, so an
	# array of nothing and an absent key are told apart here.
	if [ "$rc" != "0" ]; then
		printf '%s' "$json" | jq -e --arg k "$key" 'has($k) and .[$k] != null' >/dev/null 2>&1 \
			&& return 0
		return 1
	fi
	return 0
}

# A text setting, or its default where the file is silent. The reading errors
# are not hidden: a file that cannot be read fails the command that wanted a
# setting out of it, rather than handing back a default that looks like one.
_prel_config_text() {
	local key="$1" default="$2" value
	value=$(_prel_config_get "$key")
	case $? in
		0) printf '%s\n' "$value" ;;
		1) printf '%s\n' "$default" ;;
		*) return 2 ;;
	esac
}

# What the key set says about a file: a key prel does not know, a value of the
# wrong shape, or a prel.* git config key left behind by the move. Written to
# stderr, non-zero where anything was said, so a command can refuse to run on
# a config it cannot make sense of.
#
# git config could not be checked this way - any key is a valid key there -
# which is half the reason for a file with a known shape.
_prel_config_check() {
	local json file key type i rc=0
	local -a unknown=()

	if _prel_config_exists; then
		file=$(_prel_config_name)
		# jq is Recommends rather than Depends: prel reaches for it only in a
		# repository that has a prel.config.json. One it cannot read must not
		# pass for one that is not there - a release that quietly forgot its
		# artifacts is the failure worth avoiding.
		if ! command -v jq >/dev/null 2>&1; then
			echo "Error: $file needs jq to be read, and jq is not installed" >&2
			echo "       install it ('sudo apt install jq'), or remove the file to" >&2
			echo "       take every prel setting at its default" >&2
			return 2
		fi
		if ! json=$(_prel_config_read); then
			echo "Error: $file is not readable as a JSON object" >&2
			echo "       check it with 'jq . $file'" >&2
			return 2
		fi

		mapfile -t unknown < <(printf '%s' "$json" | jq -r \
			--argjson known "$(printf '%s\n' "${_PREL_CONFIG_KEYS[@]}" \
				| jq -R . | jq -s .)" \
			'keys_unsorted - $known | .[]' 2>/dev/null)
		if [ ${#unknown[@]} -gt 0 ]; then
			echo "Warning: $file sets keys prel does not read:" >&2
			printf '         %s\n' "${unknown[@]}" >&2
			echo "         prel reads: ${_PREL_CONFIG_KEYS[*]}" >&2
			rc=1
		fi

		local actual
		for i in "${!_PREL_CONFIG_KEYS[@]}"; do
			key="${_PREL_CONFIG_KEYS[$i]}"
			type="${_PREL_CONFIG_TYPES[$i]}"
			actual=$(printf '%s' "$json" | jq -r --arg k "$key" \
				'if has($k) then (.[$k] | type) else "absent" end' 2>/dev/null)
			case "$type:$actual" in
				*:absent|text:string|list:array|list:string) ;;
				text:*)
					echo "Error: $file: $key should be a string, not $actual" >&2
					rc=2
					;;
				list:*)
					echo "Error: $file: $key should be an array of strings, or one" >&2
					echo "       string of them separated by spaces, not $actual" >&2
					rc=2
					;;
			esac
		done
	fi

	# The move left these unread. A repository still setting one is set up for
	# a prel that no longer looks there, and silence would be indistinguishable
	# from it still working.
	local git_key value
	for i in "${!_PREL_CONFIG_GIT_KEYS[@]}"; do
		git_key="${_PREL_CONFIG_GIT_KEYS[$i]}"
		value=$(git config --get "$git_key" 2>/dev/null) || continue
		echo "Warning: $git_key is set in git config and is read no more:" >&2
		echo "         $git_key=$value" >&2
		echo "         move it to prel.config.json as \"${_PREL_CONFIG_GIT_NEW[$i]}\", then" >&2
		echo "         'git config --unset $git_key'" >&2
		[ "$rc" = "0" ] && rc=1
	done

	return $rc
}

# The check with its say, for a command asked by hand: the diagnosis in full,
# non-zero only where the file cannot be made sense of. Warnings have been
# printed by then and are not worth refusing over.
_prel_config_ok_verbose() {
	local rc
	_prel_config_check
	rc=$?
	[ "$rc" -le 1 ]
}

# A list of settings as one line, for the lines that report them: an entry
# holding a space is quoted, so a list of two never reads as a list of three.
_prel_list_line() {
	local item out=""
	for item in "$@"; do
		case "$item" in
			*[[:space:]]*) item="'$item'" ;;
		esac
		[ -n "$out" ] && out="$out "
		out="$out$item"
	done
	printf '%s\n' "$out"
}

config() {
	if [ "${1-}" = "usage" ]; then
		cat <<'USAGE'
config - The settings this repository gives prel, and where they come from

Usage:
  prel config usage     Show this help
  prel config           Show every setting, its value and whether it is a
                        default, and report anything wrong with the file

Description:
  prel reads its own settings from prel.config.json at the repository root -
  a file, so it can be committed and travel with the clone, unlike the
  prel.* git config keys it replaces:

    {
      "versionFile": "VERSION",
      "tagPrefix": "v",
      "buildCommand": "make",
      "releaseBuildCommand": "packaging/build-deb.sh ${version}",
      "artifacts": ["build/prel_${version}_all.deb"],
      "plansDir": "docs/plans"
    }

  Every key is optional and the file itself is optional; a repository with
  none takes the defaults this command prints. The keys are:

    versionFile          where the version is, for 'prel release'   (VERSION)
    tagPrefix            what goes in front of the tag; "" for none (v)
    buildCommand         the shell command 'prel build' runs
    releaseBuildCommand  the shell command that builds the release artifacts,
                         run by 'prel release' and by 'prel build --release'
    artifacts            the globs to attach to the release, an array, or one
                         string of them separated by spaces
    plansDir             where 'prel issue-from-plans' looks for plans
                         (docs/plans)

  The two build commands are read one by its own command and never the other:
  'prel build' runs buildCommand, a release runs releaseBuildCommand, and a
  key not set means there is no build to run rather than the other one.

  ${version} and ${tag} in the two build commands and in artifacts are filled
  in with the version being built and the tag it gets - see 'prel build usage'
  and 'prel release usage'.

  Reading the file needs jq, and nothing else about prel does: a repository
  with no prel.config.json never reaches for it. Where the file is there and
  jq is not, prel says so and stops rather than taking every setting at its
  default behind your back.

  git's own settings are not in here. commit.coauthor, core.hooksPath,
  commit.cleanup and include.path are read by git itself, or by the
  configs/.gitconfig-* includes, and stay in git config where git looks.
USAGE
		return 0
	fi

	if [ $# -gt 0 ]; then
		echo "Error: Unknown action '$1' for config" >&2
		echo "Try: prel config usage" >&2
		return 1
	fi

	local file root
	root=$(git rev-parse --show-toplevel 2>/dev/null) || {
		echo "Error: Not in a git repository" >&2
		return 1
	}
	file=$(_prel_config_name)

	if _prel_config_exists; then
		printf '%-21s %s\n' "file:" "$file"
	else
		printf '%-21s %s\n' "file:" "none ($file is not there; every setting is a default)"
	fi

	# First, so that nothing below prints a value out of a file whose shape
	# has already been found wanting.
	local rc=0
	_prel_config_check || rc=$?
	if [ "$rc" = "2" ]; then
		echo "prel config: the file is not usable as it stands" >&2
		return 2
	fi

	local i key type default value
	local -a list=()
	for i in "${!_PREL_CONFIG_KEYS[@]}"; do
		key="${_PREL_CONFIG_KEYS[$i]}"
		type="${_PREL_CONFIG_TYPES[$i]}"
		default="${_PREL_CONFIG_DEFAULTS[$i]}"
		if [ "$type" = "list" ]; then
			if mapfile -t list < <(_prel_config_list "$key") && [ ${#list[@]} -gt 0 ]; then
				printf '%-21s %s\n' "$key:" "$(_prel_list_line "${list[@]}")"
				[ ${#list[@]} -gt 1 ] && printf '%-21s (%d patterns)\n' "" "${#list[@]}"
			else
				printf '%-21s %s\n' "$key:" "none (default)"
			fi
			continue
		fi
		value=$(_prel_config_get "$key")
		case $? in
			0) printf '%-21s %s\n' "$key:" "${value:-\"\" (empty, set on purpose)}" ;;
			1) printf '%-21s %s\n' "$key:" "${default:-none} (default)" ;;
			*) rc=2 ;;
		esac
	done

	if [ "$rc" = "0" ]; then
		echo ""
		echo "prel config: nothing to report"
	fi
	return $rc
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	config "$@"
fi
