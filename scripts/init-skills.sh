#!/usr/bin/env bash
# init-skills.sh - Make the prel agent skills available to Claude Code
#
# Can be run directly or sourced from prel.sh
# Usage: prel init-skills [usage|register|unregister|status] [--copy]
#        OR: ./scripts/init-skills.sh [usage|register|unregister|status]
# Shortcut: prel skills [usage|register|unregister|status]

# Shortcut function - skills is an alias for init_skills
skills() {
	init_skills "$@"
}

_skills_home() {
	printf '%s/skills\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

init_skills() {
	local action="${1-usage}"
	local mode="symlink"

	if [ "$action" = "usage" ]; then
		cat <<EOF
init-skills - Make the prel agent skills available to Claude Code

Usage:
  prel init-skills usage           Show this help
  prel init-skills register        Install prel's skills for Claude Code
  prel init-skills register --copy Install them as copies instead of symlinks
  prel init-skills unregister      Remove them
  prel init-skills status          Show which ones are installed

Description:
  Links the skills shipped in prel/skills into the user skills directory
  (\$CLAUDE_CONFIG_DIR/skills, ~/.claude/skills by default), so every project
  loads them, the way 'prel init-authored-hooks register' shares the hooks.

  A symlink means an edit in the prel checkout takes effect at once. Use
  --copy where symlinks are not picked up.

  Skills shipped today:
    plan-summary   The format of docs/plans/sumup.md, which
                   'prel issue-from-plans' turns into a GitHub issue and a
                   commit subject on the next commit.
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

	local source_dir="$PREL_DIR/skills"
	if [ ! -d "$source_dir" ]; then
		echo "Error: No skills directory found in prel project ($source_dir)" >&2
		return 1
	fi

	shift 2>/dev/null || true
	while [ $# -gt 0 ]; do
		case "$1" in
			--copy) mode="copy" ;;
			*) echo "Error: Unknown option '$1' for init-skills" >&2; return 1 ;;
		esac
		shift
	done

	local skills_home
	skills_home=$(_skills_home)

	local skill_dir name target rc=0
	case "$action" in
		register)
			mkdir -p "$skills_home" || return 1
			for skill_dir in "$source_dir"/*/; do
				[ -f "$skill_dir/SKILL.md" ] || continue
				skill_dir=${skill_dir%/}
				name=$(basename "$skill_dir")
				target="$skills_home/$name"

				if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$skill_dir" ]; then
					echo "Skill already registered: $name -> $target"
					continue
				fi
				if [ -e "$target" ]; then
					echo "Error: $target already exists and is not prel's $name skill" >&2
					echo "       Remove it first, or keep yours and skip prel's." >&2
					rc=1
					continue
				fi

				if [ "$mode" = "copy" ]; then
					cp -r "$skill_dir" "$target" || { rc=1; continue; }
				else
					ln -s "$skill_dir" "$target" || { rc=1; continue; }
				fi

				if [ -r "$target/SKILL.md" ]; then
					echo "Registered skill: $name -> $target"
				else
					echo "Error: $target/SKILL.md is not readable, skill will not load" >&2
					rc=1
				fi
			done

			# A skill prel could not place would leave the hooks reading a
			# format nothing writes, so say so with the exit status.
			return $rc
			;;
		unregister)
			for skill_dir in "$source_dir"/*/; do
				skill_dir=${skill_dir%/}
				name=$(basename "$skill_dir")
				target="$skills_home/$name"

				if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$skill_dir" ]; then
					rm -f "$target"
					echo "Unregistered skill: $name"
				elif [ -e "$target" ]; then
					echo "Left alone: $target is not a link to prel's $name skill"
				else
					echo "Not registered: $name"
				fi
			done
			;;
		status)
			echo "skills directory: $skills_home"
			for skill_dir in "$source_dir"/*/; do
				[ -f "$skill_dir/SKILL.md" ] || continue
				skill_dir=${skill_dir%/}
				name=$(basename "$skill_dir")
				target="$skills_home/$name"

				if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$skill_dir" ]; then
					echo "  $name: registered (symlink)"
				elif [ -d "$target" ]; then
					echo "  $name: a directory of that name exists, not prel's link"
				else
					echo "  $name: not registered"
				fi
			done
			;;
		*)
			echo "Error: Unknown action '$action' for init-skills" >&2
			echo "Try: prel init-skills usage" >&2
			return 1
			;;
	esac
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	init_skills "$@"
fi
