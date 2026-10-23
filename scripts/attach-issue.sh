#!/usr/bin/env bash
# attach-issue.sh - File a commit already made as a GitHub issue and link it
#
# Can be run directly or sourced from prel.sh
# Usage: prel attach-issue [usage|<commit>...|--all [options]]
#        OR: ./scripts/attach-issue.sh [usage|<commit>...|--all [options]]
# Shortcut: prel attach [usage|<commit>...|--all [options]]
#
# 'prel issue-from-plans' files an issue at commit time, out of the work plans.
# This is the other way round: a commit already made, with a message worth
# keeping and no issue behind it. The message becomes the issue - subject as
# title, the rest as body - and the commit is replayed with '#<n> ' in front of
# its subject.

# Shortcut function - attach is an alias for attach_issue
attach() {
	attach_issue "$@"
}

# The trailers that say who made the commit rather than what it does. The
# commit itself records all of that, so they are dropped from the issue body;
# the commit message keeps them.
_AI_DROP_TRAILERS="author committer co-authored-by signed-off-by change-id \
reviewed-by acked-by tested-by reported-by suggested-by helped-by cc"

# The exact message bytes of a commit: everything after the first blank line of
# the raw object. Taking %B instead would append a newline and shift the hash
# of the commits this command is supposed to leave alone.
_ai_message() {
	git cat-file commit "$1" | sed -e '1,/^$/d'
}

_ai_subject() {
	_ai_message "$1" | head -1
}

# Strip the leading and trailing blank lines of a block of markdown.
_ai_trim_blank() {
	awk '{ line[NR] = $0 }
	     END {
	       s = 1; while (s <= NR && line[s] ~ /^[[:space:]]*$/) s++
	       e = NR; while (e >= s && line[e] ~ /^[[:space:]]*$/) e--
	       for (i = s; i <= e; i++) print line[i]
	     }'
}

# The message without its subject and without the identity trailers: the body
# of the issue.
_ai_body() {
	_ai_message "$1" | awk -v keys="$_AI_DROP_TRAILERS" '
		BEGIN { n = split(keys, k, /[[:space:]]+/); for (i = 1; i <= n; i++) drop[k[i]] }
		NR == 1 { next }
		/^[A-Za-z][A-Za-z-]*:[[:space:]]/ {
			key = tolower($0); sub(/:.*$/, "", key)
			if (key in drop) next
		}
		{ print }
	' | _ai_trim_blank
}

_ai_issue_body() {
	local body
	body=$(_ai_body "$1")
	[ -z "$body" ] || printf '%s\n\n' "$body"
	printf '<sub>Filed by prel from the commit message.</sub>\n'
}

# A subject already carrying an issue number has nothing to attach: this is what
# keeps a second run, or a commit filed by the hooks, from filing the same work
# twice.
_ai_is_prefixed() {
	[[ "$1" =~ ^#[0-9]+ ]]
}

_ai_is_merge() {
	[ "$(git rev-list --parents -n 1 "$1" | wc -w)" -gt 2 ]
}

_ai_github_remote() {
	local url
	url=$(git remote get-url --push origin 2>/dev/null) || url=""
	[ -n "$url" ] || url=$(git remote get-url --push "$(git remote | head -1)" 2>/dev/null) || url=""
	case "$url" in
	*github.com*) printf '%s\n' "$url" ;;
	*) return 1 ;;
	esac
}

# An issue filed for a rewrite that then failed. Lives in .git so it is
# per-worktree and never committed; keyed by the commit it was filed for, so a
# retry reuses it rather than filing a second one.
_ai_cache_file() {
	local git_dir
	git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
	printf '%s/prel-attached-issue\n' "$git_dir"
}

_ai_cache_get() {
	local cache
	cache=$(_ai_cache_file) || return 1
	[ -f "$cache" ] || return 1
	sed -n "s/^$1 //p" "$cache" | head -1
}

_ai_cache_put() {
	local cache
	cache=$(_ai_cache_file) || return 1
	printf '%s %s %s\n' "$1" "$2" "$3" >>"$cache"
}

_ai_cache_drop() {
	local cache tmp
	cache=$(_ai_cache_file) || return 1
	[ -f "$cache" ] || return 0
	tmp=$(mktemp) || return 1
	grep -v "^$1 " "$cache" >"$tmp" 2>/dev/null || true
	if [ -s "$tmp" ]; then
		mv "$tmp" "$cache"
	else
		rm -f "$tmp" "$cache"
	fi
}

# File the issue for one commit, or hand back the one a failed run already
# filed for it. Prints '<number> <url>'.
_ai_file_issue() {
	local sha="$1" title="$2" body_file="$3"
	local cached number url created

	if cached=$(_ai_cache_get "$sha") && [ -n "$cached" ]; then
		number="${cached%% *}"
		url="${cached#* }"
		if ! gh issue edit "$number" --title "$title" --body-file "$body_file" >/dev/null 2>&1; then
			echo "prel: could not update issue #$number, reusing it as it stands" >&2
		fi
		printf '%s %s\n' "$number" "$url"
		return 0
	fi

	if ! created=$(gh issue create --title "$title" --body-file "$body_file" 2>&1); then
		echo "Error: gh issue create failed for $(git rev-parse --short "$sha")" >&2
		printf '%s\n' "$created" | sed -e 's/^/prel: /' >&2
		return 1
	fi

	url=$(printf '%s\n' "$created" | sed -n 's#.*\(https://[^ ]*/issues/[0-9]\+\).*#\1#p' | tail -1)
	number="${url##*/}"
	if ! [[ "$number" =~ ^[0-9]+$ ]]; then
		echo "Error: could not read an issue number out of gh's answer" >&2
		printf '%s\n' "$created" | sed -e 's/^/prel: /' >&2
		return 1
	fi

	# Remembered until a commit really carries it: should the rewrite fail, the
	# next run attaches this issue instead of filing another.
	_ai_cache_put "$sha" "$number" "$url"
	printf '%s %s\n' "$number" "$url"
}

attach_issue() {
	local -a wanted=()
	local dry_run=0 all=0

	# No argument means HEAD, so only the word itself asks for the help.
	if [ "${1-}" = "usage" ] || [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then
		cat <<EOF
attach-issue - File a commit already made as a GitHub issue and link it

Usage:
  prel attach-issue usage           Show this help
  prel attach-issue                 File HEAD's message as an issue
  prel attach-issue <commit>...     File those commits, last or not
  prel attach-issue --all           File every unattached commit ahead of upstream
  prel attach-issue <commit>... -n  Show what would be filed, change nothing

Description:
  The commit message becomes the issue: its subject is the title, the rest is
  the body, with the identity trailers (Co-Authored-By:, Committer:,
  Signed-off-by: and the like) stripped - the commit records all that already.
  The commit is then replayed with the issue number in front of its subject:

    #12 A release target, and the build stamp moved behind a '~'

  This is the counterpart of 'prel issue-from-plans', which files the work
  plans as an issue at commit time. Use this one for a commit already made.

  Any commit of the branch can be attached, not only the last: the commits
  from it to HEAD are replayed onto its rewrite, the way 'prel recommit-last'
  and 'prel exclude-from-git' replay them. Author identity, committer identity,
  author date and commit date are all kept - only the message changes. Commits
  before the target keep their hash; the target and everything after it get new
  ones, the previous HEAD is printed and kept in the reflog, and a branch that
  was already pushed needs a force push. Commit signatures do not survive the
  rewrite.

  Left alone and said so: a subject already carrying an issue number, a merge
  commit, and a commit that is not an ancestor of HEAD.

  gh and a GitHub remote are required here - unlike in the commit hooks, the
  issue is the whole point. An issue filed for a rewrite that then failed is
  remembered in .git/prel-attached-issue and reused by the next run, so a
  failure leaves no orphan.
EOF
		return 0
	fi

	while [ $# -gt 0 ]; do
		case "$1" in
		--dry-run | -n)
			dry_run=1
			;;
		--all)
			all=1
			;;
		--)
			shift
			while [ $# -gt 0 ]; do
				wanted+=("$1")
				shift
			done
			break
			;;
		-*)
			echo "Error: Unknown option '$1' for attach-issue" >&2
			echo "Try: prel attach-issue usage" >&2
			return 1
			;;
		*)
			wanted+=("$1")
			;;
		esac
		shift
	done

	local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$REPO_ROOT"

	if [ "$all" -eq 1 ] && [ "${#wanted[@]}" -gt 0 ]; then
		echo "Error: --all takes no commit" >&2
		return 1
	fi

	local old_head
	old_head=$(git rev-parse --verify HEAD 2>/dev/null) || {
		echo "Error: No commit to attach yet" >&2
		return 1
	}

	# HEAD is about to be moved, so it has to be a branch's HEAD and nothing
	# half-done underneath it.
	local git_dir
	git_dir=$(git rev-parse --git-dir)
	if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ] ||
		[ -f "$git_dir/MERGE_HEAD" ] || [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then
		echo "Error: a rebase, merge or cherry-pick is in progress, finish it first" >&2
		return 1
	fi

	local branch
	branch=$(git rev-parse --abbrev-ref HEAD)
	if [ "$branch" = "HEAD" ] && [ "$dry_run" -eq 0 ]; then
		echo "Error: HEAD is detached, check out a branch first" >&2
		return 1
	fi

	if [ "$dry_run" -eq 0 ]; then
		if ! command -v gh >/dev/null 2>&1; then
			echo "Error: gh not found, no issue can be filed" >&2
			return 1
		fi
		if ! _ai_github_remote >/dev/null; then
			echo "Error: no GitHub remote, no issue can be filed" >&2
			return 1
		fi
	fi

	local upstream
	upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)

	# The commits asked for, oldest first, so the issue numbers follow the
	# history rather than the order they were typed in.
	local -a targets=()
	local sha
	if [ "$all" -eq 1 ]; then
		if [ -z "$upstream" ]; then
			echo "Error: no upstream branch, --all has nothing to go by" >&2
			echo "       name the commits instead" >&2
			return 1
		fi
		mapfile -t targets < <(git rev-list --reverse --topo-order "$upstream..HEAD")
		if [ "${#targets[@]}" -eq 0 ]; then
			echo "Nothing ahead of $upstream, no commit to attach"
			return 0
		fi
	else
		[ "${#wanted[@]}" -gt 0 ] || wanted=(HEAD)
		local want resolved
		local -a resolved_list=()
		for want in "${wanted[@]}"; do
			if ! resolved=$(git rev-parse --verify --quiet "$want^{commit}"); then
				echo "Error: '$want' is not a commit" >&2
				return 1
			fi
			if ! git merge-base --is-ancestor "$resolved" HEAD; then
				echo "Error: $(git rev-parse --short "$resolved") is not an ancestor of HEAD" >&2
				return 1
			fi
			resolved_list+=("$resolved")
		done
		# Ordered by the history and deduplicated: the same commit named twice
		# is one commit.
		mapfile -t targets < <(git rev-list --reverse --topo-order --no-walk "${resolved_list[@]}")
	fi

	# What is worth filing, and what is said about the rest. A merge carries the
	# attribution of work done elsewhere, and a subject already numbered is
	# already attached.
	local -a filing=()
	local -a skipped=()
	local subject
	for sha in "${targets[@]}"; do
		subject=$(_ai_subject "$sha")
		if _ai_is_prefixed "$subject"; then
			skipped+=("  $(git rev-parse --short "$sha")  already attached: $subject")
			continue
		fi
		if _ai_is_merge "$sha"; then
			skipped+=("  $(git rev-parse --short "$sha")  merge, left alone: $subject")
			continue
		fi
		filing+=("$sha")
	done

	if [ "${#filing[@]}" -eq 0 ]; then
		[ "${#skipped[@]}" -eq 0 ] || printf '%s\n' "${skipped[@]}"
		echo "Nothing to attach"
		return 0
	fi

	local earliest="${filing[0]}"
	if [ -n "$upstream" ] && git merge-base --is-ancestor "$earliest" "$upstream" 2>/dev/null; then
		echo "Warning: $(git rev-parse --short "$earliest") is already on $upstream," \
			"which will need a force push" >&2
	fi

	echo "attaching: ${#filing[@]} commit(s) of $branch"
	[ "${#skipped[@]}" -eq 0 ] || printf '%s\n' "${skipped[@]}"
	echo ""

	local tmpdir
	tmpdir=$(mktemp -d) || return 1
	local body_file="$tmpdir/body"
	local msg_file="$tmpdir/msg"

	# Commit -> the issue filed for it, read again by the replay below.
	local -A number_of=()
	local -A url_of=()
	local title filed number url
	for sha in "${filing[@]}"; do
		title=$(_ai_subject "$sha")
		_ai_issue_body "$sha" >"$body_file"

		if [ "${#title}" -gt 70 ]; then
			echo "prel: the subject of $(git rev-parse --short "$sha") is ${#title} chars," \
				"longer than the 70 an issue title should keep" >&2
		fi

		if [ "$dry_run" -eq 1 ]; then
			echo "--- issue for $(git rev-parse --short "$sha") ---------------------------"
			printf '%s\n\n' "$title"
			cat "$body_file"
			echo ""
			number_of[$sha]="<new>"
			continue
		fi

		if ! filed=$(_ai_file_issue "$sha" "$title" "$body_file"); then
			rm -rf "$tmpdir"
			return 1
		fi
		number="${filed%% *}"
		url="${filed#* }"
		number_of[$sha]="$number"
		url_of[$sha]="$url"
	done

	# The replay. Every commit of the branch is walked, but only a commit that
	# is a target or that descends from one is rebuilt: the ones before the
	# earliest target keep their hash.
	local -a range=()
	mapfile -t range < <(git rev-list --reverse --topo-order HEAD)

	local -A rewritten=()
	local new_sha tree parents parent changed=0
	local author_name author_email author_date committer_name committer_email commit_date
	local -a parent_args=()

	for sha in "${range[@]}"; do
		if [ -z "${number_of[$sha]-}" ] && [ "$changed" -eq 0 ]; then
			rewritten[$sha]="$sha"
			continue
		fi

		tree=$(git rev-parse "$sha^{tree}")
		parents=$(git rev-list --parents -n 1 "$sha" | cut -s -d' ' -f2-)
		parent_args=()
		for parent in $parents; do
			if [ -n "${rewritten[$parent]-}" ]; then
				parent_args+=(-p "${rewritten[$parent]}")
			else
				parent_args+=(-p "$parent")
			fi
		done

		_ai_message "$sha" >"$msg_file"
		if [ -n "${number_of[$sha]-}" ]; then
			{
				printf '#%s %s\n' "${number_of[$sha]}" "$(head -1 "$msg_file")"
				tail -n +2 "$msg_file"
			} >"$msg_file.new"
			mv "$msg_file.new" "$msg_file"
		fi

		if [ "$dry_run" -eq 1 ]; then
			echo "  $(git rev-parse --short "$sha")  $(head -1 "$msg_file")"
			rewritten[$sha]="$sha"
			changed=1
			continue
		fi

		IFS=$'\x1f' read -r author_name author_email author_date committer_name committer_email commit_date \
			< <(git log -1 --format='%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI' "$sha")

		new_sha=$(GIT_AUTHOR_NAME="$author_name" \
			GIT_AUTHOR_EMAIL="$author_email" \
			GIT_AUTHOR_DATE="$author_date" \
			GIT_COMMITTER_NAME="$committer_name" \
			GIT_COMMITTER_EMAIL="$committer_email" \
			GIT_COMMITTER_DATE="$commit_date" \
			git commit-tree "$tree" "${parent_args[@]}" <"$msg_file") || {
			echo "Error: Failed to rewrite $sha" >&2
			echo "       the issues filed are kept in .git/prel-attached-issue and reused on a retry" >&2
			rm -rf "$tmpdir"
			return 1
		}

		echo "  $(git rev-parse --short "$sha") -> $(git rev-parse --short "$new_sha")  $(head -1 "$msg_file")"
		rewritten[$sha]="$new_sha"
		changed=1
	done

	rm -rf "$tmpdir"

	if [ "$dry_run" -eq 1 ]; then
		echo ""
		echo "Dry run: no issue filed, nothing rewritten"
		return 0
	fi

	local new_head="${rewritten[${range[-1]}]}"

	if ! git update-ref -m "prel attach-issue (${#filing[@]} commit(s))" HEAD "$new_head" "$old_head"; then
		echo "Error: Failed to move HEAD to $new_head" >&2
		echo "       the issues filed are kept in .git/prel-attached-issue and reused on a retry" >&2
		return 1
	fi

	# The issues are carried by the history now, so the notes kept in case the
	# rewrite failed can go.
	for sha in "${filing[@]}"; do
		_ai_cache_drop "$sha"
	done

	echo ""
	for sha in "${filing[@]}"; do
		echo "Filed as issue #${number_of[$sha]} - ${url_of[$sha]}"
	done
	echo "HEAD is now $(git rev-parse --short HEAD)"
	echo "Previous HEAD: $old_head"
	echo "To undo: git update-ref HEAD $old_head"

	if [ -n "$upstream" ] && [ "$(git rev-list --count "$upstream" "^$new_head")" -gt 0 ]; then
		echo "Note: $upstream still holds the old commits, it needs a force push"
	fi
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	attach_issue "$@"
fi
