#!/usr/bin/env bash
# reapply-releases.sh - Re-point diverged tags and GitHub releases at rewritten commits, then force-push the branch
#
# Can be run directly or sourced from prel.sh
# Usage: prel reapply-releases [usage|-n|--dry-run] [--remote <name>]
#        OR: ./scripts/reapply-releases.sh [usage|-n|--dry-run] [--remote <name>]
#
# For after a history rewrite ('prel exclude-from-git'): the local branch
# carries the same commits under new hashes, but the tags on the remote - and
# the GitHub releases attached to them - still point at the old ones.

# The exact message bytes of a commit: everything after the first blank line
# of the raw object, the same trick exclude-from-git uses.
_reapply_message() {
	git cat-file commit "$1" | sed -e '1,/^$/d'
}

# The local commit carrying the same message as the old commit $1. A rewrite
# keeps messages, author and committer dates, so the message is the commit's
# name; the author date breaks ties between commits sharing a message.
_reapply_find_commit() {
	local old="$1"
	local old_msg old_date
	old_msg=$(_reapply_message "$old")
	old_date=$(git log -1 --format='%aI' "$old")

	local c msg date fallback="" count=0
	while IFS= read -r c; do
		msg=$(_reapply_message "$c")
		[ "$msg" = "$old_msg" ] || continue
		count=$((count + 1))
		date=$(git log -1 --format='%aI' "$c")
		if [ "$date" = "$old_date" ]; then
			echo "$c"
			return 0
		fi
		[ -z "$fallback" ] && fallback="$c"
	done < <(git rev-list HEAD)

	if [ -n "$fallback" ]; then
		if [ "$count" -gt 1 ]; then
			echo "Warning: $count local commits share the message of $(git rev-parse --short "$old"), taking the newest" >&2
		fi
		echo "$fallback"
		return 0
	fi
	return 1
}

# Re-point tag $2 at commit $4, keeping an annotated tag annotated with its
# own message and tagger. $1 is a scratch dir, $3 the old tag ref to read from.
_reapply_retag() {
	local tmp="$1" tag="$2" old_ref="$3" new="$4" type="$5"
	if [ "$type" = "tag" ]; then
		local body tagger name email cdate
		body=$(git cat-file tag "$old_ref")
		printf '%s\n' "$body" | sed -e '1,/^$/d' >"$tmp/msg"
		tagger=$(printf '%s\n' "$body" | sed -n 's/^tagger //p')
		if [ -n "$tagger" ]; then
			# A tagger line reads "Name <email> 1699999999 +0000".
			name="${tagger%% <*}"
			email="${tagger#* <}"
			email="${email%%>*}"
			cdate="${tagger#*> }"
			GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" GIT_COMMITTER_DATE="$cdate" \
				git tag -f -a "$tag" -F "$tmp/msg" "$new"
		else
			git tag -f -a "$tag" -F "$tmp/msg" "$new"
		fi
	else
		git tag -f "$tag" "$new"
	fi
}

# Recreate the GitHub release of tag $1 on the (already moved) tag, with the
# same title, notes, draft and prerelease flags, and the same assets: they are
# downloaded before the delete, then uploaded again. Prints the asset count.
_reapply_recreate_release() {
	local tag="$1" tmp="$2" adir="$3"
	local title draft pre nassets
	title=$(gh release view "$tag" --json name -q .name) || return 1
	gh release view "$tag" --json body -q .body >"$tmp/body" || return 1
	draft=$(gh release view "$tag" --json isDraft -q .isDraft)
	pre=$(gh release view "$tag" --json isPrerelease -q .isPrerelease)
	nassets=$(gh release view "$tag" --json assets -q '.assets | length')

	# The assets die with the old release, so they come down first.
	if [ "$nassets" -gt 0 ]; then
		gh release download "$tag" --dir "$adir" --pattern '*' --clobber >/dev/null || return 1
	fi

	gh release delete "$tag" --yes || return 1

	local -a args=(release create "$tag" --title "$title" --notes-file "$tmp/body")
	[ "$draft" = "true" ] && args+=(--draft)
	[ "$pre" = "true" ] && args+=(--prerelease)
	gh "${args[@]}" >/dev/null || return 1

	if [ "$nassets" -gt 0 ]; then
		gh release upload "$tag" --clobber "$adir"/* || return 1
	fi

	echo "$nassets"
}

# What the dry run says about the release of tag $1.
_reapply_dry_release() {
	local tag="$1" nassets
	if gh release view "$tag" --json tagName >/dev/null 2>&1; then
		nassets=$(gh release view "$tag" --json assets -q '.assets | length')
		echo "  release $tag: would be deleted and recreated on the new tag, $nassets asset(s) re-uploaded"
	else
		echo "  release $tag: none, the tag alone would be moved"
	fi
}

_reapply_main() {
	local dry_run="$1" remote="$2" branch="$3" remote_tip="$4" gh_repo="$5"

	local -a tags=() olds=() news=() types=()
	local tag ref obj peeled new type skipped=0 failed=0

	while IFS= read -r ref; do
		tag="${ref#refs/prel-reapply/tags/}"
		obj=$(git rev-parse "$ref")
		peeled=$(git rev-parse "$ref^{}")
		if git merge-base --is-ancestor "$peeled" HEAD 2>/dev/null; then
			skipped=$((skipped + 1))
			continue
		fi
		if ! new=$(_reapply_find_commit "$peeled"); then
			echo "Warning: no local commit matches '$(git log -1 --format=%s "$peeled")', $tag left alone" >&2
			failed=$((failed + 1))
			continue
		fi
		type=$(git cat-file -t "$obj")
		tags+=("$tag")
		olds+=("$peeled")
		news+=("$new")
		types+=("$type")
		echo "diverged: $tag  $(git rev-parse --short "$peeled") -> $(git rev-parse --short "$new")  $(git log -1 --format=%s "$peeled")"
	done < <(git for-each-ref --format='%(refname)' refs/prel-reapply/tags/)

	echo ""
	[ "$skipped" -gt 0 ] && echo "$skipped tag(s) still point at commits of $branch, left alone"
	[ "$failed" -gt 0 ] && echo "$failed tag(s) had no matching commit, left alone" >&2

	local head
	head=$(git rev-parse HEAD)

	if [ "$head" = "$remote_tip" ] && [ "${#tags[@]}" -eq 0 ]; then
		echo "Nothing to do: no tag of $remote has diverged and $remote/$branch is already at HEAD"
		return 0
	fi

	if [ "$dry_run" = "1" ]; then
		local i
		for i in "${!tags[@]}"; do
			_reapply_dry_release "${tags[$i]}"
		done
		echo ""
		echo "would force-push $branch: $remote/$branch $(git rev-parse --short "$remote_tip") -> $(git rev-parse --short "$head")"
		echo "Dry run: nothing was pushed, deleted, created or uploaded"
		return 0
	fi

	local tmp
	tmp=$(mktemp -d) || return 1

	local i adir nassets
	for i in "${!tags[@]}"; do
		tag="${tags[$i]}"
		if ! _reapply_retag "$tmp" "$tag" "refs/prel-reapply/tags/$tag" "${news[$i]}" "${types[$i]}"; then
			echo "Error: could not re-tag $tag locally" >&2
			rm -rf "$tmp"
			return 1
		fi
		if ! git push --quiet --force "$remote" "refs/tags/$tag"; then
			echo "Error: could not push $tag to $remote" >&2
			rm -rf "$tmp"
			return 1
		fi
		echo "tag $tag: $(git rev-parse --short "${olds[$i]}") -> $(git rev-parse --short "${news[$i]}")  pushed"

		if gh release view "$tag" --json tagName >/dev/null 2>&1; then
			adir="$tmp/assets-$i"
			mkdir -p "$adir"
			if ! nassets=$(_reapply_recreate_release "$tag" "$tmp" "$adir"); then
				echo "Error: could not recreate the release of $tag on $gh_repo" >&2
				echo "       $tag itself is already moved; the release can be rebuilt by hand" >&2
				echo "       with 'gh release create $tag --repo $gh_repo'" >&2
				rm -rf "$tmp"
				return 1
			fi
			echo "  release $tag recreated on the new tag, $nassets asset(s) re-uploaded"
		else
			echo "  no GitHub release on $tag, the tag alone was moved"
		fi
	done

	if ! git push --force-with-lease="refs/heads/$branch:$remote_tip" "$remote" "HEAD:refs/heads/$branch"; then
		echo "Error: could not force-push $branch to $remote" >&2
		rm -rf "$tmp"
		return 1
	fi
	echo ""
	echo "branch $branch force-pushed to $remote: $(git rev-parse --short "$remote_tip") -> $(git rev-parse --short "$head")"

	rm -rf "$tmp"
	return 0
}

reapply_releases() {
	local dry_run=0 remote="origin"

	if [ "${1-}" = "usage" ]; then
		cat <<EOF
reapply-releases - Re-point diverged tags and GitHub releases at rewritten commits, then force-push the branch

Usage:
  prel reapply-releases usage          Show this help
  prel reapply-releases                Move the diverged tags and releases, force-push the branch
  prel reapply-releases -n             Show what would move, change nothing
  prel reapply-releases --remote <r>   Read the tags of remote <r> instead of origin

Description:
  For after a history rewrite, 'prel exclude-from-git' among others: the local
  branch carries the same commits under new hashes, but the tags on the remote
  - and the GitHub releases attached to them - still point at the old ones.

  Every tag on the remote is checked against the local branch: if the commit
  the tag points at is still an ancestor of HEAD, the tag has not diverged and
  is left alone. Otherwise the tag is re-pointed at the local commit with the
  same message (a rewrite keeps messages and dates, so the message is the
  commit's name), locally and on the remote with 'git push --force'. An
  annotated tag stays annotated, its message and tagger kept.

  A GitHub release on a moved tag is recreated on the new tag with the same
  title, notes, draft and prerelease flags, and the same assets: they are
  downloaded from the old release first, the release is deleted, recreated,
  and the assets uploaded again with --clobber. A tag with no release is only
  moved.

  Once every diverged tag is moved, the local branch is force-pushed onto the
  same-named branch of the remote, with a lease on the tip read before anything
  was moved:

    git push --force-with-lease origin HEAD:main

  With -n nothing is pushed, deleted, created or uploaded: the tag mappings and
  the release recreations are only printed.

  Needs gh, authenticated, and a GitHub remote.
EOF
		return 0
	fi

	while [ $# -gt 0 ]; do
		case "$1" in
			-n | --dry-run) dry_run=1 ;;
			--remote)
				shift
				if [ $# -eq 0 ]; then
					echo "Error: --remote needs a remote name" >&2
					echo "Try: prel reapply-releases usage" >&2
					return 1
				fi
				remote="$1"
				;;
			--remote=*) remote="${1#--remote=}" ;;
			-*)
				echo "Error: Unknown option '$1' for reapply-releases" >&2
				echo "Try: prel reapply-releases usage" >&2
				return 1
				;;
			*)
				echo "Error: reapply-releases takes no argument, got '$1'" >&2
				echo "Try: prel reapply-releases usage" >&2
				return 1
				;;
		esac
		shift
	done

	local REPO_ROOT
	REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$REPO_ROOT"

	local branch
	branch=$(git rev-parse --abbrev-ref HEAD)
	if [ "$branch" = "HEAD" ]; then
		echo "Error: HEAD is detached, reapply-releases works on a branch" >&2
		return 1
	fi

	if ! git remote get-url "$remote" >/dev/null 2>&1; then
		echo "Error: no remote named '$remote'" >&2
		return 1
	fi

	local remote_tip
	remote_tip=$(git ls-remote --heads "$remote" "$branch" | cut -f1)
	if [ -z "$remote_tip" ]; then
		echo "Error: no branch '$branch' on $remote" >&2
		return 1
	fi

	if ! command -v gh >/dev/null 2>&1; then
		echo "Error: gh not found, so the GitHub releases cannot be moved" >&2
		echo "       install it ('gh auth login' once it is)" >&2
		return 1
	fi
	if ! gh auth status >/dev/null 2>&1; then
		echo "Error: gh is not authenticated ('gh auth login')" >&2
		return 1
	fi
	local gh_repo
	gh_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
	if [ -z "$gh_repo" ]; then
		echo "Error: $remote is not a GitHub repository gh can see, so no release can be moved" >&2
		return 1
	fi

	# The remote tags are fetched into a temporary namespace, so the local tags
	# are not touched until the command actually moves them, and the old tag
	# objects are available to read message and tagger from.
	if ! git fetch --quiet "$remote" "+refs/tags/*:refs/prel-reapply/tags/*"; then
		echo "Error: could not fetch the tags of $remote" >&2
		return 1
	fi

	local rc=0
	_reapply_main "$dry_run" "$remote" "$branch" "$remote_tip" "$gh_repo" || rc=$?

	# The temporary namespace goes whether the run succeeded or not.
	git for-each-ref --format='%(refname)' refs/prel-reapply/ |
		while IFS= read -r ref; do
			git update-ref -d "$ref"
		done

	return $rc
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	reapply_releases "$@"
fi
