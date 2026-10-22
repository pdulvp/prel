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

# The four settings a release reads, all of them out of prel.config.json -
# see 'prel config'. Each takes its default where the file is silent, and
# fails loudly where the file is there and cannot be read: a release that
# quietly took every default would tag the wrong file and upload nothing.

# Which file carries the version.
_rel_version_file() {
	_prel_config_text versionFile VERSION
}

# What the tag is called. Projects differ on the leading 'v', so it is a
# setting; "tagPrefix": "" gives a bare 1.0.1, which is why an empty value set
# on purpose has to be told from no value at all.
_rel_tag_prefix() {
	local prefix
	prefix=$(_prel_config_get tagPrefix)
	case $? in
		0) printf '%s\n' "$prefix" ;;
		1) printf 'v\n' ;;
		*) return 2 ;;
	esac
}

# The command that builds the release artifacts, run from the repository root.
# Unset in most projects, where a release is the tag and nothing else. Not the
# buildCommand of 'prel build', which is the ordinary build and no business of
# a release; 'prel build --release' runs this one on its own, which is how it
# gets tried before a release depends on it.
_rel_build_command() {
	_prel_config_text releaseBuildCommand ""
}

# The artifacts to attach to the release, as globs read from the repository
# root. _REL_PATTERNS comes back holding one pattern an element - an array in
# the file stays one entry a pattern, so a path with a space in it is as
# expressible as any other, which the whitespace-separated string it replaces
# could never manage.
_rel_artifacts() {
	_REL_PATTERNS=()
	mapfile -t _REL_PATTERNS < <(_prel_config_list artifacts)
	return 0
}


# Fill in the placeholders an artifacts pattern may carry: ${version} is
# the version being released and ${tag} the tag it gets, braced or bare. Plain
# string replacement rather than eval - a pattern becomes a filename, and must
# not be able to run a command on the way to becoming one. The braced forms go
# first, though neither spelling can eat into the other.
_rel_substitute_artifact_vars() {
	local pattern="$1" version="$2" tag="$3"
	pattern=${pattern//'${version}'/$version}
	pattern=${pattern//'${tag}'/$tag}
	pattern=${pattern//'$version'/$version}
	pattern=${pattern//'$tag'/$tag}
	printf '%s\n' "$pattern"
}

# Said of an unmatched pattern that still holds a '$': the name in it is not
# one of the two that get filled in, which is nearly always a misspelling.
# Written to stderr, where the unmatched patterns themselves are reported.
_rel_placeholder_hint() {
	local indent="$1" pattern
	shift
	for pattern in "$@"; do
		case "$pattern" in
			*'$'*)
				echo "${indent}a \$ left in a pattern is a name that was not filled in;"
				echo "${indent}artifacts knows \${version} and \${tag} only"
				return 0
				;;
		esac
	done
}

# The three numbers a VERSION file is for, the pre-release suffix allowed.
_rel_is_version() {
	[[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
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

# The issues a release fixes, read out of the commits it carries: prel's own
# convention puts '#<n> ' in front of the subject, so the range that writes the
# release notes is the range that names the issues. _REL_ISSUES comes back
# holding the numbers, ascending and without repeats.
#
# Subjects only. Every commit filed by 'prel issue-from-plans' carries a
# 'filed as issue #<n>' trailer in its body as well, and reading those would
# put the same issue in every range it was ever mentioned in.
_rel_issues_in_range() {
	local previous="$1" range
	_REL_ISSUES=()
	if [ -n "$previous" ]; then
		range="$previous..HEAD"
	else
		range="HEAD"
	fi
	mapfile -t _REL_ISSUES < <(
		git log --no-merges --format='%s' "$range" 2>/dev/null \
			| grep -oE '#[1-9][0-9]*' | tr -d '#' | sort -un
	)
}

# '#4, #5, #6', for the lines that say which issues these are.
_rel_issue_refs() {
	local issue out=""
	for issue in "$@"; do
		[ -n "$out" ] && out="$out, "
		out="$out#$issue"
	done
	printf '%s\n' "$out"
}

# The number of the milestone with this title, over every milestone the
# repository has, open or closed; non-zero where there is none. The title is
# what a milestone is known by here - it is the tag - and GitHub will not take
# two alike, so the first match is the only one.
_rel_milestone_find() {
	local title="$1" number name
	while IFS=' ' read -r number name; do
		if [ "$name" = "$title" ]; then
			printf '%s\n' "$number"
			return 0
		fi
	done < <(gh api --paginate 'repos/:owner/:repo/milestones?state=all&per_page=100' \
		--jq '.[] | "\(.number) \(.title)"' 2>/dev/null)
	return 1
}

_rel_milestone_create() {
	local title="$1" description="$2"
	gh api --method POST repos/:owner/:repo/milestones \
		-f title="$title" -f description="$description" --jq '.number' 2>/dev/null
}

# Step 8: the milestone this release is, holding the issues it fixed.
#
# Everything here happens after the release is published and out of draft, so
# none of it is undoable and none of it is worth failing a made release over.
# A non-zero return says something was left undone, which the caller reports
# as a warning naming what to finish by hand - the release itself stands.
#
# 'close' is 0 for a draft: a draft has not shipped, so the milestone and the
# issues on it stay open until it does.
#
# Each issue is looked at before it is touched. A '#<n>' that no issue answers
# to is a pull request or a stray number, and is said rather than acted on; an
# issue already on another milestone was fixed by an earlier release and is
# left where it is. Neither is a failure, so neither sets the return.
_rel_milestone_apply() {
	local title="$1" close="$2"
	shift 2
	local number info issue state existing kind rc=0
	local -a put=()

	if number=$(_rel_milestone_find "$title"); then
		echo "Milestone $title is there already"
	elif number=$(_rel_milestone_create "$title" "The issues released as $title."); then
		echo "Created milestone $title"
	else
		echo "Error: milestone $title could not be created, so no issue was moved" >&2
		echo "       the issues this release fixed: $(_rel_issue_refs "$@")" >&2
		return 1
	fi

	for issue in "$@"; do
		# The REST issue, not 'gh issue view': that resolves a pull request
		# number as though it were an issue, and a '#<n>' in a subject naming
		# one would get a milestone put on the pull request and the pull
		# request closed. Only this endpoint says which of the two it is.
		if ! info=$(gh api "repos/:owner/:repo/issues/$issue" --jq \
			'"\(.state)\t\(.milestone.title // "")\t\(if .pull_request then "pr" else "issue" end)"' \
			2>/dev/null); then
			echo "Warning: no issue #$issue here, so it is not on $title" >&2
			continue
		fi
		# Cut by hand rather than with read: a tab is whitespace, so read
		# would fold the two of them together whenever the middle field, the
		# milestone an issue is already on, is the empty one.
		state=${info%%$'\t'*}
		kind=${info##*$'\t'}
		existing=${info#*$'\t'}
		existing=${existing%$'\t'*}

		if [ "$kind" = "pr" ]; then
			echo "Warning: #$issue is a pull request, not an issue; left alone" >&2
			continue
		fi
		if [ -n "$existing" ] && [ "$existing" != "$title" ]; then
			echo "Warning: #$issue is on milestone $existing already, left there" >&2
			continue
		fi
		if [ "$existing" != "$title" ] \
			&& ! gh issue edit "$issue" --milestone "$title" >/dev/null 2>&1; then
			echo "Error: #$issue could not be put on $title" >&2
			rc=1
			continue
		fi
		put+=("$issue")

		if [ "$close" = "1" ] && [ "$state" != "closed" ]; then
			if ! gh issue close "$issue" >/dev/null 2>&1; then
				echo "Error: #$issue is on $title but could not be closed" >&2
				rc=1
			fi
		fi
	done

	if [ ${#put[@]} -gt 0 ]; then
		if [ "$close" = "1" ]; then
			echo "Put $(_rel_issue_refs "${put[@]}") on $title and closed them"
		else
			echo "Put $(_rel_issue_refs "${put[@]}") on $title"
		fi
	fi

	if [ "$close" != "1" ]; then
		echo "Milestone $title not closed: the release is a draft"
		return $rc
	fi

	# Closed even where an issue above could not be: the release has shipped,
	# and the warning is the record of what is left.
	if ! gh api --method PATCH "repos/:owner/:repo/milestones/$number" \
		-f state=closed >/dev/null 2>&1; then
		echo "Error: milestone $title holds its issues but is still open" >&2
		echo "       close it with 'gh api --method PATCH \\" >&2
		echo "       repos/:owner/:repo/milestones/$number -f state=closed'" >&2
		rc=1
	else
		echo "Closed milestone $title"
	fi
	return $rc
}

# Expand the artifact globs. _REL_ASSETS comes back holding every file matched
# and _REL_MISSING the patterns that matched none; the return is non-zero if
# any pattern did. Only regular files count: a pattern matching a directory
# alone has not found the file it was written for.
#
# Each pattern has its placeholders filled in before it is expanded, so a
# pattern can name the release it is for instead of globbing over every release ever
# built. _REL_RESOLVED comes back holding "pattern -> resolved" for the ones
# that changed, which is what the dry run shows.
#
# An unmatched pattern is the failure worth stopping on. It is how a release
# ends up published without the Windows zip nobody noticed was missing.
_rel_expand_artifacts() {
	local version="$1" tag="$2"
	shift 2
	local pattern resolved candidate nullglob_was_set
	local -a patterns=("$@") matches
	_REL_ASSETS=()
	_REL_MISSING=()
	_REL_RESOLVED=()

	shopt -q nullglob && nullglob_was_set=1 || nullglob_was_set=0
	shopt -s nullglob
	# No word splitting while the patterns are expanded: one entry is one
	# pattern, and a path with a space in it would otherwise be split into two
	# names that match nothing. Pathname expansion still yields one field per
	# file it matches, which is the part being asked for.
	local ifs_was="$IFS"
	IFS=''
	for pattern in "${patterns[@]}"; do
		resolved=$(_rel_substitute_artifact_vars "$pattern" "$version" "$tag")
		[ "$resolved" = "$pattern" ] || _REL_RESOLVED+=("$pattern -> $resolved")
		matches=()
		# Unquoted on purpose: this is the pathname expansion being asked for.
		for candidate in $resolved; do
			[ -f "$candidate" ] && matches+=("$candidate")
		done
		if [ ${#matches[@]} -eq 0 ]; then
			_REL_MISSING+=("$resolved")
		else
			_REL_ASSETS+=("${matches[@]}")
		fi
	done
	IFS="$ifs_was"
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

# 'prel release artifacts': what the artifacts of prel.config.json match as
# the tree stands,
# and nothing besides. None of the release preconditions are checked here -
# the question is about files on disk, so answering it must not want a free
# tag, a remote, or a usable gh. Non-zero where a pattern matched nothing, so
# a build script can gate on it.
_rel_check_artifacts() {
	local version="" origin="" repo_root version_file tag build_command
	local ordinary rc=0

	while [ $# -gt 0 ]; do
		case "$1" in
			-*)
				echo "Error: Unknown option '$1' for release artifacts" >&2
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

	repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$repo_root" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$repo_root" || return 1

	# A config worth reporting on before it is read for an answer.
	_prel_config_ok_verbose || return 1

	# The patterns first: with none set, the version they would have been
	# filled in with is beside the point, and so is a missing version file.
	_rel_artifacts || return 1
	if [ ${#_REL_PATTERNS[@]} -eq 0 ]; then
		echo "artifacts is not set in prel.config.json: a release here is the tag"
		echo "and nothing else. Set it with, say:"
		echo ""
		echo '  { "artifacts": ["build/myapp-${version}.deb"] }'
		return 0
	fi

	if [ -n "$version" ]; then
		if ! _rel_is_version "$version"; then
			echo "Error: '$version' is not a version of three numbers (1.0.1, 1.0.1-rc1)" >&2
			return 1
		fi
		origin="given"
	else
		# What the file reads now stands in for the release about to be made.
		# Taken as it reads, not checked: this command reports, and a version
		# worth refusing is refused by the release itself.
		version_file=$(_rel_version_file)
		if [ ! -f "$version_file" ]; then
			echo "Error: no $version_file in $repo_root to take the version from" >&2
			echo "       pass one, as in 'prel release artifacts 1.0.1'" >&2
			return 1
		fi
		version=$(tr -d '[:space:]' < "$version_file")
		if [ -z "$version" ]; then
			echo "Error: $version_file is empty, so there is no version to fill in" >&2
			echo "       pass one, as in 'prel release artifacts 1.0.1'" >&2
			return 1
		fi
		origin="from $version_file"
	fi

	tag="$(_rel_tag_prefix)$version"
	echo "artifacts: $(_prel_list_line "${_REL_PATTERNS[@]}")"
	echo "version:   $version ($origin)"
	echo "tag:       $tag"
	echo ""

	# Copied aside: the expansion writes its answers into _REL_* arrays, and
	# _REL_PATTERNS is where it reads the patterns from.
	local -a patterns=("${_REL_PATTERNS[@]}")
	_rel_expand_artifacts "$version" "$tag" "${patterns[@]}"
	rc=$?

	if [ ${#_REL_RESOLVED[@]} -gt 0 ]; then
		echo "filled in:"
		printf '  %s\n' "${_REL_RESOLVED[@]}"
	fi
	if [ ${#_REL_ASSETS[@]} -gt 0 ]; then
		echo "would upload:"
		printf '  %s\n' "${_REL_ASSETS[@]}"
	fi
	if [ ${#_REL_MISSING[@]} -gt 0 ]; then
		echo "matched nothing:"
		printf '  %s\n' "${_REL_MISSING[@]}"
		_rel_placeholder_hint '  ' "${_REL_MISSING[@]}"
		# The usual reason, and the one this command cannot tell apart from a
		# wrong pattern: the build that writes those files has not run.
		build_command=$(_rel_build_command)
		if [ -n "$build_command" ]; then
			echo "  a release would build them first: $build_command"
		else
			ordinary=$(_prel_build_command)
			if [ -n "$ordinary" ]; then
				echo "  no releaseBuildCommand: a release builds nothing here. The"
				echo "  buildCommand this file sets is the build 'prel build' runs,"
				echo "  and not one a release runs"
			fi
		fi
	fi

	echo ""
	if [ "$rc" = "0" ]; then
		echo "${#_REL_ASSETS[@]} file(s) would go up with the release"
	else
		echo "${#_REL_MISSING[@]} pattern(s) matched nothing; a release would stop before the push"
	fi
	return $rc
}

release() {
	local version="" message="" dry_run=0 assume_yes=0 publish=1 draft=0
	local no_build=0 no_assets=0 milestone=1

	if [ "${1-usage}" = "usage" ]; then
		cat <<EOF
release - Move the VERSION file on, tag it, push it and publish the release

Usage:
  prel release usage              Show this help
  prel release artifacts          Say what the artifacts setting matches
  prel release artifacts <x.y.z>  The same, for a version not yet in the file
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
  prel release <x.y.z> --no-milestone
                                  Create no milestone, move no issue

Description:
  For a project that keeps its version in a VERSION file at its root, a
  release is that file moved on and the commit it was moved in made public.
  This does the steps in order, and stops at the first one that fails:

    1. write <x.y.z> into the VERSION file
    2. commit that file alone
    3. tag the commit, annotated, as v<x.y.z>
    4. build the artifacts, where releaseBuildCommand says how
    5. push the branch and the tag
    6. create the GitHub release, its notes the commits since the last tag
    7. upload the artifacts the artifacts setting names, then take the
       release out of draft now that it has them
    8. put the issues these commits fixed on a milestone named after the tag,
       creating it if it is not there, and close them and it

  Steps 4 and 7 happen only in a project that has asked for them, in its
  prel.config.json:

    {
      "releaseBuildCommand": "cmake --build build --target release",
      "artifacts": ["build/*.deb", "build-win/*.zip"]
    }

  releaseBuildCommand is the only build a release runs. buildCommand, the
  ordinary build of the project, is the one 'prel build' runs and is never
  run here; 'prel build --release' is how the release build gets tried
  without a release around it.

  'prel release artifacts' answers what those patterns match, without any of
  the above: no network, no gh, nothing written, nothing built. The version
  comes from the version file as it stands, or from the argument. It exits
  non-zero where a pattern matched no file, so a build script can gate on it.

  A pattern in artifacts can name the release it is for rather than glob over
  every release ever built: \${version} is the version and \${tag} the tag, as
  in "build/myapp-\${version}.deb". No shell is involved in a pattern - the two
  names are filled in by plain string replacement, and nothing else in it can
  run. releaseBuildCommand is a shell command, and sees the same two as
  \$version and \$tag. One artifacts entry is one pattern, so a path with a
  space in it is as expressible as any other.

  Step 8 reads the issues out of the commit subjects: 'prel issue-from-plans'
  puts '#<n> ' in front of each one, so the range that writes the notes names
  the issues too. A project whose commits name none gets no milestone, so
  there is nothing to opt into and --no-milestone to opt out. It is the last
  step and never fails a release that is already out: what it could not do it
  says, with the gh command to finish it. An issue already on another
  milestone is left there - an earlier release fixed it - and --draft creates
  the milestone and fills it but closes nothing, a draft not having shipped.

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

  The tag is v<x.y.z>, or the version alone where tagPrefix is set to an
  empty string. The file is VERSION, or the path in versionFile. All four of
  these settings are read from prel.config.json - see 'prel config'. The
  release commit is made with PREL_SKIP_ISSUE set, so it never consumes the
  sum-up that 'prel issue-from-plans' is holding for the next real commit.
EOF
		return 0
	fi

	# Not a release at all: the artifact patterns, looked at and nothing more.
	if [ "${1-}" = "artifacts" ]; then
		shift
		_rel_check_artifacts "$@"
		return $?
	fi

	while [ $# -gt 0 ]; do
		case "$1" in
			-n|--dry-run) dry_run=1 ;;
			-y|--yes) assume_yes=1 ;;
			--no-release) publish=0 ;;
			--no-build) no_build=1 ;;
			--no-assets) no_assets=1 ;;
			--no-milestone) milestone=0 ;;
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

	# A typo here becomes a tag, so it is worth refusing.
	if ! _rel_is_version "$version"; then
		echo "Error: '$version' is not a version of three numbers (1.0.1, 1.0.1-rc1)" >&2
		return 1
	fi

	local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$REPO_ROOT"

	# Before a word of it is believed. A key prel does not know or a value of
	# the wrong shape stops the release here, where nothing has happened yet -
	# the shape of this file is known, unlike git config, where any key was a
	# valid key. A stale prel.* git config key is a warning and passes.
	if ! _prel_config_ok_verbose; then
		echo "Error: prel.config.json is not usable, so nothing was released" >&2
		return 1
	fi

	local version_file current
	version_file=$(_rel_version_file)
	if [ ! -f "$version_file" ]; then
		echo "Error: no $version_file in $REPO_ROOT, nothing to release" >&2
		echo "       a project keeping its version elsewhere sets versionFile" >&2
		echo "       in prel.config.json" >&2
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
	local build_command build=0 assets=0
	build_command=$(_rel_build_command)
	_rel_artifacts || return 1
	local -a patterns=("${_REL_PATTERNS[@]}")
	[ -n "$build_command" ] && build=1
	[ ${#patterns[@]} -gt 0 ] && assets=1
	[ "$no_build" = "1" ] && build=0
	if [ "$no_assets" = "1" ] || [ "$publish" = "0" ]; then
		assets=0
		build=0
	fi
	# Nothing published means no milestone to put the issues on either.
	[ "$publish" = "1" ] || milestone=0

	# The previous tag, and with it the commits this release carries: the
	# release notes are their subjects and the milestone is the issues those
	# subjects name. Read from the history as it stands, before the release
	# commit, which carries no change of its own worth listing.
	local previous
	previous=$(git describe --tags --abbrev=0 2>/dev/null) || previous=""
	_rel_issues_in_range "$previous"
	# A project not using the convention names no issue in any range, and gets
	# no empty milestone per release for it.
	[ ${#_REL_ISSUES[@]} -gt 0 ] || milestone=0

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
		echo "build:        nothing, releaseBuildCommand not run"
	else
		# A project whose config names the ordinary build and no release build
		# is told which of the two a release reads, here where it is about to
		# not run one. 0.2.3 called the release build buildCommand, and a
		# config written then would otherwise release with no build at all.
		local ordinary
		ordinary=$(_prel_build_command)
		if [ -n "$ordinary" ]; then
			echo "build:        nothing, releaseBuildCommand not set"
			echo "              (buildCommand is the build 'prel build' runs,"
			echo "              and not one a release runs)"
		fi
	fi
	if [ "$assets" = "1" ]; then
		echo "artifacts:    $(_prel_list_line "${patterns[@]}")"
	elif [ ${#patterns[@]} -gt 0 ]; then
		echo "artifacts:    nothing, the artifacts of prel.config.json not uploaded"
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
	if [ "$milestone" = "1" ] && [ "$draft" = "1" ]; then
		echo "milestone:    $tag, $(_rel_issue_refs "${_REL_ISSUES[@]}") (draft, closes nothing)"
	elif [ "$milestone" = "1" ]; then
		echo "milestone:    $tag, $(_rel_issue_refs "${_REL_ISSUES[@]}") closed with it"
	elif [ "$publish" = "1" ] && [ ${#_REL_ISSUES[@]} -gt 0 ]; then
		echo "milestone:    nothing, --no-milestone"
	elif [ "$publish" = "1" ]; then
		echo "milestone:    nothing, no issue named since ${previous:-the first commit}"
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

	local notes_file

	if [ "$dry_run" = "1" ]; then
		echo "--- $version_file ------------------------------------------------------"
		echo "$version"
		if [ "$assets" = "1" ]; then
			echo "--- artifacts ----------------------------------------------------------"
			_rel_expand_artifacts "$version" "$tag" "${patterns[@]}"
			if [ ${#_REL_RESOLVED[@]} -gt 0 ]; then
				echo "filled in:"
				printf '  %s\n' "${_REL_RESOLVED[@]}"
			fi
			[ ${#_REL_ASSETS[@]} -gt 0 ] && printf '%s\n' "${_REL_ASSETS[@]}"
			[ ${#_REL_MISSING[@]} -gt 0 ] \
				&& printf '%s  (matches nothing as the tree stands)\n' "${_REL_MISSING[@]}"
			if [ "$build" = "1" ]; then
				echo "(the build runs before this is checked, so it may yet produce them)"
			fi
		fi
		if [ "$milestone" = "1" ]; then
			echo "--- milestone ----------------------------------------------------------"
			if _rel_milestone_find "$tag" >/dev/null; then
				echo "$tag (there already)"
			else
				echo "$tag (would be created)"
			fi
			echo "issues: $(_rel_issue_refs "${_REL_ISSUES[@]}")"
			if [ "$draft" = "1" ]; then
				echo "(a draft closes nothing: neither the issues nor the milestone)"
			else
				echo "(the issues and the milestone would be closed)"
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
		# Through build.sh, which is where 'prel build' runs it too: the
		# command sees $version and $tag as shell variables, and that being
		# documented is reason enough for the two not to expand it each.
		if ! _prel_build_eval "$version" "$tag" "$build_command"; then
			echo ""
			echo "Error: the build failed, so there is no release to make" >&2
			_rel_undo_and_report "$tag" "$version_file" "$backup" "$current"
			return 1
		fi
		echo ""
	fi

	if [ "$assets" = "1" ]; then
		if ! _rel_expand_artifacts "$version" "$tag" "${patterns[@]}"; then
			echo "Error: these artifacts of prel.config.json matched no file:" >&2
			printf '       %s\n' "${_REL_MISSING[@]}" >&2
			_rel_placeholder_hint '       ' "${_REL_MISSING[@]}" >&2
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

	# Last, with the release out and nothing left to undo: the milestone the
	# issues of this release belong on. A draft closes nothing - it has not
	# shipped - and trouble here is a warning rather than a failed release,
	# since the release is made whatever the milestone says.
	if [ "$milestone" = "1" ]; then
		echo ""
		local close_milestone=1
		[ "$draft" = "1" ] && close_milestone=0
		if ! _rel_milestone_apply "$tag" "$close_milestone" "${_REL_ISSUES[@]}"; then
			echo "Warning: $tag is released; it is the milestone above that is" >&2
			echo "         unfinished - 'gh issue edit <n> --milestone $tag' and" >&2
			echo "         'gh issue close <n>' are what is left" >&2
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

# If this script is run directly (not sourced), call the function. Sourced
# from prel.sh the shared config reader is already loaded; run directly, this
# has to load it itself - sourcing it only defines its functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_rel_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	for _rel_sibling in config.sh build.sh; do
		# shellcheck source=/dev/null
		[ -r "$_rel_dir/$_rel_sibling" ] && source "$_rel_dir/$_rel_sibling"
	done
	release "$@"
fi
