#!/usr/bin/env bash
# init-memory.sh - Share prel's Claude Code memories with a repository
#
# Can be run directly or sourced from prel.sh
# Usage: prel init-memory [usage|register|unregister|status]
#        OR: ./scripts/init-memory.sh [usage|register|unregister|status]
# Shortcut: prel memory [usage|register|unregister|status]

# Shortcut function - memory is an alias for init_memory
memory() {
	init_memory "$@"
}

_mem_begin_marker="<!-- prel:memory -->"
_mem_end_marker="<!-- /prel:memory -->"

# Claude Code keeps a project's memories under the project path with every
# slash turned into a dash.
_mem_project_memory_dir() {
	local root="$1" slug
	slug=$(printf '%s' "$root" | tr '/' '-')
	printf '%s/projects/%s/memory\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" "$slug"
}

_mem_shared_files() {
	local file
	for file in "$1"/*.md; do
		[ -f "$file" ] || continue
		[ "$(basename "$file")" = "INDEX.md" ] && continue
		printf '%s\n' "$file"
	done
}

# Rewrite MEMORY.md with prel's pointer lines in a block of their own, dropping
# any earlier copy of them so the command can be run again safely.
_mem_write_index() {
	local mem_dir="$1" source_dir="$2" keep="$3"
	local index="$source_dir/INDEX.md" memory_md="$mem_dir/MEMORY.md"
	local tmp file

	tmp=$(mktemp) || return 1
	if [ -f "$memory_md" ]; then
		# What the project wrote for itself: everything that is neither prel's
		# block - \%...% addresses, the end marker has a slash in it - nor a
		# stale pointer line to a memory prel now ships.
		local -a drop=()
		while IFS= read -r file; do
			drop+=(-e "]($(basename "$file"))")
		done < <(_mem_shared_files "$source_dir")
		[ ${#drop[@]} -gt 0 ] || drop=(-e $'\001no-such-line')

		# grep answering 'no lines left' is not a failure here - a project whose
		# memories are all prel's has nothing of its own to keep. sed failing
		# is, and would otherwise silently drop the lines it was meant to keep.
		local kept
		kept=$(sed -e "\%$_mem_begin_marker%,\%$_mem_end_marker%d" "$memory_md" \
			| grep -F -v "${drop[@]}"; exit "${PIPESTATUS[0]}")
		if [ $? -ne 0 ]; then
			echo "Error: could not read $memory_md, leaving it as it is" >&2
			rm -f "$tmp"
			return 1
		fi

		[ -n "${kept//[[:space:]]/}" ] && printf '%s\n' "$kept" > "$tmp"
	fi

	if [ "$keep" = "1" ]; then
		[ -s "$tmp" ] && printf '\n' >> "$tmp"
		printf '%s\n' "$_mem_begin_marker" >> "$tmp"
		cat "$index" >> "$tmp"
		printf '%s\n' "$_mem_end_marker" >> "$tmp"
	fi

	if [ -s "$tmp" ]; then
		mv "$tmp" "$memory_md"
	else
		rm -f "$tmp" "$memory_md"
	fi
}

init_memory() {
	local action="${1-usage}"

	if [ "$action" = "usage" ]; then
		cat <<EOF
init-memory - Share prel's Claude Code memories with a repository

Usage:
  prel init-memory usage           Show this help
  prel init-memory register        Link prel's memories into this project
  prel init-memory unregister      Remove them from this project
  prel init-memory status          Show which ones are linked

Description:
  Claude Code keeps its memories per project, under
  \$CLAUDE_CONFIG_DIR/projects/<the repo path with dashes>/memory. A
  convention shared by several repositories would have to be written there
  once per repository, and would then drift.

  This links the memories shipped in prel/memory into the current
  repository's memory directory and splices their index lines into its
  MEMORY.md, between the markers prel owns. The memories themselves stay in
  the prel checkout: that is where they are edited, and every registered
  repository sees the edit.

  Memories that belong to one repository alone - its build, its stack - stay
  where they are: MEMORY.md keeps its own lines, prel only ever rewrites its
  own block.

  Memories shipped today:
    write-plan-before-coding   Write the steps to docs/plans/plan.md first,
                               mark it complete, sum it up, archive it.
    resume-from-plan-file      On "continue where you left off", read the
                               newest plan in docs/plans/ before anything else.

  Both are the convention 'prel issue-from-plans' and the plan-summary skill
  are built around, so a repository using those wants them.
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

	local source_dir="$PREL_DIR/memory"
	if [ ! -d "$source_dir" ]; then
		echo "Error: No memory directory found in prel project ($source_dir)" >&2
		return 1
	fi

	local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi

	local mem_dir
	mem_dir=$(_mem_project_memory_dir "$REPO_ROOT")

	local file name target rc=0
	case "$action" in
		register)
			mkdir -p "$mem_dir" || return 1
			while IFS= read -r file; do
				name=$(basename "$file")
				target="$mem_dir/$name"

				if [ -L "$target" ]; then
					if [ "$(readlink -f "$target")" = "$file" ]; then
						echo "Already registered: $name"
					else
						echo "Error: $target already links elsewhere, left alone" >&2
						rc=1
						continue
					fi
				elif [ -e "$target" ]; then
					# A copy of this memory predating prel: adopt it when it
					# says the same thing, keep hands off when it does not.
					if cmp -s "$target" "$file"; then
						rm -f "$target" && ln -s "$file" "$target" \
							&& echo "Adopted identical local copy: $name"
					else
						echo "Error: $target differs from prel's $name, left alone" >&2
						echo "       Merge it into $file by hand, then register again." >&2
						rc=1
						continue
					fi
				else
					if ln -s "$file" "$target"; then
						echo "Registered memory: $name"
					else
						echo "Error: could not link $name into $mem_dir" >&2
						rc=1
					fi
				fi
			done < <(_mem_shared_files "$source_dir")

			if _mem_write_index "$mem_dir" "$source_dir" 1; then
				echo "Indexed them in $mem_dir/MEMORY.md"
			else
				rc=1
			fi

			# A memory prel could not place is the silent half-registration
			# 'prel init' is there to surface, so it has to be an exit status
			# too and not only a line on stderr.
			return $rc
			;;
		unregister)
			while IFS= read -r file; do
				name=$(basename "$file")
				target="$mem_dir/$name"
				if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$file" ]; then
					rm -f "$target"
					echo "Unregistered memory: $name"
				elif [ -e "$target" ]; then
					echo "Left alone: $target is not a link to prel's $name"
				else
					echo "Not registered: $name"
				fi
			done < <(_mem_shared_files "$source_dir")

			_mem_write_index "$mem_dir" "$source_dir" 0
			echo "Removed prel's block from $mem_dir/MEMORY.md"
			;;
		status)
			echo "repository:       $REPO_ROOT"
			echo "memory directory: $mem_dir"
			if [ ! -d "$mem_dir" ]; then
				echo "                  (does not exist yet)"
			fi
			while IFS= read -r file; do
				name=$(basename "$file")
				target="$mem_dir/$name"
				if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$file" ]; then
					echo "  $name: registered"
				elif [ -e "$target" ]; then
					echo "  $name: a local file of that name exists, not prel's link"
				else
					echo "  $name: not registered"
				fi
			done < <(_mem_shared_files "$source_dir")
			if [ -f "$mem_dir/MEMORY.md" ] && grep -qF "$_mem_begin_marker" "$mem_dir/MEMORY.md"; then
				echo "  MEMORY.md: carries prel's block"
			else
				echo "  MEMORY.md: no prel block"
			fi
			;;
		*)
			echo "Error: Unknown action '$action' for init-memory" >&2
			echo "Try: prel init-memory usage" >&2
			return 1
			;;
	esac
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	init_memory "$@"
fi
