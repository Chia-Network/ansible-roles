#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
	HELPER="$REPO_ROOT/chia-blockchain/files/darwin/timelord-app-quiesce.sh"
	BIN="$BATS_TEST_TMPDIR/bin"
	APP="$BATS_TEST_TMPDIR/Timelord.app"
	GUI="$APP/Contents/MacOS/Timelord"
	SUPERVISOR="$APP/Contents/Helpers/timelord-supervisor"
	LOCK="$BATS_TEST_TMPDIR/owner.lock"
	PIDS="$BATS_TEST_TMPDIR/pids"
	mkdir -p "$BIN" "$(dirname "$GUI")" "$(dirname "$SUPERVISOR")"
	: >"$LOCK"
	: >"$PIDS"
	export BIN APP GUI SUPERVISOR LOCK PIDS
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

run_helper() {
	run "$HELPER" \
		--user "$(id -un)" \
		--app "$APP" \
		--supervisor "$SUPERVISOR" \
		--timeout 1
}

@test "quiesce is a no-op when nothing matches" {
	run_helper
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
}

@test "quiesce TERMs the GUI and its supervisor" {
	gui=$(start_argv0 "$GUI")
	supervisor=$(start_argv0 "$SUPERVISOR")
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

@test "quiesce does not wait on a hanging osascript" {
	cat >"$BIN/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${OSASCRIPT_LOG:?}"
sleep 60
EOF
	chmod +x "$BIN/osascript"
	OSASCRIPT_LOG="$BATS_TEST_TMPDIR/osascript.log"
	export OSASCRIPT_LOG
	gui=$(start_argv0 "$GUI")
	sleep 0.2
	start=$(date +%s)
	run_helper
	elapsed=$(($(date +%s) - start))
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	[ "$elapsed" -lt 5 ]
	[ ! -e "$OSASCRIPT_LOG" ]
	if kill -0 "$gui" 2>/dev/null; then
		false
	fi
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

@test "quiesce fails when a matched process remains" {
	cat >"$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-U" ] && [ "${3:-}" = "-f" ] || exit 1
[ "${2:-}" = "${FAKE_UID:?}" ] || exit 1
case "${4:-}" in
*"/Contents/MacOS/"* | *"/Contents/Helpers/timelord-supervisor"*) ;;
*) exit 1 ;;
esac
printf '999999\n'
EOF
	chmod +x "$BIN/pgrep"
	FAKE_UID=$(id -un)
	export FAKE_UID
	run "$HELPER" \
		--user "$FAKE_UID" \
		--app "$APP" \
		--supervisor "$SUPERVISOR" \
		--timeout 1
	[ "$status" -ne 0 ]
	[[ "$output" == *"quiesce failed"* ]]
	[[ "$output" == *"999999"* ]]
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
		--supervisor "$SUPERVISOR" \
		--timeout 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
	kill -0 "$pid" 2>/dev/null
}
