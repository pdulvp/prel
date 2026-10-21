#!/usr/bin/env bash
# prel.sh - Main entrypoint for prel project
#
# Loads all command scripts from the scripts/ directory and routes commands.
#
# Usage:
#   prel <command> [action]     Execute a command with optional action
#   prel usage                 Show all available commands and their usage

# Get the directory where this script is located (prel project root). The
# symlink is resolved first: installed as a package, /usr/bin/prel points at
# /usr/share/prel/prel.sh, and BASH_SOURCE holds the path prel was invoked as
# rather than the one it lives at. A no-op in a clone.
PREL_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Export PREL_DIR so sub-scripts can use it
export PREL_DIR

# Get the current git repository root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""

# If not in a git repo, error out (unless showing usage or listing commands)
if [ -z "$REPO_ROOT" ] && [ "${1-}" != "usage" ] && [ -n "${1-}" ]; then
	echo "Error: Not in a git repository" >&2
	exit 1
fi

# Remember where prel was called from, before moving to the repo root: a command
# taking paths needs it to read them relative to the caller's directory, the way
# every git command does.
PREL_PWD="$PWD"
export PREL_PWD

# Change to repo root if we're in one
if [ -n "$REPO_ROOT" ]; then
	cd "$REPO_ROOT"
fi

# Load all command scripts from scripts/ directory
SCRIPTS_DIR="$PREL_DIR/scripts"
if [ -d "$SCRIPTS_DIR" ]; then
	for script_file in "$SCRIPTS_DIR"/*.sh; do
		if [ -f "$script_file" ]; then
			# Source the script to load its functions
			source "$script_file"
		fi
	done
fi

# Display usage for all commands
show_all_usage() {
	cat <<EOF
prel - Git management toolkit

Available commands:
EOF
	
	# For each script, call its function with "usage" argument
	for script_file in "$SCRIPTS_DIR"/*.sh; do
		if [ -f "$script_file" ]; then
			# Extract function name from filename (replace - with _)
			func_name=$(basename "$script_file" .sh | tr '-' '_')
			# Call the function with usage argument
			echo ""
			$func_name usage 2>/dev/null || true
		fi
	done
	
	cat <<EOF

Global options:
  prel usage              Show this help message
  prel <command> usage    Show help for a specific command
EOF
}

# Display brief command list
show_command_list() {
	cat <<EOF
Usage: prel <command> [action]

Available commands:
EOF
	
	for script_file in "$SCRIPTS_DIR"/*.sh; do
		if [ -f "$script_file" ]; then
			func_name=$(basename "$script_file" .sh | tr '-' '_')
			# Get first line of usage from the function
			first_line=$($func_name usage 2>/dev/null | head -1 || echo "  $func_name")
			echo "  $first_line"
		fi
	done
	
	cat <<EOF

Type 'prel usage' for detailed help on all commands.
Type 'prel <command> usage' for help on a specific command.
EOF
}

# Main command dispatch
if [ -z "${1-}" ] || [ "${1-}" = "help" ]; then
	show_command_list
	exit 0
fi

if [ "${1-}" = "usage" ]; then
	show_all_usage
	exit 0
fi

# If not in a git repo, show error
if [ -z "$REPO_ROOT" ]; then
	echo "Error: Not in a git repository" >&2
	exit 1
fi

# Convert command name to function name (replace - with _)
CMD="$1"
FUNC_NAME=$(echo "$CMD" | tr '-' '_')

# Check if the function exists
if ! command -v "$FUNC_NAME" >/dev/null 2>&1; then
	echo "Error: Unknown command '$CMD'" >&2
	echo ""
	show_command_list
	exit 1
fi

# Call the function with remaining arguments
shift
$FUNC_NAME "$@"
