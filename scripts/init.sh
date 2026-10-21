#!/usr/bin/env bash
# init.sh - Register everything prel shares with a repository, in one go
#
# Can be run directly or sourced from prel.sh
# Usage: prel init [usage|register|unregister|status] [--copy]
#        OR: ./scripts/init.sh [usage|register|unregister|status]
#
# 'prel issue-from-plans' only works when all three of the hooks, the skill and
# the memories are registered, and missing one disables it without saying so.
# This is the command that keeps them together.

# Run one of the commands init drives, under its own heading.
_init_step() {
	local heading="$1" func="$2"
	shift 2
	echo "== $heading"
	"$func" "$@"
	local rc=$?
	echo ""
	return $rc
}

init() {
	local action="${1-usage}"
	local copy=""

	if [ "$action" = "usage" ]; then
		cat <<EOF
init - Register everything prel shares with a repository, in one go

Usage:
  prel init usage             Show this help
  prel init register          Register the hooks, the skill and the memories
  prel init register --copy   Install the skill as a copy instead of a symlink
  prel init unregister        Remove the hooks and the memories from this repo
  prel init status            Show the state of all three, and what the next
                              commit would file

Description:
  prel shares three things with a repository, each with a command of its own:
  the hooks that file the completed work plans ('prel hooks'), the skill that
  is the format they read ('prel skills'), and the memories that make a
  session produce something to file ('prel memory').

  All three are needed before 'prel issue-from-plans' does anything, and
  missing one leaves the feature silently inert - a repository with no
  memories grows no plans, so there is never a sum-up to file. This registers
  them together, so there is one command to run in a new repository and one
  to ask afterwards.

  register is safe to run again: each step reports what was already in place,
  and leaves alone any local file of the same name that is not prel's.

  unregister removes only what belongs to this repository: the hooks and the
  memories. The skill lives in the user's skills directory and is shared by
  every repository, so it is kept - remove it with 'prel skills unregister'.

  status adds the report of 'prel issue-from-plans status' to the three, so
  one command answers whether a commit here would file an issue, and why not.
EOF
		return 0
	fi

	shift 2>/dev/null || true
	while [ $# -gt 0 ]; do
		case "$1" in
			--copy) copy="--copy" ;;
			*) echo "Error: Unknown option '$1' for init" >&2; return 1 ;;
		esac
		shift
	done

	case "$action" in
		register|unregister|status) ;;
		*)
			echo "Error: Unknown action '$action' for init" >&2
			echo "Try: prel init usage" >&2
			return 1
			;;
	esac

	local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$REPO_ROOT"

	# Every step runs even when an earlier one failed: a half-registered
	# repository is the thing this command exists to make visible, so the
	# report has to be complete before the exit status says so.
	local -a failed=()

	_init_step "hooks" init_authored_hooks "$action" || failed+=("prel hooks $action")

	case "$action" in
		register)
			_init_step "skill" init_skills register $copy || failed+=("prel skills register")
			;;
		status)
			_init_step "skill" init_skills status || failed+=("prel skills status")
			;;
		unregister)
			# Shared user-wide, so not this repository's to remove.
			echo "== skill"
			echo "Kept: the skill is shared by every repository"
			echo "      remove it with 'prel skills unregister'"
			echo ""
			;;
	esac

	_init_step "memories" init_memory "$action" || failed+=("prel memory $action")

	if [ "$action" = "status" ]; then
		_init_step "what the next commit would file" issue_from_plans status \
			|| failed+=("prel issues status")
	fi

	if [ ${#failed[@]} -gt 0 ]; then
		local step
		echo "prel init: these steps reported a problem, read their output above:" >&2
		for step in "${failed[@]}"; do
			echo "  - $step" >&2
		done
		return 1
	fi

	case "$action" in
		register)
			echo "prel init: hooks, skill and memories registered for $REPO_ROOT"
			echo "           'prel init status' says what a commit here would file"
			;;
		unregister)
			echo "prel init: hooks and memories removed for $REPO_ROOT"
			;;
	esac

	return 0
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	# Sourced from prel.sh the commands init drives are already loaded; run
	# directly, it has to load them itself. Each script guards its own
	# direct-run block, so sourcing them only defines their functions.
	_init_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	for _init_sibling in "$_init_dir"/*.sh; do
		[ "$_init_sibling" = "$_init_dir/init.sh" ] && continue
		[ -r "$_init_sibling" ] || continue
		# shellcheck source=/dev/null
		source "$_init_sibling"
	done
	init "$@"
fi
