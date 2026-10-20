#!/usr/bin/env bash
# exclude-from-git.sh - Rewrite history to drop files that should never have been committed
#
# Can be run directly or sourced from prel.sh
# Usage: prel exclude-from-git [usage|<path>... [options]]
#        OR: ./scripts/exclude-from-git.sh [usage|<path>... [options]]
# Shortcut: prel exclude [usage|<path>... [options]]

# Shortcut function - exclude is an alias for exclude_from_git
exclude() {
	exclude_from_git "$@"
}

# The exact message bytes of a commit: everything after the first blank line of
# the raw object. Taking %B instead would append a newline and shift the hash
# of commits this command is supposed to leave alone.
_exclude_from_git_message() {
	git cat-file commit "$1" | sed -e '1,/^$/d'
}

exclude_from_git() {
	local -a paths=()
	local dry_run=0 keep_empty=0 keep_index=0 count=""

	if [ "${1-usage}" = "usage" ]; then
		cat <<EOF
exclude-from-git - Rewrite history to drop files that should never have been committed

Usage:
  prel exclude-from-git usage              Show this help
  prel exclude-from-git <path>...          Drop <path>... from the whole history
  prel exclude-from-git <path>... -n       Show what would change, rewrite nothing
  prel exclude-from-git <path>... --last N Only rewrite the last N commits
  prel exclude-from-git <path>... --keep-empty
                                           Keep commits left with nothing in them
  prel exclude-from-git <path>... --keep-index
                                           Leave the index alone

Description:
  Replays the history of the current branch without the given paths, for when a
  file was committed that should not have been. Each path is a git pathspec, so
  a directory or a glob drops everything under or matching it:

    prel exclude-from-git secrets.env build/ '*.log'

  Paths are read relative to the directory the command is called from, like any
  other git command.

  Author identity, committer identity, author date and commit date are all kept
  as they are, and so is every commit message: only the trees change. The
  prepare-commit-msg hook of 'prel switch-author' is deliberately not run, so no
  Co-Authored-By trailer is added or removed here - use 'prel recommit-last' for
  that. Commits the paths never appeared in keep their original hash.

  With --last N only the last N commits are replayed, so the paths stay in the
  history before them and the first replayed commit is left deleting them.

  A commit left with nothing in it is dropped, unless --keep-empty is given;
  commits that were already empty are kept either way. Merge commits are never
  dropped.

  The files stay on disk: they are only removed from history and, unless
  --keep-index is given, from the index, so the next commit does not add them
  straight back. Add them to .gitignore afterwards to be sure.

  Rewritten commits get new hashes; the previous HEAD is printed and kept in the
  reflog so the rewrite can be undone. A branch that was already pushed needs a
  force push, and other clones keep the old commits. Commit signatures do not
  survive the rewrite.
EOF
		return 0
	fi

	while [ $# -gt 0 ]; do
		case "$1" in
		--dry-run | -n)
			dry_run=1
			;;
		--keep-empty)
			keep_empty=1
			;;
		--keep-index)
			keep_index=1
			;;
		--last)
			shift
			if [ $# -eq 0 ]; then
				echo "Error: --last needs a commit count" >&2
				echo "Try: prel exclude-from-git usage" >&2
				return 1
			fi
			count="$1"
			;;
		--last=*)
			count="${1#--last=}"
			;;
		--)
			shift
			while [ $# -gt 0 ]; do
				paths+=("$1")
				shift
			done
			break
			;;
		-*)
			echo "Error: Unknown option '$1' for exclude-from-git" >&2
			echo "Try: prel exclude-from-git usage" >&2
			return 1
			;;
		*)
			paths+=("$1")
			;;
		esac
		shift
	done

	if [ "${#paths[@]}" -eq 0 ]; then
		echo "Error: No path to exclude" >&2
		echo "Try: prel exclude-from-git usage" >&2
		return 1
	fi

	if [ -n "$count" ] && ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
		echo "Error: '$count' is not a commit count" >&2
		echo "Try: prel exclude-from-git usage" >&2
		return 1
	fi

	local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"

	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi

	# Paths are read relative to the directory prel was called from, the way
	# every git command reads them, but the rewrite itself runs from the root.
	# prel.sh has already moved there, hence PREL_PWD.
	local prefix
	prefix=$(git -C "${PREL_PWD:-$PWD}" rev-parse --show-prefix 2>/dev/null || true)

	cd "$REPO_ROOT"

	if [ -n "$prefix" ]; then
		local -a rebased=()
		local path
		for path in "${paths[@]}"; do
			case "$path" in
			:* | /*) rebased+=("$path") ;;
			*) rebased+=("$prefix$path") ;;
			esac
		done
		paths=("${rebased[@]}")
	fi

	# Catch a pathspec git will not take at all - one pointing outside the
	# repository, say - instead of reporting it as a path history never had.
	local pathspec_error
	if ! pathspec_error=$(git ls-files --cached -- "${paths[@]}" 2>&1 >/dev/null); then
		echo "Error: ${pathspec_error#fatal: }" >&2
		return 1
	fi

	local old_head
	old_head=$(git rev-parse --verify HEAD 2>/dev/null) || {
		echo "Error: No commit to rewrite yet" >&2
		return 1
	}

	local branch
	branch=$(git rev-parse --abbrev-ref HEAD)

	local total
	total=$(git rev-list --count HEAD)
	if [ -n "$count" ] && [ "$count" -gt "$total" ]; then
		echo "Error: Only $total commit(s) on HEAD, cannot rewrite $count" >&2
		return 1
	fi

	local -a range=()
	if [ -n "$count" ]; then
		mapfile -t range < <(git rev-list --reverse --topo-order -n "$count" HEAD)
	else
		mapfile -t range < <(git rev-list --reverse --topo-order HEAD)
	fi

	echo "excluding: ${paths[*]}"
	echo "rewriting: ${#range[@]} commit(s) of $branch"
	echo ""

	local tmpdir
	tmpdir=$(mktemp -d) || return 1
	local index_file="$tmpdir/index"
	local msg_file="$tmpdir/msg"

	# Old hash -> new hash, so that each commit is rebuilt onto the rewrite of
	# its parent. Parents outside the range are kept as they are, and a commit
	# the paths never touched keeps its own hash.
	local -A rewritten=()
	local sha new_sha tree new_tree parents parent first_parent new_first_parent parent_tree
	local author_name author_email author_date committer_name committer_email commit_date
	local changed=0 dropped=0 touched=0
	local -a parent_args=()
	local -a matched=()

	for sha in "${range[@]}"; do
		tree=$(git rev-parse "$sha^{tree}")
		parents=$(git rev-list --parents -n 1 "$sha" | cut -s -d' ' -f2-)
		first_parent=""
		parent_args=()
		for parent in $parents; do
			[ -n "$first_parent" ] || first_parent="$parent"
			if [ -n "${rewritten[$parent]-}" ]; then
				parent_args+=(-p "${rewritten[$parent]}")
			else
				parent_args+=(-p "$parent")
			fi
		done
		new_first_parent=""
		if [ -n "$first_parent" ]; then
			new_first_parent="${rewritten[$first_parent]-$first_parent}"
		fi

		# The matching is done against an index of its own rather than with
		# 'git ls-tree -- <path>', whose pathspecs are plain prefixes: a glob
		# would quietly match nothing there.
		rm -f "$index_file"
		GIT_INDEX_FILE="$index_file" git read-tree "$sha" || {
			echo "Error: Failed to read the tree of $sha" >&2
			rm -rf "$tmpdir"
			return 1
		}
		mapfile -d '' -t matched < <(GIT_INDEX_FILE="$index_file" git ls-files -z --cached -- "${paths[@]}")

		# Nothing to drop and every parent untouched: the commit is already the
		# commit it should be, hash included.
		if [ "${#matched[@]}" -eq 0 ] && [ "$changed" -eq 0 ]; then
			rewritten[$sha]="$sha"
			continue
		fi

		if [ "${#matched[@]}" -eq 0 ]; then
			new_tree="$tree"
		else
			touched=$((touched + 1))
			printf '%s\0' "${matched[@]}" |
				GIT_INDEX_FILE="$index_file" git update-index -z --force-remove --stdin || {
				echo "Error: Failed to drop the paths from $sha" >&2
				rm -rf "$tmpdir"
				return 1
			}
			new_tree=$(GIT_INDEX_FILE="$index_file" git write-tree) || {
				echo "Error: Failed to write the tree of $sha" >&2
				rm -rf "$tmpdir"
				return 1
			}
		fi

		# A commit that said something before and says nothing now is an
		# artefact of the exclusion, so it goes. A commit that was already
		# empty was meant to be, and a merge is kept whatever its tree.
		if [ "$keep_empty" -eq 0 ] && [ -n "$new_first_parent" ] && [ "${#parent_args[@]}" -eq 2 ]; then
			parent_tree=$(git rev-parse "$first_parent^{tree}")
			if [ "$new_tree" = "$(git rev-parse "$new_first_parent^{tree}")" ] && [ "$tree" != "$parent_tree" ]; then
				echo "  $(git rev-parse --short "$sha") -> dropped (empty)  $(_exclude_from_git_message "$sha" | head -1)"
				rewritten[$sha]="$new_first_parent"
				changed=1
				dropped=$((dropped + 1))
				continue
			fi
		fi

		IFS=$'\x1f' read -r author_name author_email author_date committer_name committer_email commit_date \
			< <(git log -1 --format='%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI' "$sha")

		_exclude_from_git_message "$sha" >"$msg_file"

		if [ "$dry_run" -eq 1 ]; then
			echo "  $(git rev-parse --short "$sha")  $(head -1 "$msg_file")"
			[ "${#matched[@]}" -eq 0 ] || printf '           drops: %s\n' "${matched[@]}"
			# Pretend the rewrite happened, so the commits after this one are
			# reported the way they would really be.
			rewritten[$sha]="$sha"
			[ "${#matched[@]}" -eq 0 ] || changed=1
			continue
		fi

		new_sha=$(GIT_AUTHOR_NAME="$author_name" \
			GIT_AUTHOR_EMAIL="$author_email" \
			GIT_AUTHOR_DATE="$author_date" \
			GIT_COMMITTER_NAME="$committer_name" \
			GIT_COMMITTER_EMAIL="$committer_email" \
			GIT_COMMITTER_DATE="$commit_date" \
			git commit-tree "$new_tree" "${parent_args[@]}" <"$msg_file") || {
			echo "Error: Failed to rewrite $sha" >&2
			rm -rf "$tmpdir"
			return 1
		}

		echo "  $(git rev-parse --short "$sha") -> $(git rev-parse --short "$new_sha")  $(head -1 "$msg_file")"
		[ "${#matched[@]}" -eq 0 ] || printf '           drops: %s\n' "${matched[@]}"
		rewritten[$sha]="$new_sha"
		changed=1
	done

	rm -rf "$tmpdir"

	if [ "$touched" -eq 0 ]; then
		echo "None of the given paths is in the history of $branch, nothing to rewrite"
		return 0
	fi

	if [ "$dry_run" -eq 1 ]; then
		echo ""
		echo "Dry run: nothing rewritten"
		return 0
	fi

	local new_head="${rewritten[${range[-1]}]}"

	if [ "$new_head" = "$old_head" ]; then
		echo ""
		echo "Nothing to rewrite"
		return 0
	fi

	git update-ref -m "prel exclude-from-git ${paths[*]}" HEAD "$new_head" "$old_head" || {
		echo "Error: Failed to move HEAD to $new_head" >&2
		return 1
	}

	echo ""
	echo "Rewrote ${#range[@]} commit(s), HEAD is now $(git rev-parse --short HEAD)"
	[ "$dropped" -eq 0 ] || echo "Dropped $dropped empty commit(s)"

	# Without this the paths are still in the index, so the very next commit
	# would add back what was just taken out of the history.
	if [ "$keep_index" -eq 0 ]; then
		local -a staged=()
		mapfile -d '' -t staged < <(git ls-files -z --cached -- "${paths[@]}")
		if [ "${#staged[@]}" -gt 0 ]; then
			git rm --cached --quiet --ignore-unmatch -- "${staged[@]}" || true
			echo "Removed from the index (kept on disk): ${staged[*]}"
		fi
	fi

	echo "Previous HEAD: $old_head"
	echo "To undo: git update-ref HEAD $old_head"
	echo "To really drop the old objects: git reflog expire --expire=now --all && git gc --prune=now"

	local upstream
	upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
	if [ -n "$upstream" ] && [ "$(git rev-list --count "$upstream" "^$new_head")" -gt 0 ]; then
		echo "Note: $upstream still holds the old commits, it needs a force push"
	fi
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	exclude_from_git "$@"
fi
