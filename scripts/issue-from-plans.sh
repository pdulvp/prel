#!/usr/bin/env bash
# issue-from-plans.sh - File the completed work plans as a GitHub issue at commit time
#
# Can be run directly or sourced from prel.sh
# Usage: prel issue-from-plans [usage|status|dry-run]
#        OR: ./scripts/issue-from-plans.sh [usage|status|dry-run]
# Shortcut: prel issues [usage|status|dry-run]
#
# The actions prepare-msg, subject and stamp are called by the prel hooks and
# are not meant to be typed.

# Shortcut function - issues is an alias for issue_from_plans
issues() {
	issue_from_plans "$@"
}

# Where the plans live. A repository that keeps them elsewhere sets
# prel.plansDir in its own git config.
_ifp_plans_dir() {
	local dir
	dir=$(git config --get prel.plansDir 2>/dev/null) || dir=""
	[ -n "$dir" ] || dir="docs/plans"
	printf '%s\n' "$dir"
}

# The issue created for a commit that has not been made yet. Lives in .git so
# it is per-worktree and never committed.
_ifp_cache_file() {
	local git_dir
	git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1
	printf '%s/prel-pending-issue\n' "$git_dir"
}

_ifp_cache_get() {
	local cache
	cache=$(_ifp_cache_file) || return 1
	[ -f "$cache" ] || return 1
	sed -n "s/^$1=//p" "$cache" | head -1
}

# What git treats as a comment in the message file, so the hint prel leaves for
# the editor really is dropped from the commit.
_ifp_comment_char() {
	local cc
	cc=$(git config --get core.commentChar 2>/dev/null) || cc=""
	# 'auto' makes git pick a char for the template it wrote; the one it picked
	# is not readable from here and '#' is what it uses unless the message
	# already starts with one.
	[ -n "$cc" ] && [ "$cc" != "auto" ] || cc="#"
	printf '%s\n' "${cc:0:1}"
}

# How git will clean the message up once every hook has had its say - the
# cleanup happens after commit-msg, not before, so this is what decides whether
# a '#12' subject reaches the commit or is dropped as a comment.
_ifp_cleanup_mode() {
	local mode
	mode=$(git config --get commit.cleanup 2>/dev/null) || mode=""
	if [ -z "$mode" ] || [ "$mode" = "default" ]; then
		# git strips comments when it opens an editor, and only trims
		# whitespace when the message was given on the command line.
		case "${1-}" in
			message) mode="whitespace" ;;
			*) mode="strip" ;;
		esac
	fi
	printf '%s\n' "$mode"
}

# Whether a subject may start with the comment character under that mode.
_ifp_cleanup_keeps_hash() {
	case "$1" in
		whitespace|scissors|verbatim) return 0 ;;
		*) return 1 ;;
	esac
}

# The front matter of a plan: the lines between the opening --- and the next one.
_ifp_front_matter() {
	awk 'NR==1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
	     /^---[[:space:]]*$/ { exit }
	     { print }' "$1"
}

_ifp_fm_value() {
	_ifp_front_matter "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -1
}

_ifp_is_complete() {
	local status
	status=$(_ifp_fm_value "$1" status | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
	[ "$status" = "complete" ]
}

_ifp_is_linked() {
	[ -n "$(_ifp_fm_value "$1" issue)" ]
}

# Strip the leading and trailing blank lines of a block of markdown.
_ifp_trim_blank() {
	awk '{ line[NR] = $0 }
	     END {
	       s = 1; while (s <= NR && line[s] ~ /^[[:space:]]*$/) s++
	       e = NR; while (e >= s && line[e] ~ /^[[:space:]]*$/) e--
	       for (i = s; i <= e; i++) print line[i]
	     }'
}

# A plan without its front matter and without its H1: the title is reused as the
# heading of the plan's section in the issue.
_ifp_plan_body() {
	awk 'NR == 1 && /^---[[:space:]]*$/ { fm = 1; next }
	     fm && !fm_done { if ($0 ~ /^---[[:space:]]*$/) fm_done = 1; next }
	     !h1 && /^#[[:space:]]/ { h1 = 1; next }
	     { print }' "$1" | _ifp_trim_blank
}

_ifp_plan_title() {
	local title
	title=$(sed -n 's/^#[[:space:]]\+//p' "$1" | head -1)
	[ -n "$title" ] || title=$(basename "$1" .md)
	# Drop a leading "Plan - " label: the issue section says that already.
	printf '%s\n' "$title" | sed -e 's/^[Pp]lan[[:space:]]*[—–-][[:space:]]*//'
}

# Completed plans no issue has been filed for yet, oldest first - the dated
# archive names sort chronologically on their own.
_ifp_pending_plans() {
	local dir="$1" file base
	for file in "$dir"/*.md; do
		[ -f "$file" ] || continue
		base=$(basename "$file")
		case "$base" in
			README.md|sumup.md) continue ;;
		esac
		_ifp_is_complete "$file" || continue
		if _ifp_is_linked "$file"; then continue; fi
		printf '%s\n' "$file"
	done | LC_ALL=C sort
}

# The H1 of sumup.md: the issue title and the commit subject.
_ifp_sumup_title() {
	sed -n 's/^#[[:space:]]\+//p' "$1" | head -1
}

# Everything under that H1: the commit body and the issue's lead.
_ifp_sumup_lead() {
	awk '!seen && /^#[[:space:]]/ { seen = 1; next } seen { print }' "$1" | _ifp_trim_blank
}

_ifp_issue_body() {
	local sumup="$1"
	shift
	local file title updated

	_ifp_sumup_lead "$sumup"

	for file in "$@"; do
		title=$(_ifp_plan_title "$file")
		updated=$(_ifp_fm_value "$file" updated)
		printf '\n\n## %s\n\n' "$title"
		if [ -n "$updated" ]; then
			printf '<sub>`%s` — %s</sub>\n\n' "$(basename "$file")" "$updated"
		else
			printf '<sub>`%s`</sub>\n\n' "$(basename "$file")"
		fi
		_ifp_plan_body "$file"
	done

	printf '\n\n<sub>Filed by prel from the completed plans at commit time.</sub>\n'
}

# The subject of the message as it stands: its first line that is neither blank
# nor one of git's comments. A '#12 ...' line is a subject prel wrote, not a
# comment - which is the whole reason commit.cleanup has to be scissors.
_ifp_msg_subject() {
	local cc
	cc=$(_ifp_comment_char)
	awk -v cc="$cc" '
		!NF { next }
		substr($0, 1, 1) == cc && $0 !~ /^#[0-9]+/ { next }
		{ print; exit }
	' "$1" 2>/dev/null
}

# Empty means git is offering a blank template and prel is free to write the
# abstract into it.
_ifp_msg_has_content() {
	[ -n "$(_ifp_msg_subject "$1")" ]
}

# A subject already carrying an issue number is left alone: this is what keeps
# 'prel recommit-last', which replays messages back through the hook, and
# 'git commit --amend' from filing the same work twice.
_ifp_is_prefixed() {
	[[ "$1" =~ ^#[0-9]+ ]]
}

# Put '#<n> ' in front of the subject. Only an existing subject line is touched:
# a message left empty must stay empty, so that git aborts the commit the way it
# would without prel.
_ifp_prefix_subject() {
	local msg_file="$1" number="$2" cc tmp
	cc=$(_ifp_comment_char)
	tmp=$(mktemp) || return 1
	awk -v n="$number" -v cc="$cc" '
		!done && NF && substr($0, 1, 1) != cc { print "#" n " " $0; done = 1; next }
		{ print }
	' "$msg_file" > "$tmp" && mv "$tmp" "$msg_file" || { rm -f "$tmp"; return 1; }
}

_ifp_github_remote() {
	local url
	url=$(git remote get-url --push origin 2>/dev/null) || url=""
	[ -n "$url" ] || url=$(git remote get-url --push "$(git remote | head -1)" 2>/dev/null) || url=""
	case "$url" in
		*github.com*) printf '%s\n' "$url" ;;
		*) return 1 ;;
	esac
}

# ----------------------------------------------------------------------------
# prepare-commit-msg: file the issue, write the abstract into the message
# ----------------------------------------------------------------------------
_ifp_prepare_msg() {
	local msg_file="$1" source="${2-}"

	[ -n "$msg_file" ] && [ -f "$msg_file" ] || return 0
	[ -z "${PREL_SKIP_ISSUE:-}" ] || return 0

	# A merge or a squash message is not this repository's work to file.
	case "$source" in
		merge|squash) return 0 ;;
	esac

	local dir sumup
	dir=$(_ifp_plans_dir)
	sumup="$dir/sumup.md"

	# sumup.md is the trigger: no sum-up, no issue, ordinary commit. This is
	# what keeps the hook inert in every repository that has no plans.
	[ -s "$sumup" ] || return 0

	local title
	title=$(_ifp_sumup_title "$sumup")
	if [ -z "$title" ]; then
		echo "prel: $sumup has no '# title' line, no issue filed" >&2
		return 0
	fi

	_ifp_is_prefixed "$(_ifp_msg_subject "$msg_file")" && return 0

	# Nothing is filed when git would strip the number back off the subject:
	# the link is the point, and a half-filed issue is worse than none.
	local mode
	mode=$(_ifp_cleanup_mode "$source")
	if ! _ifp_cleanup_keeps_hash "$mode"; then
		echo "prel: commit.cleanup is '$mode', which drops a '#number' subject as a comment" >&2
		echo "prel: run 'prel init-authored-hooks register' to set it to scissors, nothing filed ($sumup kept)" >&2
		return 0
	fi

	if ! command -v gh >/dev/null 2>&1; then
		echo "prel: gh not found, committing without filing an issue ($sumup kept)" >&2
		return 0
	fi
	if ! _ifp_github_remote >/dev/null; then
		echo "prel: no github remote, committing without filing an issue ($sumup kept)" >&2
		return 0
	fi

	local -a plans=()
	local line
	while IFS= read -r line; do
		[ -n "$line" ] && plans+=("$line")
	done < <(_ifp_pending_plans "$dir")

	if [ ${#title} -gt 70 ]; then
		echo "prel: the title in $sumup is ${#title} chars, longer than the 70 a subject should keep" >&2
	fi

	local body_file
	body_file=$(mktemp) || return 0
	_ifp_issue_body "$sumup" "${plans[@]}" > "$body_file"

	local cache number url
	cache=$(_ifp_cache_file) || { rm -f "$body_file"; return 0; }
	number=$(_ifp_cache_get issue) || number=""

	if [ -n "$number" ]; then
		# An issue was already filed for a commit that did not happen - the
		# editor was quit, or a later hook refused the commit. Reuse it rather
		# than leave it orphaned, with whatever the sum-up says now.
		url=$(_ifp_cache_get url)
		if ! gh issue edit "$number" --title "$title" --body-file "$body_file" >/dev/null 2>&1; then
			echo "prel: could not update pending issue #$number, reusing it as it stands" >&2
		fi
	else
		local created
		if ! created=$(gh issue create --title "$title" --body-file "$body_file" 2>&1); then
			echo "prel: gh issue create failed, committing without filing an issue ($sumup kept)" >&2
			echo "$created" | sed -e 's/^/prel: /' >&2
			rm -f "$body_file"
			return 0
		fi
		url=$(printf '%s\n' "$created" | sed -n 's#.*\(https://[^ ]*/issues/[0-9]\+\).*#\1#p' | tail -1)
		number=${url##*/}
		if ! [[ "$number" =~ ^[0-9]+$ ]]; then
			echo "prel: could not read an issue number out of gh's answer, committing without a link" >&2
			echo "$created" | sed -e 's/^/prel: /' >&2
			rm -f "$body_file"
			return 0
		fi
	fi
	rm -f "$body_file"

	# Remember the issue until a commit actually carries it: the number is added
	# to the subject by the commit-msg hook and the plans are stamped by
	# post-commit, both out of this file.
	{
		printf 'issue=%s\n' "$number"
		printf 'url=%s\n' "$url"
		printf 'title=%s\n' "$title"
		local plan
		for plan in "${plans[@]}"; do
			printf 'plan=%s\n' "$plan"
		done
	} > "$cache"

	# Write the abstract as the message, unless something is already there: an
	# explicit -m, -F or --amend message is the user's, and only gets the issue
	# number prefixed to it.
	if ! _ifp_msg_has_content "$msg_file"; then
		local tmp
		tmp=$(mktemp) || return 0
		{
			printf '%s\n' "$title"
			local lead
			lead=$(_ifp_sumup_lead "$sumup")
			[ -n "$lead" ] && printf '\n%s\n' "$lead"
			printf '\n'
			cat "$msg_file"
		} > "$tmp"
		mv "$tmp" "$msg_file"
	fi

	# The number leads the subject, so an editor shows the message as it will be
	# committed. The commit-msg hook puts it back should it be edited away.
	_ifp_prefix_subject "$msg_file" "$number"

	# Where the commit is going, for an editor session. Below the scissors line,
	# so it never reaches the message - which is also why it is only written
	# under the one cleanup mode that has such a line.
	if [ "$mode" = "scissors" ] && [ "$source" != "message" ]; then
		local cc
		cc=$(_ifp_comment_char)
		printf '%s prel: filed as issue #%s - %s\n' "$cc" "$number" "$url" >> "$msg_file"
	fi

	return 0
}

# ----------------------------------------------------------------------------
# commit-msg: put the issue number in front of the subject
# ----------------------------------------------------------------------------
_ifp_subject() {
	local msg_file="$1"

	[ -n "$msg_file" ] && [ -f "$msg_file" ] || return 0
	[ -z "${PREL_SKIP_ISSUE:-}" ] || return 0

	local number
	number=$(_ifp_cache_get issue) || return 0
	[[ "$number" =~ ^[0-9]+$ ]] || return 0

	_ifp_is_prefixed "$(_ifp_msg_subject "$msg_file")" && return 0

	_ifp_prefix_subject "$msg_file" "$number"

	return 0
}

# ----------------------------------------------------------------------------
# post-commit: stamp the plans, consume the sum-up
# ----------------------------------------------------------------------------
_ifp_stamp_plan() {
	local file="$1" number="$2" tmp
	tmp=$(mktemp) || return 1
	awk -v n="$number" '
		NR == 1 && /^---[[:space:]]*$/ { print; fm = 1; next }
		fm && !fm_done && /^---[[:space:]]*$/ { print "issue: " n; print; fm_done = 1; next }
		{ print }
	' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

_ifp_stamp() {
	local cache number
	cache=$(_ifp_cache_file) || return 0
	[ -f "$cache" ] || return 0
	number=$(_ifp_cache_get issue) || return 0
	[[ "$number" =~ ^[0-9]+$ ]] || return 0

	# Only consume the sum-up once a commit really carries the issue: a commit
	# made with --no-verify, or one the commit-msg hook left alone, leaves the
	# pending issue for the next one.
	local subject
	subject=$(git log -1 --format=%s 2>/dev/null) || return 0
	case "$subject" in
		"#$number"|"#$number "*) ;;
		*) return 0 ;;
	esac

	local dir plan url
	dir=$(_ifp_plans_dir)
	url=$(_ifp_cache_get url)
	while IFS= read -r plan; do
		[ -n "$plan" ] && [ -f "$plan" ] || continue
		_ifp_is_linked "$plan" && continue
		_ifp_stamp_plan "$plan" "$number" || echo "prel: could not stamp issue #$number into $plan" >&2
	done < <(sed -n 's/^plan=//p' "$cache")

	rm -f "$dir/sumup.md"
	rm -f "$cache"
	echo "prel: filed as issue #$number - $url"
	return 0
}

# ----------------------------------------------------------------------------
# status / dry-run
# ----------------------------------------------------------------------------
_ifp_report() {
	local render="$1"
	local dir sumup
	dir=$(_ifp_plans_dir)
	sumup="$dir/sumup.md"

	echo "plans directory: $dir"

	local number url
	number=$(_ifp_cache_get issue) || number=""
	if [ -n "$number" ]; then
		url=$(_ifp_cache_get url)
		echo "pending issue:   #$number ($url) - filed, waiting for a commit to carry it"
	fi

	if [ ! -d "$dir" ]; then
		echo "nothing to file:  no $dir in this repository"
		return 0
	fi

	local -a plans=()
	local line
	while IFS= read -r line; do
		[ -n "$line" ] && plans+=("$line")
	done < <(_ifp_pending_plans "$dir")

	if [ ${#plans[@]} -eq 0 ]; then
		echo "completed plans: none without an issue"
	else
		echo "completed plans not linked to an issue:"
		for line in "${plans[@]}"; do
			echo "  - $line ($(_ifp_plan_title "$line"))"
		done
	fi

	if [ ! -s "$sumup" ]; then
		echo "sum-up:          $sumup is missing, so the next commit files nothing"
		if [ ${#plans[@]} -gt 0 ]; then
			echo "                 write it to file those plans (see the plan-summary skill)"
		fi
		return 0
	fi

	local title
	title=$(_ifp_sumup_title "$sumup")
	if [ -z "$title" ]; then
		echo "sum-up:          $sumup has no '# title' line, so the next commit files nothing"
		return 0
	fi

	echo "sum-up:          $sumup"
	echo "issue title:     $title (${#title} chars)"
	command -v gh >/dev/null 2>&1 || echo "warning:         gh not found, the next commit will not file anything"
	_ifp_github_remote >/dev/null || echo "warning:         no github remote, the next commit will not file anything"

	local mode
	mode=$(_ifp_cleanup_mode "")
	if ! _ifp_cleanup_keeps_hash "$mode"; then
		echo "warning:         commit.cleanup is '$mode', which drops a '#number' subject"
		echo "                 run 'prel init-authored-hooks register' to set it to scissors"
	fi

	if [ "$render" != "1" ]; then
		echo ""
		echo "'prel issue-from-plans dry-run' shows the issue and the message in full."
		return 0
	fi

	local n="${number:-<new>}"
	echo ""
	echo "--- commit message -----------------------------------------------------"
	printf '#%s %s\n' "$n" "$title"
	local lead
	lead=$(_ifp_sumup_lead "$sumup")
	[ -n "$lead" ] && printf '\n%s\n' "$lead"
	echo "--- issue #$n: $title -------------------------------------------------"
	_ifp_issue_body "$sumup" "${plans[@]}"
	echo "------------------------------------------------------------------------"
	return 0
}

issue_from_plans() {
	local action="${1-usage}"

	if [ "$action" = "usage" ]; then
		cat <<EOF
issue-from-plans - File the completed work plans as a GitHub issue at commit time

Usage:
  prel issue-from-plans usage       Show this help
  prel issue-from-plans status      Show what the next commit would file
  prel issue-from-plans dry-run     Show the issue and the message in full

Description:
  On commit, the prel hooks file the plans under docs/plans/ that are marked
  'status: complete' and carry no 'issue:' field yet as one GitHub issue, and
  put the issue number in front of the commit subject:

    #12 Paquetage Windows: zip avec les DLL de Qt

  One issue covers the whole batch: its body is the sum-up followed by one
  section per plan. The plans themselves stay out of git - the issue is what
  remains of them.

  docs/plans/sumup.md is the trigger and supplies the wording. Its '# title'
  line becomes the issue title and the commit subject, and what follows becomes
  the commit body and the issue's lead. Without that file nothing is filed and
  the commit is an ordinary one, so the hooks stay inert in repositories that
  keep no plans. The plan-summary skill is the format it follows; install it
  with 'prel skills register'.

  Once a commit carries the issue, the plans are stamped with 'issue: <n>' and
  sumup.md is deleted: its content lives in the issue from then on.

  A subject that already starts with an issue number is left alone, so
  'prel recommit-last' and 'git commit --amend' do not file the same work
  twice. An issue filed for a commit that never happened is remembered in
  .git/prel-pending-issue and reused by the next commit instead of being left
  orphaned.

  Nothing here can stop a commit: a missing gh, an unauthenticated gh, no
  GitHub remote or a failing API call are reported on stderr and the commit is
  made without a link, with sumup.md left in place for the next attempt.
  PREL_SKIP_ISSUE=1 git commit skips the whole thing, and so does
  'git commit --no-verify'.

  A '#12' subject only survives under commit.cleanup=scissors, which
  'prel init-authored-hooks register' sets: git applies its cleanup after the
  hooks have run, and under the default mode it drops every line starting with
  the comment character - the subject included. Where the setting is missing,
  nothing is filed and the reason is printed.

  The plans are read from docs/plans, or from the path in the prel.plansDir git
  config of the repository.
EOF
		return 0
	fi

	local REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
	if [ -z "$REPO_ROOT" ]; then
		echo "Error: Not in a git repository" >&2
		return 1
	fi
	cd "$REPO_ROOT"

	case "$action" in
		status)
			_ifp_report 0
			;;
		dry-run|dry_run|-n)
			_ifp_report 1
			;;
		prepare-msg)
			shift
			_ifp_prepare_msg "$@"
			;;
		subject)
			shift
			_ifp_subject "$@"
			;;
		stamp)
			_ifp_stamp
			;;
		*)
			echo "Error: Unknown action '$action' for issue-from-plans" >&2
			echo "Try: prel issue-from-plans usage" >&2
			return 1
			;;
	esac
}

# If this script is run directly (not sourced), call the function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	issue_from_plans "$@"
fi
