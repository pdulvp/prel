#!/usr/bin/env bash
# init-authored-hooks.sh - Initialize git hooks from prel/.githooks
#
# Can be run directly or sourced from prel.sh
# Usage: prel init-authored-hooks [usage|register|unregister]
#        OR: ./scripts/init-authored-hooks.sh [usage|register|unregister]
# Shortcut: prel hooks [usage|register|unregister]

# Shortcut function - hooks is an alias for init_authored_hooks
hooks() {
	init_authored_hooks "$@"
}

init_authored_hooks() {
	local action="${1-usage}"
	
	# If just showing usage, don't need a git repo
	if [ "$action" = "usage" ]; then
		cat <<EOF
init-authored-hooks - Initialize git hooks from prel/.githooks

Usage:
  prel init-authored-hooks usage          Show this help
  prel init-authored-hooks register       Set core.hooksPath to prel/.githooks
  prel init-authored-hooks unregister     Remove core.hooksPath setting
  prel init-authored-hooks status         Show whether they are registered

Description:
  Registers the prel hooks directory with the current git repository.
  The hooks are stored in the prel project and will be used for all commits.

  Registering also sets commit.cleanup to scissors, which is what lets a
  commit subject start with the '#12' of the issue 'prel issue-from-plans'
  files: git cleans the message up after the hooks have run, and its default
  mode drops every line starting with the comment character. Under scissors
  only what sits below the scissors line is dropped, so the help text still
  goes and the subject stays. Unregistering puts the setting back.
EOF
		return 0
	fi
	
	# Determine PREL_DIR - use exported var if available, otherwise calculate from script location
	local PREL_DIR="${PREL_DIR:-}"
	if [ -z "$PREL_DIR" ]; then
		local SCRIPT_DIR
		SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		PREL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
	fi
	
	local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
	
	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	
	cd "$REPO_ROOT"
	
	local source_dir="$PREL_DIR/.githooks"
	
	case "$action" in
		register)
			# Check if prel .githooks exist
			if [ ! -d "$source_dir" ]; then
				echo "Error: No .githooks directory found in prel project ($source_dir)" >&2
				return 1
			fi
			
			# Set core.hooksPath to the prel .githooks directory
			if [ "$(git config --get core.hooksPath 2>/dev/null)" != "$source_dir" ]; then
				git config --local core.hooksPath "$source_dir"
				echo "Registered hooks from: $source_dir"
			else
				echo "Hooks already registered from: $source_dir"
			fi

			# Keep a '#12' subject out of git's comment stripping - see usage.
			if [ "$(git config --get commit.cleanup 2>/dev/null)" != "scissors" ]; then
				git config --local commit.cleanup scissors
				echo "Set commit.cleanup=scissors (so an issue number can lead the subject)"
			fi
			;;
		unregister)
			local current_hooks=$(git config --get core.hooksPath 2>/dev/null || true)
			if [ -n "$current_hooks" ]; then
				git config --local --unset core.hooksPath
				echo "Unregistered hooks (was: $current_hooks)"
			else
				echo "No hooks currently registered"
			fi

			if [ "$(git config --local --get commit.cleanup 2>/dev/null)" = "scissors" ]; then
				git config --local --unset commit.cleanup
				echo "Unset commit.cleanup (was: scissors)"
			fi
			;;
		status)
			local current cleanup hook
			current=$(git config --get core.hooksPath 2>/dev/null || true)

			echo "hooks directory: $source_dir"
			if [ "$current" = "$source_dir" ]; then
				echo "  core.hooksPath: registered"
			elif [ -n "$current" ]; then
				echo "  core.hooksPath: $current, not prel's hooks"
			else
				echo "  core.hooksPath: not registered"
			fi

			# A hook git cannot execute is skipped in silence, which looks
			# exactly like a hook that decided to do nothing.
			for hook in "$source_dir"/*; do
				[ -f "$hook" ] || continue
				if [ -x "$hook" ]; then
					echo "  $(basename "$hook"): executable"
				else
					echo "  $(basename "$hook"): not executable, git will skip it"
				fi
			done

			# What git will do to a '#12' subject once the hooks have run.
			cleanup=$(git config --get commit.cleanup 2>/dev/null || true)
			case "$cleanup" in
				scissors)
					echo "  commit.cleanup: scissors, an issue number can lead the subject"
					;;
				whitespace|verbatim)
					echo "  commit.cleanup: $cleanup, which also keeps a '#number' subject"
					;;
				*)
					echo "  commit.cleanup: ${cleanup:-unset}, which drops a '#number' subject"
					echo "                  run 'prel init-authored-hooks register' to set it to scissors"
					;;
			esac
			;;
		*)
			echo "Error: Unknown action '$action' for init-authored-hooks" >&2
			echo "Try: prel init-authored-hooks usage" >&2
			return 1
			;;
	esac
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	init_authored_hooks "$@"
fi
