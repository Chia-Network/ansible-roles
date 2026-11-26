#!/bin/bash
# Stop the Timelord.app GUI and any supervisor or worker owned by the service
# user. Root-owned so it never runs from the service user's home directory.
set -u

user=
app=
timeout=

usage() {
	printf 'usage: %s --user USER --app APP --timeout SECONDS\n' "$0" >&2
	exit 64
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--user)
		[ "$#" -ge 2 ] || usage
		user=$2
		shift 2
		;;
	--app)
		[ "$#" -ge 2 ] || usage
		app=$2
		shift 2
		;;
	--timeout)
		[ "$#" -ge 2 ] || usage
		timeout=$2
		shift 2
		;;
	*)
		usage
		;;
	esac
done

[ -n "$user" ] && [ -n "$app" ] && [ -n "$timeout" ] || usage
case "$timeout" in '' | *[!0-9]*) usage ;; esac

escape_regex() {
	printf '%s\n' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

# Anchor on argv[0]: a later mention of the bundle path is not a match.
# pgrep -U restricts every match to the service user's processes.
supervisor="$app/Contents/Helpers/timelord-supervisor"
app_regex=$(escape_regex "$app")
gui_pattern="^$app_regex/Contents/MacOS/"
supervisor_pattern="^$(escape_regex "$supervisor")([[:space:]]|$)"
bundle_pattern="^$app_regex/Contents/"

# TERM only the GUI and the supervisor; wait for, and if needed KILL, the whole
# bundle prefix so a worker in its own process group is not orphaned.
collect_gui_and_supervisor() {
	{
		pgrep -U "$user" -f "$gui_pattern" 2>/dev/null || true
		pgrep -U "$user" -f "$supervisor_pattern" 2>/dev/null || true
	} | LC_ALL=C sort -n -u
}

collect_bundle() {
	pgrep -U "$user" -f "$bundle_pattern" 2>/dev/null || true
}

wait_gone() {
	local deadline
	deadline=$(($(date +%s) + timeout))
	while :; do
		[ -z "$(collect_bundle)" ] && return 0
		[ "$(date +%s)" -ge "$deadline" ] && return 1
		sleep 1
	done
}

signal_pids() {
	local signal=$1 pid signalled=1
	while IFS= read -r pid; do
		[ -n "$pid" ] || continue
		kill "-$signal" "$pid" 2>/dev/null && signalled=0
	done
	return "$signalled"
}

changed=0
pids=$(collect_gui_and_supervisor)
if [ -n "$pids" ]; then
	printf '%s\n' "$pids" | signal_pids TERM && changed=1
fi

# When only an orphaned worker remains, wait_gone still spends the full budget
# before KILL so the vendor worst-case stop window is always allowed.
if ! wait_gone; then
	# Re-collect before KILL so a worker or child that appeared during the TERM
	# wait is included.
	pids=$(collect_bundle)
	printf '%s\n' "$pids" | signal_pids KILL && changed=1
	if ! wait_gone; then
		printf 'Timelord.app quiesce failed; still running: %s\n' \
			"$(collect_bundle | tr '\n' ' ')" >&2
		exit 1
	fi
fi

[ "$changed" -eq 1 ] && printf 'changed=true\n' || printf 'changed=false\n'
exit 0
