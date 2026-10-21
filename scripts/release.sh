#!/usr/bin/env bash
# release.sh - Move the VERSION file on, tag it, push it and publish the release
#
# Can be run directly or sourced from prel.sh
# Usage: prel release [usage|<x.y.z> [options]]
#        OR: ./scripts/release.sh [usage|<x.y.z> [options]]
#
# For a project whose version lives in a VERSION file at its root, the plainest
# form there is: the file is what the build reads, so moving it on, tagging that
# commit and publishing the tag is the whole of a release.

# Which file carries the version. A project keeping it elsewhere sets
# prel.versionFile in its own git config.
_rel_version_file() {
	local file
	file=$(git config --get prel.versionFile 2>/dev/null) || file=""
	[ -n "$file" ] || file="VERSION"
	printf '%s\n' "$file"
}

# What the tag is called. Projects differ on the leading 'v', so it is a
# setting; prel.tagPrefix set to an empty string gives a bare 1.0.1.
_rel_tag_prefix() {
	if git config --get prel.tagPrefix >/dev/null 2>&1; then
		git config --get prel.tagPrefix
	else
		printf 'v\n'
	fi
}

_rel_remote() {
	local remote
	if git remote get-url origin >/dev/null 2>&1; then
		printf 'origin\n'
		return 0
	fi
	remote=$(git remote | head -1)
	[ -n "$remote" ] || return 1
	printf '%s\n' "$remote"
}

_rel_is_github() {
	local url
	url=$(git remote get-url --push "$1" 2>/dev/null) || return 1
	case "$url" in
		*github.com*) return 0 ;;
		*) return 1 ;;
	esac
}

# Whether there is a terminal to ask on. The device node can be there with
# nothing attached to it, so opening it is the only test that answers.
_rel_has_tty() {
	( : < /dev/tty ) 2>/dev/null
}

# Ask on the terminal rather than on stdin: a command that pushes and publishes
# must not take a redirected pipe for an answer.
_rel_confirm() {
	local prompt="$1" reply
	printf '%s' "$prompt" > /dev/tty 2>/dev/null || return 1
	read -r reply < /dev/tty 2>/dev/null || return 1
	case "$reply" in
		y|Y|yes|YES|Yes|o|O|oui|OUI|Oui) return 0 ;;
		*) return 1 ;;
	esac
}

# The subjects of the commits this release carries, for the notes of the
# GitHub release: everything since the previous tag, or the whole history the
# first time round.
_rel_notes() {
	local tag="$1" previous="$2" range
	if [ -n "$previous" ]; then
		range="$previous..HEAD"
		printf '## Changes since %s\n\n' "$previous"
	else
		range="HEAD"
		printf '## Changes\n\n'
	fi
	git log --no-merges --format='- %s' "$range"
	printf '\n<sub>Published by prel from the VERSION file.</sub>\n'
}

release() {
	local version="" message="" dry_run=0 assume_yes=0 publish=1 draft=0

	if [ "${1-usage}" = "usage" ]; then
		cat <<EOF
release - Move the VERSION file on, tag it, push it and publish the release

Usage:
  prel release usage              Show this help
  prel release <x.y.z>            Bump, commit, tag, push, publish
  prel release <x.y.z> -n         Show every step, change nothing
  prel release <x.y.z> -y         Do not ask about uncommitted changes
  prel release <x.y.z> -m <msg>   Use <msg> for the commit and the tag
  prel release <x.y.z> --draft    Publish the GitHub release as a draft
  prel release <x.y.z> --no-release
                                  Commit, tag and push, publish nothing

Description:
  For a project that keeps its version in a VERSION file at its root, a
  release is that file moved on and the commit it was moved in made public.
  This does the five steps in order, and stops at the first one that fails:

    1. write <x.y.z> into the VERSION file
    2. commit that file alone
    3. tag the commit, annotated, as v<x.y.z>
    4. push the branch and the tag
    5. create the GitHub release, its notes the commits since the last tag

  Nothing is touched before every precondition is checked: a VERSION file to
  move, a three-number version, a branch rather than a detached HEAD, a tag
  that is free both here and on the remote, and a usable gh unless
  --no-release says not to publish. A release half made is worse than one not
  started.

  Uncommitted changes are not carried into a release. Where the tree has any,
  the command shows them and asks, since committing the version alone leaves
  them exactly where they were; -y answers yes in advance and no terminal to
  ask on is an answer of no.

  The tag is v<x.y.z>, or the version alone where prel.tagPrefix is set to an
  empty string. The file is VERSION, or the path in prel.versionFile. The
  release commit is made with PREL_SKIP_ISSUE set, so it never consumes the
  sum-up that 'prel issue-from-plans' is holding for the next real commit.
EOF
		return 0
	fi

	while [ $# -gt 0 ]; do
		case "$1" in
			-n|--dry-run) dry_run=1 ;;
			-y|--yes) assume_yes=1 ;;
			--no-release) publish=0 ;;
			--draft) draft=1 ;;
			-m|--message)
				shift
				message="${1-}"
				if [ -z "$message" ]; then
					echo "Error: -m wants a message" >&2
					return 1
				fi
				;;
			-*)
				echo "Error: Unknown option '$1' for release" >&2
				echo "Try: prel release usage" >&2
				return 1
				;;
			*)
				if [ -n "$version" ]; then
					echo "Error: one version at a time, got '$version' and '$1'" >&2
					return 1
				fi
				version="$1"
				;;
		esac
		shift
	done

	if [ -z "$version" ]; then
		echo "Error: release wants a version, as in 'prel release 1.0.1'" >&2
		return 1
	fi

	# Semantic versioning, with the pre-release suffix allowed: the three
	# numbers are what a VERSION file is for, and a typo here becomes a tag.
	if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
		echo "Error: '$version' is not a version of three numbers (1.0.1, 1.0.1-rc1)" >&2
		return 1
	fi

	local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$REPO_ROOT"

	local version_file current
	version_file=$(_rel_version_file)
	if [ ! -f "$version_file" ]; then
		echo "Error: no $version_file in $REPO_ROOT, nothing to release" >&2
		echo "       a project keeping its version elsewhere sets prel.versionFile" >&2
		return 1
	fi
	current=$(tr -d '[:space:]' < "$version_file")

	local branch
	branch=$(git symbolic-ref --short -q HEAD) || branch=""
	if [ -z "$branch" ]; then
		echo "Error: HEAD is detached, so there is no branch to push" >&2
		return 1
	fi

	local remote
	remote=$(_rel_remote) || {
		echo "Error: this repository has no remote to push to" >&2
		return 1
	}

	local tag
	tag="$(_rel_tag_prefix)$version"

	if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
		echo "Error: tag $tag already exists here" >&2
		return 1
	fi
	# A tag already on the remote would make the push fail halfway through, so
	# it is worth a question over the network before anything is written.
	local remote_tag
	if remote_tag=$(git ls-remote --tags "$remote" "refs/tags/$tag" 2>/dev/null) \
		&& [ -n "$remote_tag" ]; then
		echo "Error: tag $tag already exists on $remote" >&2
		return 1
	fi

	if [ "$publish" = "1" ]; then
		if ! command -v gh >/dev/null 2>&1; then
			echo "Error: gh not found, so no GitHub release can be created" >&2
			echo "       install it, or use --no-release to commit, tag and push only" >&2
			return 1
		fi
		if ! gh auth status >/dev/null 2>&1; then
			echo "Error: gh is not authenticated ('gh auth login')" >&2
			echo "       or use --no-release to commit, tag and push only" >&2
			return 1
		fi
		if ! _rel_is_github "$remote"; then
			echo "Error: $remote is not a github.com remote, so there is no release to create" >&2
			echo "       use --no-release to commit, tag and push only" >&2
			return 1
		fi
	fi

	[ -n "$message" ] || message="Release $version"

	# Everything that is not the version file, captured before the file is
	# written: from then on it is dirty itself and tells us nothing.
	local others
	others=$(git status --porcelain -- . ":(exclude)$version_file")

	echo "release:      $current -> $version"
	echo "version file: $version_file"
	echo "commit:       $message"
	echo "tag:          $tag (annotated)"
	echo "push:         $remote $branch, $remote $tag"
	if [ "$publish" = "1" ]; then
		echo "publish:      GitHub release $tag$([ "$draft" = "1" ] && printf ' (draft)')"
	else
		echo "publish:      nothing, --no-release"
	fi
	if [ "$current" = "$version" ]; then
		echo "note:         $version_file already reads $version, committing it as it stands"
	fi
	echo ""

	if [ -n "$others" ]; then
		echo "This tree has changes that will NOT be part of the release:"
		printf '%s\n' "$others" | sed -e 's/^/  /'
		echo ""
		echo "Only $version_file would be committed; these stay exactly as they are."
		if [ "$dry_run" != "1" ] && [ "$assume_yes" != "1" ]; then
			if ! _rel_has_tty; then
				echo "Error: no terminal to ask on, so the answer is no" >&2
				echo "       pass -y to release with these changes left behind" >&2
				return 1
			fi
			if ! _rel_confirm "Release $version anyway? [y/N] "; then
				echo "Nothing done." >&2
				return 1
			fi
			echo ""
		fi
	fi

	# The notes are read from the history as it stands: the release commit
	# carries no change of its own worth listing.
	local previous notes_file
	previous=$(git describe --tags --abbrev=0 2>/dev/null) || previous=""

	if [ "$dry_run" = "1" ]; then
		echo "--- $version_file ------------------------------------------------------"
		echo "$version"
		echo "--- release notes ------------------------------------------------------"
		_rel_notes "$tag" "$previous"
		echo "------------------------------------------------------------------------"
		echo ""
		echo "Dry run: nothing was written, committed, pushed or published."
		return 0
	fi

	printf '%s\n' "$version" > "$version_file" || {
		echo "Error: could not write $version_file" >&2
		return 1
	}

	# PREL_SKIP_ISSUE: a release is not the commit that files the finished work
	# plans, and must not spend the issue the sum-up is waiting for.
	if ! PREL_SKIP_ISSUE=1 git commit --quiet -m "$message" -- "$version_file"; then
		echo "Error: the release commit failed, $version_file left at $version" >&2
		return 1
	fi
	echo "Committed $version_file at $version"

	if ! git tag -a "$tag" -m "$message"; then
		echo "Error: could not create tag $tag; the commit stands" >&2
		echo "       undo it with 'git reset --hard HEAD~1' if you want it gone" >&2
		return 1
	fi
	echo "Tagged $tag"

	if ! git push --quiet "$remote" "$branch"; then
		echo "Error: could not push $branch to $remote; the commit and $tag are local" >&2
		echo "       nothing is published, so a retry after fixing the remote is safe" >&2
		return 1
	fi
	echo "Pushed $branch to $remote"

	if ! git push --quiet "$remote" "refs/tags/$tag"; then
		echo "Error: could not push $tag to $remote; the commit is pushed, the tag is not" >&2
		return 1
	fi
	echo "Pushed $tag to $remote"

	if [ "$publish" != "1" ]; then
		echo ""
		echo "prel release: $version is committed, tagged and pushed; nothing published"
		return 0
	fi

	notes_file=$(mktemp) || return 1
	_rel_notes "$tag" "$previous" > "$notes_file"

	local -a gh_args=(release create "$tag" --title "$tag" --notes-file "$notes_file")
	[ "$draft" = "1" ] && gh_args+=(--draft)

	local url
	if ! url=$(gh "${gh_args[@]}" 2>&1); then
		echo "Error: gh release create failed; $tag is pushed, so this can be retried" >&2
		printf '%s\n' "$url" | sed -e 's/^/       /' >&2
		rm -f "$notes_file"
		return 1
	fi
	rm -f "$notes_file"

	echo ""
	echo "prel release: $version released as $tag"
	printf '%s\n' "$url" | sed -n 's#.*\(https://[^ ]*\).*#              \1#p' | tail -1
	return 0
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	release "$@"
fi
