#!/bin/bash
# Quit Timelord.app and fall back to terminating its GUI process when the
# AppleScript quit is ignored. Helpers under Contents/Helpers (including the
# supervisor) are deliberately not matched here; evict them separately.
set -u

bundle_id="net.chia.timelord.mac"
app="/Applications/Timelord.app"
timeout=10

usage() {
	printf 'usage: %s [--app PATH] [--bundle-id ID] [--timeout SECONDS]\n' "$0" >&2
	exit 64
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--app)
		[ "$#" -ge 2 ] || usage
		app=$2
		shift 2
		;;
	--bundle-id)
		[ "$#" -ge 2 ] || usage
		bundle_id=$2
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

ancestors=" "
pid=$$
while [ "$pid" -gt 0 ] 2>/dev/null; do
	ancestors="${ancestors}${pid} "
	[ "$pid" -eq 1 ] && break
	pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
	[ -n "$pid" ] || break
done

is_own_process() {
	local candidate=$1 parent
	case " ${ancestors} " in
	*" ${candidate} "*) return 0 ;;
	esac
	parent=$candidate
	while [ "$parent" -gt 0 ] 2>/dev/null; do
		[ "$parent" = "$$" ] && return 0
		parent=$(ps -o ppid= -p "$parent" 2>/dev/null | tr -d ' ')
		[ -n "$parent" ] || break
	done
	return 1
}

running_pids() {
	local pattern output candidate
	for pattern in "$app/Contents/MacOS/" "$bundle_id"; do
		output=$(pgrep -f "$pattern" 2>/dev/null || true)
		while IFS= read -r candidate; do
			[ -n "$candidate" ] || continue
			is_own_process "$candidate" && continue
			printf '%s\n' "$candidate"
		done <<<"$output"
	done
}

wait_for_exit() {
	local seconds=$1 deadline
	deadline=$(($(date +%s) + seconds))
	while :; do
		[ -z "$(running_pids)" ] && return 0
		[ "$(date +%s)" -ge "$deadline" ] && return 1
		sleep 1
	done
}

if [ -z "$(running_pids)" ]; then
	printf 'changed=false\n'
	exit 0
fi

if command -v osascript >/dev/null 2>&1; then
	osascript -e "quit app id \"${bundle_id}\"" >/dev/null 2>&1 || true
fi

if ! wait_for_exit "$timeout"; then
	if command -v pkill >/dev/null 2>&1; then
		pkill -TERM -f "$app/Contents/MacOS/" 2>/dev/null || true
	fi
	while IFS= read -r candidate; do
		[ -n "$candidate" ] || continue
		kill -TERM "$candidate" 2>/dev/null || true
	done < <(running_pids)
	if ! wait_for_exit "$timeout"; then
		if command -v pkill >/dev/null 2>&1; then
			pkill -KILL -f "$app/Contents/MacOS/" 2>/dev/null || true
		fi
		while IFS= read -r candidate; do
			[ -n "$candidate" ] || continue
			kill -KILL "$candidate" 2>/dev/null || true
		done < <(running_pids)
		wait_for_exit "$timeout" || true
	fi
fi

printf 'changed=true\n'
exit 0
