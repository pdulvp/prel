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

# The command that builds the release artifacts, run from the repository root.
# Unset in most projects, where a release is the tag and nothing else.
_rel_build_command() {
	git config --get prel.buildCommand 2>/dev/null || true
}

# The artifacts to attach to the release, as whitespace-separated globs read
# from the repository root: "build/*.deb build-win/*.zip". A list of patterns
# cannot also hold paths with spaces in them; that is the trade made here.
_rel_artifacts_spec() {
	git config --get prel.artifacts 2>/dev/null || true
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

# Expand the artifact globs. _REL_ASSETS comes back holding every file matched
# and _REL_MISSING the patterns that matched none; the return is non-zero if
# any pattern did. Only regular files count: a pattern matching a directory
# alone has not found the file it was written for.
#
# An unmatched pattern is the failure worth stopping on. It is how a release
# ends up published without the Windows zip nobody noticed was missing.
_rel_expand_artifacts() {
	local spec="$1" pattern candidate nullglob_was_set
	local -a patterns matches
	_REL_ASSETS=()
	_REL_MISSING=()

	# Split the list first, and with 'read' rather than word splitting, so that
	# nullglob below cannot make a pattern matching nothing disappear before it
	# has been reported as matching nothing.
	read -ra patterns <<< "$spec"

	shopt -q nullglob && nullglob_was_set=1 || nullglob_was_set=0
	shopt -s nullglob
	for pattern in "${patterns[@]}"; do
		matches=()
		# Unquoted on purpose: this is the pathname expansion being asked for.
		for candidate in $pattern; do
			[ -f "$candidate" ] && matches+=("$candidate")
		done
		if [ ${#matches[@]} -eq 0 ]; then
			_REL_MISSING+=("$pattern")
		else
			_REL_ASSETS+=("${matches[@]}")
		fi
	done
	[ "$nullglob_was_set" = "1" ] || shopt -u nullglob

	[ ${#_REL_MISSING[@]} -eq 0 ]
}

# Undo the release commit and its tag, putting the version file back from the
# copy taken before it was written and leaving the rest of the tree exactly as
# it was. Deliberately not 'reset --hard': this command releases from a dirty
# tree on purpose, so it must never discard the changes it warned about and
# then kept. Returns non-zero where there is no parent commit to step back to,
# which is the one case the caller has to report rather than fix.
_rel_rollback_release_commit() {
	local tag="$1" version_file="$2" backup="$3"

	git tag -d "$tag" >/dev/null 2>&1

	git rev-parse -q --verify HEAD~1 >/dev/null 2>&1 || return 1
	git reset --quiet --soft HEAD~1 || return 1
	# Mixed reset of that one path: the index goes back to HEAD for the version
	# file and every other staged path keeps whatever it held.
	git reset -q -- "$version_file" >/dev/null 2>&1
	if [ -n "$backup" ] && [ -f "$backup" ]; then
		cp "$backup" "$version_file" || return 1
	fi
	return 0
}

# Roll the release commit and tag back and say what is left, for the two
# failures that can happen while it is all still local. Drops the copy of the
# version file either way: there is no second attempt to make from it.
_rel_undo_and_report() {
	local tag="$1" version_file="$2" backup="$3" current="$4"
	if _rel_rollback_release_commit "$tag" "$version_file" "$backup"; then
		echo "       the commit and $tag are undone, $version_file back at $current" >&2
		echo "       nothing was pushed or published, so this can be run again" >&2
	else
		echo "       the commit and $tag could not be undone here; nothing was" >&2
		echo "       pushed or published, but $version_file reads $current no more" >&2
	fi
	rm -f "$backup"
}

release() {
	local version="" message="" dry_run=0 assume_yes=0 publish=1 draft=0
	local no_build=0 no_assets=0

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
  prel release <x.y.z> --no-build Upload the artifacts without building them
  prel release <x.y.z> --no-assets
                                  Build nothing, upload nothing
  prel release <x.y.z> --no-release
                                  Commit, tag and push, publish nothing

Description:
  For a project that keeps its version in a VERSION file at its root, a
  release is that file moved on and the commit it was moved in made public.
  This does the steps in order, and stops at the first one that fails:

    1. write <x.y.z> into the VERSION file
    2. commit that file alone
    3. tag the commit, annotated, as v<x.y.z>
    4. build the artifacts, where prel.buildCommand says how
    5. push the branch and the tag
    6. create the GitHub release, its notes the commits since the last tag
    7. upload the artifacts in prel.artifacts, then take the release out of
       draft now that it has them

  Steps 4 and 7 happen only in a project that has asked for them:

    git config prel.buildCommand "cmake --build build --target release"
    git config prel.artifacts "build/*.deb build-win/*.zip"

  The build runs before the push, while the commit and the tag are still only
  local. A build that fails there undoes both and leaves nothing published,
  rather than a public tag whose release holds no files. The release is created
  as a draft whenever there are artifacts and taken out of draft once they are
  all up, so it is never visible without them; --draft leaves it a draft. A
  pattern matching no file stops the release before the push - that is how a
  release goes out missing the one artifact nobody checked for.

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
			--no-build) no_build=1 ;;
			--no-assets) no_assets=1 ;;
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

	# What the project asked for, and what the options make of it. Nothing to
	# upload to means nothing worth building, so --no-release and --no-assets
	# both take the build down with them.
	local build_command artifacts_spec build=0 assets=0
	build_command=$(_rel_build_command)
	artifacts_spec=$(_rel_artifacts_spec)
	[ -n "$build_command" ] && build=1
	[ -n "$artifacts_spec" ] && assets=1
	[ "$no_build" = "1" ] && build=0
	if [ "$no_assets" = "1" ] || [ "$publish" = "0" ]; then
		assets=0
		build=0
	fi

	# Everything that is not the version file, captured before the file is
	# written: from then on it is dirty itself and tells us nothing.
	local others
	others=$(git status --porcelain -- . ":(exclude)$version_file")

	echo "release:      $current -> $version"
	echo "version file: $version_file"
	echo "commit:       $message"
	echo "tag:          $tag (annotated)"
	echo "push:         $remote $branch, $remote $tag"
	if [ "$build" = "1" ]; then
		echo "build:        $build_command"
	elif [ -n "$build_command" ]; then
		echo "build:        nothing, prel.buildCommand not run"
	fi
	if [ "$assets" = "1" ]; then
		echo "artifacts:    $artifacts_spec"
	elif [ -n "$artifacts_spec" ]; then
		echo "artifacts:    nothing, prel.artifacts not uploaded"
	fi
	if [ "$publish" != "1" ]; then
		echo "publish:      nothing, --no-release"
	elif [ "$draft" = "1" ]; then
		echo "publish:      GitHub release $tag (draft)"
	elif [ "$assets" = "1" ]; then
		echo "publish:      GitHub release $tag (draft until the artifacts are up)"
	else
		echo "publish:      GitHub release $tag"
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
		if [ "$assets" = "1" ]; then
			echo "--- artifacts ----------------------------------------------------------"
			_rel_expand_artifacts "$artifacts_spec"
			[ ${#_REL_ASSETS[@]} -gt 0 ] && printf '%s\n' "${_REL_ASSETS[@]}"
			[ ${#_REL_MISSING[@]} -gt 0 ] \
				&& printf '%s  (matches nothing as the tree stands)\n' "${_REL_MISSING[@]}"
			if [ "$build" = "1" ]; then
				echo "(the build runs before this is checked, so it may yet produce them)"
			fi
		fi
		echo "--- release notes ------------------------------------------------------"
		_rel_notes "$tag" "$previous"
		echo "------------------------------------------------------------------------"
		echo ""
		echo "Dry run: nothing was written, committed, pushed or published."
		return 0
	fi

	# Copied aside while it still holds the old version, so a failed build can
	# put the file back byte for byte rather than rebuild it from what it read.
	local backup=""
	if [ "$build" = "1" ] || [ "$assets" = "1" ]; then
		backup=$(mktemp) || return 1
		if ! cp "$version_file" "$backup"; then
			rm -f "$backup"
			echo "Error: could not copy $version_file aside" >&2
			return 1
		fi
	fi

	printf '%s\n' "$version" > "$version_file" || {
		rm -f "$backup"
		echo "Error: could not write $version_file" >&2
		return 1
	}

	# PREL_SKIP_ISSUE: a release is not the commit that files the finished work
	# plans, and must not spend the issue the sum-up is waiting for.
	if ! PREL_SKIP_ISSUE=1 git commit --quiet -m "$message" -- "$version_file"; then
		echo "Error: the release commit failed, $version_file left at $version" >&2
		rm -f "$backup"
		return 1
	fi
	echo "Committed $version_file at $version"

	if ! git tag -a "$tag" -m "$message"; then
		echo "Error: could not create tag $tag; the commit stands" >&2
		echo "       undo it with 'git reset --hard HEAD~1' if you want it gone" >&2
		rm -f "$backup"
		return 1
	fi
	echo "Tagged $tag"

	# Everything from here to the push is undoable, and that is the point of
	# building here rather than after it.
	if [ "$build" = "1" ]; then
		echo ""
		echo "build: $build_command"
		if ! ( cd "$REPO_ROOT" && eval "$build_command" ); then
			echo ""
			echo "Error: the build failed, so there is no release to make" >&2
			_rel_undo_and_report "$tag" "$version_file" "$backup" "$current"
			return 1
		fi
		echo ""
	fi

	if [ "$assets" = "1" ]; then
		if ! _rel_expand_artifacts "$artifacts_spec"; then
			echo "Error: these patterns in prel.artifacts matched no file:" >&2
			printf '       %s\n' "${_REL_MISSING[@]}" >&2
			if [ ${#_REL_ASSETS[@]} -gt 0 ]; then
				echo "       what did match, and would have gone up alone:" >&2
				printf '       %s\n' "${_REL_ASSETS[@]}" >&2
			fi
			echo "       a release is not published short of its artifacts" >&2
			_rel_undo_and_report "$tag" "$version_file" "$backup" "$current"
			return 1
		fi
		echo "Artifacts to upload:"
		printf '  %s\n' "${_REL_ASSETS[@]}"
	fi

	# Past this line nothing is undoable, so the copy has no further use.
	rm -f "$backup"
	backup=""

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
	# A draft either because that is what was asked for, or because artifacts
	# are still to come and a release without them is not one.
	if [ "$draft" = "1" ] || [ "$assets" = "1" ]; then
		gh_args+=(--draft)
	fi

	local url
	if ! url=$(gh "${gh_args[@]}" 2>&1); then
		echo "Error: gh release create failed; $tag is pushed, so this can be retried" >&2
		printf '%s\n' "$url" | sed -e 's/^/       /' >&2
		rm -f "$notes_file"
		return 1
	fi
	rm -f "$notes_file"

	if [ "$assets" = "1" ]; then
		if ! gh release upload "$tag" --clobber "${_REL_ASSETS[@]}"; then
			echo "Error: the artifacts could not be uploaded; $tag is published as a" >&2
			echo "       draft, so nobody is looking at a release without them" >&2
			echo "       the files are built and waiting:" >&2
			printf '       %s\n' "${_REL_ASSETS[@]}" >&2
			echo "       finish it with 'gh release upload $tag --clobber <files>'" >&2
			[ "$draft" != "1" ] && echo "       then 'gh release edit $tag --draft=false'" >&2
			return 1
		fi
		echo "Uploaded ${#_REL_ASSETS[@]} artifact(s) to $tag"

		if [ "$draft" != "1" ]; then
			if ! gh release edit "$tag" --draft=false >/dev/null; then
				echo "Error: $tag has its artifacts but could not be taken out of draft" >&2
				echo "       finish it with 'gh release edit $tag --draft=false'" >&2
				return 1
			fi
		fi
	fi

	echo ""
	if [ "$draft" = "1" ]; then
		echo "prel release: $version is tagged and pushed, $tag waiting as a draft"
	else
		echo "prel release: $version released as $tag"
	fi
	printf '%s\n' "$url" | sed -n 's#.*\(https://[^ ]*\).*#              \1#p' | tail -1
	return 0
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	release "$@"
fi
