#!/bin/bash
# Evict a Timelord.app supervisor that is not the launchd-owned process. A GUI
# launched outside launchd can leave a user-session supervisor holding the
# owner.lock file, which makes install-service.sh check-owner fail.
set -u

label=""
lock=""
binary=""
timeout=60
launchctl_cmd="launchctl"

usage() {
	printf 'usage: %s --label LABEL --lock PATH --binary PATH [--launchctl PATH] [--timeout SECONDS]\n' "$0" >&2
	exit 64
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--label)
		[ "$#" -ge 2 ] || usage
		label=$2
		shift 2
		;;
	--lock)
		[ "$#" -ge 2 ] || usage
		lock=$2
		shift 2
		;;
	--binary)
		[ "$#" -ge 2 ] || usage
		binary=$2
		shift 2
		;;
	--launchctl)
		[ "$#" -ge 2 ] || usage
		launchctl_cmd=$2
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

[ -n "$label" ] && [ -n "$lock" ] && [ -n "$binary" ] || usage

is_numeric() {
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	esac
	return 0
}

ancestors=" "
pid=$$
while is_numeric "$pid" && [ "$pid" -gt 1 ]; do
	ancestors="${ancestors}${pid} "
	pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
done
[ -n "$pid" ] && ancestors="${ancestors}${pid} "

live_pid=$("$launchctl_cmd" print "system/${label}" 2>/dev/null |
	sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\).*/\1/p' |
	head -n 1)

is_excluded() {
	local candidate=$1 parent
	is_numeric "$candidate" || return 0
	case " ${ancestors} " in
	*" ${candidate} "*) return 0 ;;
	esac
	parent=$candidate
	while is_numeric "$parent" && [ "$parent" -gt 1 ]; do
		[ "$parent" = "$$" ] && return 0
		parent=$(ps -o ppid= -p "$parent" 2>/dev/null | tr -d '[:space:]')
	done
	[ -n "$live_pid" ] && [ "$candidate" = "$live_pid" ] && return 0
	return 1
}

# A bare command line that merely mentions the binary path (for example this
# script's own --binary argument) is not a supervisor. Require the process's
# executable or argv[0] to be the supervisor binary itself.
is_supervisor_process() {
	local candidate=$1 exe cmd
	is_numeric "$candidate" || return 1
	exe=$(ps -o comm= -p "$candidate" 2>/dev/null |
		sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	[ -n "$exe" ] && [ "$exe" = "$binary" ] && return 0
	cmd=$(ps -o command= -p "$candidate" 2>/dev/null | sed 's/^[[:space:]]*//')
	case "$cmd" in
	"$binary" | "$binary "*) return 0 ;;
	esac
	return 1
}

pids=""
add_pid() {
	local candidate=$1
	is_numeric "$candidate" || return 0
	is_excluded "$candidate" && return 0
	# A PID that is already gone is not something we evicted.
	kill -0 "$candidate" 2>/dev/null || return 0
	case " ${pids} " in
	*" ${candidate} "*) return 0 ;;
	esac
	pids="${pids}${candidate} "
}

collect() {
	local output holder
	if [ -e "$lock" ] && command -v lsof >/dev/null 2>&1; then
		output=$(lsof -t "$lock" 2>/dev/null || true)
		while IFS= read -r holder; do
			add_pid "$holder"
		done <<<"$output"
	fi
	if command -v pgrep >/dev/null 2>&1; then
		output=$(pgrep -f "$binary" 2>/dev/null || true)
		while IFS= read -r holder; do
			[ -n "$holder" ] || continue
			is_supervisor_process "$holder" || continue
			add_pid "$holder"
		done <<<"$output"
	fi
}

alive_pids() {
	local candidate
	for candidate in $pids; do
		kill -0 "$candidate" 2>/dev/null && printf '%s\n' "$candidate"
	done
}

lock_holders() {
	[ -e "$lock" ] || return 0
	command -v lsof >/dev/null 2>&1 || return 0
	local output candidate
	output=$(lsof -t "$lock" 2>/dev/null || true)
	while IFS= read -r candidate; do
		[ -n "$candidate" ] || continue
		is_excluded "$candidate" || printf '%s\n' "$candidate"
	done <<<"$output"
}

wait_gone() {
	local seconds=$1 deadline remaining holders
	deadline=$(($(date +%s) + seconds))
	while :; do
		remaining=$(alive_pids)
		holders=$(lock_holders)
		if [ -z "$remaining" ] && [ -z "$holders" ]; then
			return 0
		fi
		[ "$(date +%s)" -ge "$deadline" ] && return 1
		sleep 1
	done
}

collect
holders=$(lock_holders)
if [ -z "$(printf '%s' "$pids" | tr -d '[:space:]')" ] && [ -z "$holders" ]; then
	printf 'changed=false\n'
	exit 0
fi

killed_any=0
if [ -n "$(printf '%s' "$pids" | tr -d '[:space:]')" ]; then
	printf 'Evicting Timelord.app supervisor process(es): %s\n' "$pids" >&2
	for candidate in $pids; do
		kill -TERM "$candidate" 2>/dev/null && killed_any=1
	done
fi
if ! wait_gone "$timeout"; then
	collect
	for candidate in $pids; do
		kill -0 "$candidate" 2>/dev/null || continue
		kill -KILL "$candidate" 2>/dev/null && killed_any=1
	done
	if ! wait_gone "$timeout"; then
		remaining=$(alive_pids)
		holders=$(lock_holders)
		printf 'Timelord.app supervisor eviction failed; still alive: %s lock holders: %s\n' \
			"${remaining:-none}" "${holders:-none}" >&2
		exit 1
	fi
fi

if [ "$killed_any" -eq 0 ]; then
	holders=$(lock_holders)
	if [ -n "$holders" ]; then
		printf 'Timelord.app supervisor eviction failed; still alive: %s lock holders: %s\n' \
			"none" "$holders" >&2
		exit 1
	fi
	printf 'changed=false\n'
	exit 0
fi

printf 'changed=true\n'
exit 0
