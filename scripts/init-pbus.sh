#!/usr/bin/env bash
# init-pbus.sh - Declare the pbus event a published release emits
#
# Can be run directly or sourced from prel.sh
# Usage: sudo prel init-pbus [usage|register|unregister|status]
#        OR: sudo ./scripts/init-pbus.sh [usage|register|unregister|status]
#
# There is deliberately no 'pbus' shortcut here, the way 'prel skills' is a
# shortcut for 'prel init-skills': prel.sh sources every scripts/*.sh into one
# shell, so a function named pbus would shadow the pbus binary for the rest of
# that shell - including the 'pbus emit' a release ends on.

# The event, and the shape of the payload it carries. The payload is the
# version being released, which is why the pattern is the one _rel_is_version
# accepts: the daemon then refuses anything else before a listener is started,
# and a listener can use "$PBUS_PAYLOAD" as a version without checking it.
_PREL_PBUS_EVENT="prel.release.published"
_PREL_PBUS_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
_PREL_PBUS_DESC="A prel release has been published"

# Where pbus keeps its configuration, and the keyring of whoever is asking -
# the same two answers the pbus CLI gives itself, so what is reported here is
# the file 'pbus emit' will actually read.
_ipb_etc() {
	printf '%s\n' "${PBUS_ETC:-/etc/pbus}"
}

_ipb_keyring() {
	if [ -n "${PBUS_KEYSTORE:-}" ]; then
		printf '%s\n' "$PBUS_KEYSTORE"
	elif [ "$(id -u)" -eq 0 ]; then
		printf '%s/keys\n' "$(_ipb_etc)"
	else
		printf '%s/pbus/keys\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
	fi
}

_ipb_have_pbus() {
	command -v pbus >/dev/null 2>&1
}

# Whether the machine knows the event. 'pbus show-event' exits non-zero on an
# event it has never heard of, which is the check a release makes before it
# emits anything.
_ipb_event_known() {
	pbus show-event "$_PREL_PBUS_EVENT" >/dev/null 2>&1
}

# An event declared --no-key accepts any local emission, and then there is no
# keyring to report on. prel never declares one that way, but the event is a
# file anyone with root can write, so what is there is what gets reported.
_ipb_event_wants_key() {
	pbus show-event "$_PREL_PBUS_EVENT" 2>/dev/null \
		| grep -q '^key required: *no$' && return 1
	return 0
}

# The payload pattern the event carries, if any. show-event does not print it;
# 'pbus test' does, being the command that answers what an emission would do.
_ipb_event_pattern() {
	pbus test "$_PREL_PBUS_EVENT" 2>/dev/null \
		| sed -n 's/^[[:space:]]*payload must match[[:space:]]*//p' | head -1
}

# The file the event lives in, as pbus reports it: the one to append a line to
# where something has to be changed without drawing a new key.
_ipb_event_file() {
	pbus show-event "$_PREL_PBUS_EVENT" 2>/dev/null \
		| sed -n 's/^file[[:space:]]*:[[:space:]]*//p' | head -1
}

_ipb_no_pbus_message() {
	echo "Error: pbus not found in PATH" >&2
	echo "       pbus is the event dispatcher a published release emits to;" >&2
	echo "       prel works without it, and this command is what declares the" >&2
	echo "       event once pbus is installed" >&2
}

# register and unregister write under /etc/pbus. Said here rather than left to
# pbus, so the answer names the command to run instead of the directory.
_ipb_need_root() {
	local action="$1"
	[ "$(id -u)" -eq 0 ] && return 0
	[ -w "$(_ipb_etc)" ] && return 0
	echo "Error: '$action' writes $(_ipb_etc), so it wants root" >&2
	echo "       sudo prel init-pbus $action" >&2
	return 1
}

# Hand the key to the account that called sudo. register-event --save puts it
# in root's keyring, and root is not who runs 'prel release': the emit happens
# as an ordinary user, who would otherwise have no key to present. Done through
# 'pbus save-key' rather than by writing the file, so the path stays pbus's to
# decide.
_ipb_save_key_for_caller() {
	local key="$1" user="${SUDO_USER:-}" home path
	[ -n "$key" ] || return 1
	[ -n "$user" ] && [ "$user" != "root" ] || return 1

	home=$(getent passwd "$user" | cut -d: -f6)
	[ -n "$home" ] && [ -d "$home" ] || return 1

	local -a as_user=()
	if command -v runuser >/dev/null 2>&1; then
		as_user=(runuser -u "$user" --)
	elif command -v sudo >/dev/null 2>&1; then
		as_user=(sudo -n -u "$user" --)
	else
		return 1
	fi

	# HOME named explicitly: the keyring hangs off it, and sudo leaves root's
	# behind. PBUS_KEYSTORE unset so that an override meant for this shell is
	# not written into somebody's home.
	path=$(printf '%s\n' "$key" | "${as_user[@]}" \
		env -u PBUS_KEYSTORE HOME="$home" pbus save-key "$_PREL_PBUS_EVENT" 2>/dev/null \
		| sed -n 's/^Key saved to //p') || return 1
	[ -n "$path" ] || return 1
	printf '%s\t%s\n' "$user" "$path"
}

init_pbus() {
	local action="${1-usage}"

	if [ "$action" = "usage" ]; then
		cat <<EOF
init-pbus - Declare the pbus event a published release emits

Usage:
  prel init-pbus usage           Show this help
  sudo prel init-pbus register   Declare $_PREL_PBUS_EVENT
  sudo prel init-pbus unregister Remove it
  prel init-pbus status          Show what a release here would emit

Description:
  pbus is an event dispatcher: a command registers against an event name and
  the daemon launches it when that event is emitted. 'prel release' emits
  $_PREL_PBUS_EVENT once a release is really out, with the version
  as the payload, so that a site rebuild or a notification happens without the
  release waiting for it.

  register declares the event, keeps the key in root's keyring and hands a
  copy to the account that called sudo - that account is the one that runs
  'prel release', and an emission without a key is refused. It is machine-wide
  and once and for all, unlike 'prel init', which registers what belongs to a
  repository.

  An event already declared is left exactly as it is: declaring it again would
  draw a new key and silently break whoever already holds the old one. Use
  'sudo pbus rotate-key $_PREL_PBUS_EVENT --save' when that is
  what you want.

  Subscribing to the event is pbus's own business, not prel's:

    sudo pbus register-listener $_PREL_PBUS_EVENT --id notify \\
         -u root 'pbus-notify -u \$USER "prel \$PBUS_PAYLOAD published"'

  Nothing about pbus can stop a release. The emit is the last step, after the
  release is published: pbus missing or the event undeclared is silence, and a
  daemon that is not running or a key that cannot be found is a warning naming
  the 'pbus emit' to run by hand. That is also why the package recommends pbus
  rather than depending on it.

  The event carries the version and nothing else - 0.2.7, not v0.2.7 - and it
  is declared with a payload pattern of that shape, so a listener may read
  "\$PBUS_PAYLOAD" as a version: the daemon refuses anything else before the
  listener starts.
EOF
		return 0
	fi

	case "$action" in
		register)
			_ipb_have_pbus || { _ipb_no_pbus_message; return 1; }

			# Asked before the root check: an event already there is an answer
			# this command can give without being root, and the answer is that
			# there is nothing to write.
			if _ipb_event_known; then
				echo "Event already declared: $_PREL_PBUS_EVENT"
				echo ""
				pbus show-event "$_PREL_PBUS_EVENT"
				echo ""
				echo "Left as it is: declaring it again would draw a new key and"
				echo "break whoever holds the old one. To replace the key:"
				echo "  sudo pbus rotate-key $_PREL_PBUS_EVENT --save"

				# An event declared by hand, or by an older prel, may carry no
				# payload pattern. Worth saying, since the pattern is what
				# lets a listener read "$PBUS_PAYLOAD" as a version.
				local pattern event_file
				pattern=$(_ipb_event_pattern)
				if [ -z "$pattern" ]; then
					event_file=$(_ipb_event_file)
					echo ""
					echo "It declares no payload pattern, so the daemon accepts any payload."
				fi
				return 0
			fi

			_ipb_need_root register || return 1

			local out
			if ! out=$(pbus register-event "$_PREL_PBUS_EVENT" \
				-d "$_PREL_PBUS_DESC" \
				--payload-pattern "$_PREL_PBUS_PATTERN" \
				--save 2>&1); then
				echo "Error: pbus could not declare $_PREL_PBUS_EVENT" >&2
				printf '%s\n' "$out" | sed -e 's/^/       /' >&2
				return 1
			fi

			# The key is shown once and nowhere else, so it is read out of
			# that output rather than printed again here: it is in two
			# keyrings by the time this returns, and a secret echoed into a
			# scrollback is one more place it lives.
			local key
			key=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*key:[[:space:]]*//p' | head -1)

			echo "Declared pbus event: $_PREL_PBUS_EVENT"
			echo "  description:     $_PREL_PBUS_DESC"
			echo "  payload pattern: $_PREL_PBUS_PATTERN"
			echo "  key:             $(_ipb_keyring)/$_PREL_PBUS_EVENT ($(id -un))"

			local handed
			if handed=$(_ipb_save_key_for_caller "$key"); then
				echo "  key:             ${handed#*$'\t'} (${handed%%$'\t'*})"
			elif [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
				echo ""
				echo "Warning: the key could not be put in $SUDO_USER's keyring, so a" >&2
				echo "         release run by $SUDO_USER has none to present. Hand it over" >&2
				echo "         with 'pbus save-key $_PREL_PBUS_EVENT' as $SUDO_USER, or" >&2
				echo "         draw a new one with 'sudo pbus rotate-key $_PREL_PBUS_EVENT --save'" >&2
			fi

			echo ""
			echo "A release published from here now emits it. Nothing listens yet:"
			echo "  sudo pbus register-listener $_PREL_PBUS_EVENT --id notify \\"
			echo "       -u root 'pbus-notify -u ${SUDO_USER:-\$USER} \"prel \$PBUS_PAYLOAD published\"'"
			return 0
			;;
		unregister)
			_ipb_have_pbus || { _ipb_no_pbus_message; return 1; }
			_ipb_need_root unregister || return 1

			if ! _ipb_event_known; then
				echo "Not declared: $_PREL_PBUS_EVENT"
				return 0
			fi

			if ! pbus unregister-event "$_PREL_PBUS_EVENT"; then
				echo "Error: pbus could not remove $_PREL_PBUS_EVENT" >&2
				return 1
			fi
			# The listeners are somebody's configuration, and an event can be
			# declared again under the same name: removing them is a separate
			# decision, taken with a separate flag.
			echo "The listeners of that event are kept; remove them too with:"
			echo "  sudo pbus unregister-event $_PREL_PBUS_EVENT --purge-listeners"

			# pbus removes the key from the keyring of whoever is running it -
			# root's - and knows nothing of the copy register handed to the
			# account that called sudo. It opens nothing where the event is
			# gone, but it is a secret, and a stale one.
			local user="${SUDO_USER:-}"
			if [ -n "$user" ] && [ "$user" != "root" ]; then
				local home
				home=$(getent passwd "$user" | cut -d: -f6)
				if [ -n "$home" ] && [ -f "$home/.config/pbus/keys/$_PREL_PBUS_EVENT" ]; then
					echo ""
					echo "$user's copy of the key opens nothing now; remove it with:"
					echo "  rm -f $home/.config/pbus/keys/$_PREL_PBUS_EVENT"
				fi
			fi
			return 0
			;;
		status)
			if ! _ipb_have_pbus; then
				echo "pbus:    not installed, so a release emits nothing"
				echo "         ('prel release' is unaffected: the emit is the last step"
				echo "         of a published release, and a silent one without pbus)"
				return 0
			fi

			echo "pbus:    $(command -v pbus) ($(pbus version 2>/dev/null || echo 'version unknown'))"
			echo "event:   $_PREL_PBUS_EVENT"

			if ! _ipb_event_known; then
				echo "         not declared, so a release emits nothing"
				echo "         declare it with 'sudo prel init-pbus register'"
				return 0
			fi

			local keyring
			keyring=$(_ipb_keyring)
			if ! _ipb_event_wants_key; then
				echo "key:     none required, the event is declared --no-key"
			elif [ -r "$keyring/$_PREL_PBUS_EVENT" ]; then
				echo "key:     $keyring/$_PREL_PBUS_EVENT"
			elif [ -n "${PBUS_KEY:-}" ]; then
				echo "key:     PBUS_KEY is set in this shell"
			else
				echo "key:     none for $(id -un) in $keyring"
				echo "         an emission without one is refused; hand it over with"
				echo "         'pbus save-key $_PREL_PBUS_EVENT'"
			fi

			local pattern
			pattern=$(_ipb_event_pattern)
			if [ -n "$pattern" ]; then
				echo "payload: the version being released, as in 0.2.7"
				echo "         the event declares the pattern $pattern"
			else
				echo "payload: the version being released, as in 0.2.7"
				echo "         the event declares no pattern, so it accepts any payload"
				echo "         ('sudo prel init-pbus register' says how to add one)"
			fi
			echo ""
			pbus show-event "$_PREL_PBUS_EVENT"
			return 0
			;;
		*)
			echo "Error: Unknown action '$action' for init-pbus" >&2
			echo "Try: prel init-pbus usage" >&2
			return 1
			;;
	esac
}

# If this script is run directly (not sourced), call the function.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	init_pbus "$@"
fi
