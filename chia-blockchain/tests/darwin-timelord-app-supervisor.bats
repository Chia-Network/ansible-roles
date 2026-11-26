#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
	HELPER="$REPO_ROOT/chia-blockchain/files/darwin/timelord-app-quiesce.sh"
	BIN="$BATS_TEST_TMPDIR/bin"
	APP="$BATS_TEST_TMPDIR/Timelord.app"
	GUI="$APP/Contents/MacOS/Timelord"
	SUPERVISOR="$APP/Contents/Helpers/timelord-supervisor"
	WORKER="$APP/Contents/Helpers/timelord-service"
	LOCK="$BATS_TEST_TMPDIR/owner.lock"
	PIDS="$BATS_TEST_TMPDIR/pids"
	mkdir -p "$BIN" "$(dirname "$GUI")" "$(dirname "$SUPERVISOR")"
	: >"$LOCK"
	: >"$PIDS"
	export BIN APP GUI SUPERVISOR WORKER LOCK PIDS
	export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
}

teardown() {
	local pid
	[ -f "${PIDS:-}" ] || return 0
	while IFS= read -r pid; do
		[ -n "$pid" ] || continue
		kill -KILL "$pid" 2>/dev/null || true
	done <"$PIDS"
}

track() {
	local pid=$1
	printf '%s\n' "$pid" >>"$PIDS"
	printf '%s\n' "$pid"
}

start_argv0() {
	local name=$1
	bash -c 'exec -a "$1" sleep 60' _ "$name" >/dev/null 2>&1 &
	track "$!"
}

start_ignoring_term() {
	local name=$1
	bash -c 'trap "" TERM; exec -a "$1" sleep 60' _ "$name" >/dev/null 2>&1 &
	track "$!"
}

start_mentioning() {
	local mention=$1
	bash -c 'while :; do sleep 1; done' mention "$mention" >/dev/null 2>&1 &
	track "$!"
}

start_lock_opener() {
	bash -c 'exec 3>>"$1"; while :; do sleep 1; done' _ "$LOCK" >/dev/null 2>&1 &
	track "$!"
}

start_late_argv0() {
	local name=$1 delay=$2 pidfile=$3 late
	(
		sleep "$delay"
		bash -c 'exec -a "$1" sleep 60' _ "$name" >/dev/null 2>&1 &
		late=$!
		printf '%s\n' "$late" >"$pidfile"
		printf '%s\n' "$late" >>"$PIDS"
	) &
}

start_session_argv0() {
	local name=$1 pidfile=$2
	setsid bash -c 'printf "%s\n" "$$" >"$2"; exec -a "$1" sleep 60' _ "$name" "$pidfile" \
		>/dev/null 2>&1 &
	track "$!"
	for _ in $(seq 1 50); do
		[ -s "$pidfile" ] && break
		sleep 0.05
	done
	track "$(cat "$pidfile")"
}

run_helper() {
	run "$HELPER" \
		--user "$(id -un)" \
		--app "$APP" \
		--timeout "${1:-1}"
}

@test "quiesce is a no-op when nothing matches" {
	run_helper
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
}

@test "quiesce TERMs the GUI and a supervisor with trailing arguments" {
	gui=$(start_argv0 "$GUI")
	supervisor=$(start_argv0 "$SUPERVISOR run --config x")
	sleep 0.2
	run_helper
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	if kill -0 "$gui" 2>/dev/null; then
		false
	fi
	if kill -0 "$supervisor" 2>/dev/null; then
		false
	fi
}

@test "quiesce does not TERM a supervisor whose argv[0] only shares the prefix" {
	exact=$(start_argv0 "$SUPERVISOR")
	foo=$(start_argv0 "$SUPERVISOR-foo")
	out="$BATS_TEST_TMPDIR/boundary.out"
	"$HELPER" \
		--user "$(id -un)" \
		--app "$APP" \
		--timeout 2 >"$out" 2>&1 &
	helper_pid=$!
	sleep 0.5
	kill -0 "$foo" 2>/dev/null
	if kill -0 "$exact" 2>/dev/null; then false; fi
	wait "$helper_pid"
	[[ "$(cat "$out")" == *"changed=true"* ]]
}

@test "quiesce prefix-KILLs a supervisor whose argv[0] only shares the prefix" {
	foo=$(start_argv0 "$SUPERVISOR-foo")
	sleep 0.2
	run_helper 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	if kill -0 "$foo" 2>/dev/null; then
		false
	fi
}

@test "quiesce does not SIGKILL a supervisor that exits gracefully" {
	graceful_log="$BATS_TEST_TMPDIR/graceful.log"
	cat >"$BIN/graceful-supervisor" <<'SUPERVISOR'
#!/bin/bash
trap 'sleep 1.5; printf "graceful\n" >>"$1"; exit 0' TERM
while :; do sleep 0.1; done
SUPERVISOR
	chmod +x "$BIN/graceful-supervisor"
	bash -c 'exec -a "$1" bash "$2" "$3"' _ "$SUPERVISOR" "$BIN/graceful-supervisor" "$graceful_log" \
		>/dev/null 2>&1 &
	pid=$!
	track "$pid"
	sleep 0.2
	run_helper 3
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	[ -f "$graceful_log" ]
	[[ "$(cat "$graceful_log")" == *graceful* ]]
	if kill -0 "$pid" 2>/dev/null; then
		false
	fi
}

@test "quiesce reports changed when only the prefix KILL removes an orphan worker" {
	worker_pid="$BATS_TEST_TMPDIR/worker.pid"
	start_session_argv0 "$WORKER --serve" "$worker_pid"
	worker=$(cat "$worker_pid")
	sleep 0.2
	run_helper 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	if kill -0 "$worker" 2>/dev/null; then
		false
	fi
}

@test "quiesce does not invoke osascript" {
	! grep -q osascript "$HELPER"
}

@test "quiesce KILLs a process that ignores TERM" {
	pid=$(start_ignoring_term "$GUI")
	sleep 0.2
	kill -TERM "$pid"
	sleep 0.2
	kill -0 "$pid" 2>/dev/null
	run_helper
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	if kill -0 "$pid" 2>/dev/null; then
		false
	fi
}

@test "quiesce KILLs a worker that appears during the TERM wait" {
	gui=$(start_ignoring_term "$GUI")
	late_pid="$BATS_TEST_TMPDIR/late.pid"
	start_late_argv0 "$WORKER" 0.5 "$late_pid"
	run_helper 2
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	late=$(cat "$late_pid")
	if kill -0 "$late" 2>/dev/null; then
		false
	fi
	if kill -0 "$gui" 2>/dev/null; then
		false
	fi
}

@test "quiesce KILLs an orphaned worker in its own process group" {
	supervisor=$(start_ignoring_term "$SUPERVISOR run --config x")
	worker_pid="$BATS_TEST_TMPDIR/worker.pid"
	start_session_argv0 "$WORKER --serve" "$worker_pid"
	worker=$(cat "$worker_pid")
	sleep 0.2
	run_helper 2
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	if kill -0 "$worker" 2>/dev/null; then
		false
	fi
	if kill -0 "$supervisor" 2>/dev/null; then
		false
	fi
}

@test "quiesce fails when a matched process remains" {
	cat >"$BIN/pgrep" <<'PGREP'
#!/usr/bin/env bash
[ "${1:-}" = "-U" ] && [ "${3:-}" = "-f" ] || exit 1
[ "${2:-}" = "${FAKE_UID:?}" ] || exit 1
case "${4:-}" in
*"/Contents/"*) printf '999999\n' ;;
*) exit 1 ;;
esac
PGREP
	chmod +x "$BIN/pgrep"
	FAKE_UID=$(id -un)
	export FAKE_UID
	run "$HELPER" \
		--user "$FAKE_UID" \
		--app "$APP" \
		--timeout 1
	[ "$status" -ne 0 ]
	[[ "$output" == *"quiesce failed"* ]]
	[[ "$output" == *"999999"* ]]
}

@test "quiesce reports unchanged when every match exits before it is signalled" {
	cat >"$BIN/pgrep" <<'PGREP'
#!/usr/bin/env bash
[ "${1:-}" = "-U" ] && [ "${3:-}" = "-f" ] || exit 1
[ "${2:-}" = "${FAKE_UID:?}" ] || exit 1
case "${4:-}" in
*"/Contents/MacOS/"* | *"/Contents/Helpers/timelord-supervisor"*) printf '999999\n' ;;
*) exit 1 ;;
esac
PGREP
	chmod +x "$BIN/pgrep"
	FAKE_UID=$(id -un)
	export FAKE_UID
	run "$HELPER" \
		--user "$FAKE_UID" \
		--app "$APP" \
		--timeout 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
}

@test "quiesce ignores later argv mentions and unescaped paths" {
	mention_gui=$(start_mentioning "$GUI")
	mention_supervisor=$(start_mentioning "$SUPERVISOR")
	mention_bundle=$(start_mentioning "net.chia.timelord.mac")
	decoy_app="$BATS_TEST_TMPDIR/TimelordXapp"
	decoy_gui="$decoy_app/Contents/MacOS/Timelord"
	mkdir -p "$(dirname "$decoy_gui")"
	decoy=$(start_argv0 "$decoy_gui")
	sleep 0.2
	run_helper
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
	for pid in "$mention_gui" "$mention_supervisor" "$mention_bundle" "$decoy"; do
		kill -0 "$pid" 2>/dev/null
	done
}

@test "quiesce does not kill a process that only holds the lock file" {
	opener=$(start_lock_opener)
	sleep 0.2
	run_helper
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
	kill -0 "$opener" 2>/dev/null
}

@test "quiesce only signals the requested user's processes" {
	other_user=root
	if [ "$(id -u)" -eq 0 ]; then
		other_user=nobody
	fi
	id -u "$other_user" >/dev/null 2>&1 || skip "no alternate user"
	pid=$(start_argv0 "$GUI")
	sleep 0.2
	run "$HELPER" \
		--user "$other_user" \
		--app "$APP" \
		--timeout 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
	kill -0 "$pid" 2>/dev/null
}
