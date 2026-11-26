#!/bin/bash
# Stop the Timelord.app GUI and any unlabeled supervisor owned by the service
# user. Root-owned so it never runs from the service user's home directory.
set -u

user=
app=
supervisor=
timeout=10

usage() {
	printf 'usage: %s --user USER --app APP --supervisor SUPERVISOR [--timeout SECONDS]\n' "$0" >&2
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
	--supervisor)
		[ "$#" -ge 2 ] || usage
		supervisor=$2
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

[ -n "$user" ] && [ -n "$app" ] && [ -n "$supervisor" ] || usage
case "$timeout" in '' | *[!0-9]*) usage ;; esac

escape_regex() {
	printf '%s\n' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

# Anchor on argv[0]: a later mention of the bundle or binary path is not a
# match. pgrep -U restricts every match to the service user's processes.
app_pattern="^$(escape_regex "$app")/Contents/MacOS/"
supervisor_pattern="^$(escape_regex "$supervisor")([[:space:]]|$)"

collect_pids() {
	{
		pgrep -U "$user" -f "$app_pattern" 2>/dev/null || true
		pgrep -U "$user" -f "$supervisor_pattern" 2>/dev/null || true
	} | LC_ALL=C sort -n -u
}

wait_gone() {
	local deadline
	deadline=$(($(date +%s) + timeout))
	while :; do
		[ -z "$(collect_pids)" ] && return 0
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

pids=$(collect_pids)
if [ -z "$pids" ]; then
	printf 'changed=false\n'
	exit 0
fi

changed=0
printf '%s\n' "$pids" | signal_pids TERM && changed=1
if ! wait_gone; then
	# Re-collect so a child that appeared during the TERM wait is also killed.
	pids=$(collect_pids)
	printf '%s\n' "$pids" | signal_pids KILL && changed=1
	if ! wait_gone; then
		printf 'Timelord.app quiesce failed; still running: %s\n' \
			"$(collect_pids | tr '\n' ' ')" >&2
		exit 1
	fi
fi

[ "$changed" -eq 1 ] && printf 'changed=true\n' || printf 'changed=false\n'
exit 0
