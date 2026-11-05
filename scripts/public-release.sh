#!/usr/bin/env bash
# public-release.sh - Publish a release on the public releases repository
#
# Can be run directly or sourced from prel.sh
# Usage: prel public-release [usage|<x.y.z>|major|minor|micro|current [options]]
#        OR: ./scripts/public-release.sh [usage|<x.y.z>|major|minor|micro|current [options]]
#
# publicReleasesRepository in prel.config.json names a second GitHub
# repository, as owner/repo, that a release is also published on: this command
# clones it into a temporary directory, writes the same version file there
# with the version being published, commits, tags and pushes, then creates the
# GitHub release on it with the notes of this repository and uploads the
# artifacts copied from this repository's tree - the files 'prel release'
# built, not a build run again. This repository is only read, never written:
# its VERSION file is not touched, and the commit and the tag are made in the
# clone.
#
# The release settings - versionFile, tagPrefix, artifacts - are the ones
# release.sh reads, so what is published here is what 'prel release' released:
# the same version file, the same tag, the same artifacts.

# The public releases repository, as owner/repo, out of prel.config.json.
# Empty where the file is silent, which is every project that has not asked
# for one, and this command has nothing to publish without it.
_public_releases_repo() {
	_prel_config_text publicReleasesRepository ""
}

# Whether a value names a repository gh can be pointed at: owner/repo, the
# shape 'gh --repo' wants.
_public_is_repo_slug() {
	[[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

public_release() {
	local version="" message="" dry_run=0 draft=0

	if [ "${1-usage}" = "usage" ]; then
		cat <<EOF
public-release - Publish a release on the public releases repository

Usage:
  prel public-release usage              Show this help
  prel public-release <x.y.z>            Publish <x.y.z> on publicReleasesRepository
  prel public-release major              The same, for the version a level gives
  prel public-release minor
  prel public-release micro
  prel public-release current            The version the version file reads
  prel public-release <x.y.z> -n         Show every step, change nothing
  prel public-release <x.y.z> -m <msg>   Use <msg> for the commit and the tag
  prel public-release <x.y.z> --draft    Publish the GitHub release as a draft

Description:
  publicReleasesRepository in prel.config.json names a second GitHub
  repository, as owner/repo:

    { "publicReleasesRepository": "acme/myapp-releases" }

  and this command publishes a release on it, the way 'prel release' publishes
  one on this repository. It clones that repository into a temporary
  directory, writes the same version file there with the version being
  published, commits that file alone, tags the commit, annotated, pushes the
  branch and the tag, then creates the GitHub release there with the notes
  this repository's commits make and uploads the artifacts the artifacts
  setting names. The steps, in order, stopping at the first that fails:

    1. clone publicReleasesRepository into a temporary directory
    2. write the version into the version file there
    3. commit that file alone, in the clone
    4. tag the commit, annotated, as v<x.y.z>
    5. push the branch and the tag to publicReleasesRepository
    6. create the GitHub release there, its notes the commits of this
       repository since its last tag
    7. upload the artifacts, copied from this repository's tree, then take
       the release out of draft now that it has them

  This repository is only read, never written: its VERSION file is not
  touched, and a tag free here is not required - the tag is made in the
  clone. The artifacts, though, are copied from this repository's tree as it
  stands, so they have to be there: a pattern matching no file stops the
  command before anything is cloned, which is what 'prel release' (or 'prel
  build --release') leaves behind. No build runs here.

  The version can be worked out rather than given: major, minor, micro and
  current read the version file of this repository exactly as 'prel release'
  does, so 'prel public-release micro' publishes the same version 'prel
  release micro' would release. Either way the first line says which version
  came out of the word: 'public release: 0.2.7 -> 0.2.8 (micro)'.

  The release is created as a draft whenever there are artifacts and taken
  out of draft once they are all up, so it is never visible without them;
  --draft leaves it a draft. A tag already on the public repository is said
  to be there and nothing is pushed - running this again for a version already
  published is a no-op.

  No milestone and no pbus event on the public repository: the issues live in
  this repository, and the release is announced once, by 'prel release'. This
  command is for publishing the release somewhere else, not for announcing
  it again.

  Everything is checked before anything is cloned: the config usable, the key
  set and an owner/repo, a usable gh, a version file to read, a three-number
  version, and every artifacts pattern matching a file here. A publish half
  made is worse than one not started.
EOF
		return 0
	fi

	while [ $# -gt 0 ]; do
		case "$1" in
			-n|--dry-run) dry_run=1 ;;
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
				echo "Error: Unknown option '$1' for public-release" >&2
				echo "Try: prel public-release usage" >&2
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
		echo "Error: public-release wants a version or a level, as in 'prel public-release 1.0.1'" >&2
		echo "       or 'prel public-release micro'" >&2
		return 1
	fi

	# A typo here becomes a tag on the public repository, so it is worth
	# refusing before anything is cloned.
	local asked="$version"
	if ! _rel_is_version "$asked" && ! _rel_is_level "$asked" \
		&& [ "$asked" != "current" ]; then
		echo "Error: '$asked' is neither a version of three numbers (1.0.1, 1.0.1-rc1)" >&2
		echo "       nor one of major, minor, micro, current" >&2
		return 1
	fi
	version=""

	local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$REPO_ROOT"

	# Before a word of it is believed: a key prel does not know or a value of
	# the wrong shape stops the command here, where nothing has happened yet.
	if ! _prel_config_ok_verbose; then
		echo "Error: prel.config.json is not usable, so nothing was published" >&2
		return 1
	fi

	local repo
	repo=$(_public_releases_repo)
	if [ -z "$repo" ]; then
		echo "Error: publicReleasesRepository is not set in prel.config.json, so there is" >&2
		echo "       no public releases repository to publish to" >&2
		echo '       set it, as in: { "publicReleasesRepository": "acme/myapp-releases" }' >&2
		return 1
	fi
	if ! _public_is_repo_slug "$repo"; then
		echo "Error: publicReleasesRepository is '$repo', which is not an owner/repo" >&2
		echo "       a GitHub release can be published to" >&2
		return 1
	fi

	if ! command -v gh >/dev/null 2>&1; then
		echo "Error: gh not found, so no GitHub release can be created on $repo" >&2
		echo "       install it ('gh auth login' once it is)" >&2
		return 1
	fi
	if ! gh auth status >/dev/null 2>&1; then
		echo "Error: gh is not authenticated ('gh auth login')" >&2
		return 1
	fi

	local version_file current
	version_file=$(_rel_version_file)
	if [ ! -f "$version_file" ]; then
		echo "Error: no $version_file in $REPO_ROOT, nothing to take the version from" >&2
		echo "       a project keeping its version elsewhere sets versionFile" >&2
		echo "       in prel.config.json" >&2
		return 1
	fi
	current=$(tr -d '[:space:]' < "$version_file")

	# The word becomes a version here, where the file it is counted from has
	# just been read - the same resolver 'prel release' uses.
	if _rel_is_version "$asked"; then
		version="$asked"
	else
		if ! _rel_is_version "$current"; then
			_rel_uncountable "$asked" "$version_file" "$current" "prel public-release"
			return 1
		fi
		version=$(_rel_resolve_version "$asked" "$current") || return 1
	fi

	local tag
	tag="$(_rel_tag_prefix)$version"

	# The artifacts are copied from this repository's tree, so they have to
	# match here, before anything is cloned: this is the one check that cannot
	# wait for the clone.
	_rel_artifacts || return 1
	local -a patterns=("${_REL_PATTERNS[@]}")
	local assets=0
	[ ${#patterns[@]} -gt 0 ] && assets=1
	_rel_expand_artifacts "$version" "$tag" "${patterns[@]}" || true

	# The previous tag here, for the notes of the release on the public
	# repository: the same range 'prel release' writes them from.
	local previous
	previous=$(git describe --tags --abbrev=0 2>/dev/null) || previous=""

	[ -n "$message" ] || message="Release $version"

	if [ "$asked" = "$version" ]; then
		echo "public release: $current -> $version"
	else
		echo "public release: $current -> $version ($asked)"
	fi
	echo "repository:     $repo"
	echo "version file:   $version_file (in the clone; this one is not touched)"
	echo "commit:         $message"
	echo "tag:            $tag (annotated)"
	if [ "$assets" = "1" ]; then
		if [ ${#_REL_ASSETS[@]} -gt 0 ]; then
			echo "artifacts:      $(_prel_list_line "${_REL_ASSETS[@]}") (copied from here)"
		else
			echo "artifacts:      $(_prel_list_line "${_REL_MISSING[@]}") (match nothing here as the tree stands)"
		fi
	fi
	if [ "$draft" = "1" ]; then
		echo "publish:        GitHub release $tag on $repo (draft)"
	elif [ "$assets" = "1" ]; then
		echo "publish:        GitHub release $tag on $repo (draft until the artifacts are up)"
	else
		echo "publish:        GitHub release $tag on $repo"
	fi
	echo "notes:          the commits here since ${previous:-the first commit}"
	if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
		echo "note:           $tag is not tagged in this repository, so 'prel release $version'"
		echo "                has not made it here; publishing it on $repo anyway"
	fi
	echo ""

	if [ "$assets" = "1" ] && [ ${#_REL_MISSING[@]} -gt 0 ]; then
		echo "Error: these artifacts of prel.config.json matched no file in $REPO_ROOT:" >&2
		printf '       %s\n' "${_REL_MISSING[@]}" >&2
		_rel_placeholder_hint '       ' "${_REL_MISSING[@]}" >&2
		echo "       they are copied from this repository, so build them first -" >&2
		echo "       'prel release $version', or 'prel build --release' on its own" >&2
		return 1
	fi

	if [ "$dry_run" = "1" ]; then
		echo "--- release notes ------------------------------------------------------"
		_rel_notes "$tag" "$previous"
		echo "------------------------------------------------------------------------"
		echo ""
		echo "Dry run: nothing was cloned, written, pushed or published."
		return 0
	fi

	local dir notes_file url branch mirror_version
	local -a gh_args

	dir=$(mktemp -d) || return 1

	# Cloned with gh rather than git, so the credentials gh already holds are
	# the ones the clone uses. The git work runs with -C rather than a cd, so
	# the artifact paths stay relative to this repository for the upload.
	if ! gh repo clone "$repo" "$dir" >/dev/null 2>&1; then
		echo "Error: could not clone $repo" >&2
		rm -rf "$dir"
		return 1
	fi
	if [ -n "$(git -C "$dir" ls-remote --tags origin "refs/tags/$tag" 2>/dev/null)" ]; then
		echo "$repo already has $tag, nothing to publish"
		rm -rf "$dir"
		return 0
	fi

	mirror_version=""
	[ -f "$dir/$version_file" ] && mirror_version=$(tr -d '[:space:]' < "$dir/$version_file")
	if [ "$mirror_version" != "$version" ]; then
		# Added first: in a fresh clone the version file is not tracked yet,
		# and 'commit -- <path>' only takes tracked paths.
		if ! printf '%s\n' "$version" > "$dir/$version_file" \
			|| ! git -C "$dir" add -- "$version_file" \
			|| ! PREL_SKIP_ISSUE=1 git -C "$dir" commit --quiet -m "$message" -- "$version_file"; then
			echo "Error: could not commit $version_file at $version in $repo" >&2
			rm -rf "$dir"
			return 1
		fi
		echo "Committed $version_file at $version in $repo"
	fi

	if ! git -C "$dir" tag -a "$tag" -m "$message"; then
		echo "Error: could not create tag $tag in $repo" >&2
		rm -rf "$dir"
		return 1
	fi

	branch=$(git -C "$dir" symbolic-ref --short -q HEAD) || branch=""
	if [ -z "$branch" ] \
		|| ! git -C "$dir" push --quiet origin "$branch" \
		|| ! git -C "$dir" push --quiet origin "refs/tags/$tag"; then
		echo "Error: could not push $tag to $repo; the commit and $tag are local to the clone" >&2
		rm -rf "$dir"
		return 1
	fi
	echo "Pushed $tag to $repo"

	notes_file=$(mktemp) || {
		rm -rf "$dir"
		return 1
	}
	_rel_notes "$tag" "$previous" > "$notes_file"

	gh_args=(release create "$tag" --repo "$repo" --title "$tag" --notes-file "$notes_file")
	# A draft either because that is what was asked for, or because artifacts
	# are still to come - same rule as 'prel release'.
	if [ "$draft" = "1" ] || [ "$assets" = "1" ]; then
		gh_args+=(--draft)
	fi

	if ! url=$(gh "${gh_args[@]}" 2>&1); then
		echo "Error: gh release create failed on $repo; $tag is pushed there, so this can be retried" >&2
		printf '%s\n' "$url" | sed -e 's/^/       /' >&2
		rm -f "$notes_file"
		rm -rf "$dir"
		return 1
	fi

	if [ "$assets" = "1" ]; then
		if ! gh release upload "$tag" --repo "$repo" --clobber "${_REL_ASSETS[@]}"; then
			echo "Error: the artifacts could not be uploaded to $tag on $repo" >&2
			echo "       $tag is a draft there; finish it with" >&2
			echo "       'gh release upload $tag --repo $repo --clobber <files>'" >&2
			[ "$draft" != "1" ] && echo "       then 'gh release edit $tag --repo $repo --draft=false'" >&2
			rm -f "$notes_file"
			rm -rf "$dir"
			return 1
		fi
		echo "Uploaded ${#_REL_ASSETS[@]} artifact(s) to $tag on $repo"

		if [ "$draft" != "1" ]; then
			if ! gh release edit "$tag" --repo "$repo" --draft=false >/dev/null; then
				echo "Error: $tag on $repo has its artifacts but could not be taken out of draft" >&2
				echo "       finish it with 'gh release edit $tag --repo $repo --draft=false'" >&2
				rm -f "$notes_file"
				rm -rf "$dir"
				return 1
			fi
		fi
	fi

	rm -f "$notes_file"
	rm -rf "$dir"

	echo ""
	if [ "$draft" = "1" ]; then
		echo "prel public-release: $version is tagged and pushed on $repo, $tag waiting as a draft"
	else
		echo "prel public-release: $version published as $tag on $repo"
	fi
	printf '%s\n' "$url" | sed -n 's#.*\(https://[^ ]*\).*#              \1#p' | tail -1

	return 0
}

# If this script is run directly (not sourced), call the function. Sourced
# from prel.sh the shared readers are already loaded; run directly, this has
# to load them itself - sourcing release.sh only defines its functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_public_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	for _public_sibling in config.sh release.sh; do
		# shellcheck source=/dev/null
		[ -r "$_public_dir/$_public_sibling" ] && source "$_public_dir/$_public_sibling"
	done
	public_release "$@"
fi
