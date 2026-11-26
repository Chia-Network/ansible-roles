#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
	QUIT="$REPO_ROOT/chia-blockchain/files/darwin/timelord-app-quit.sh"
	EVICT="$REPO_ROOT/chia-blockchain/files/darwin/timelord-app-evict-supervisor.sh"
	BIN="$BATS_TEST_TMPDIR/bin"
	STATE="$BATS_TEST_TMPDIR/state"
	LOCK="$BATS_TEST_TMPDIR/owner.lock"
	APP="$BATS_TEST_TMPDIR/Timelord.app"
	mkdir -p "$BIN" "$STATE"
	export BIN STATE LOCK APP
	export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
	unset FAKE_APP_PID FAKE_LIVE_PID FAKE_LOCK_PID FAKE_LOCK_ALWAYS FAKE_OSASCRIPT_QUITS
}

teardown() {
	if [ -n "${TRACK_PID:-}" ]; then
		kill -KILL "$TRACK_PID" 2>/dev/null || true
	fi
}

fake_launchctl() {
	cat >"$BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = print ] && [ -n "${FAKE_LIVE_PID:-}" ]; then
	printf 'system/net.chia.timelord.supervisor = {\n\tpid = %s\n}\n' "$FAKE_LIVE_PID"
	exit 0
fi
exit 1
EOF
	chmod +x "$BIN/launchctl"
}

fake_lsof() {
	cat >"$BIN/lsof" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_LOCK_PID:-}" ] || exit 0
if [ "${FAKE_LOCK_ALWAYS:-0}" = 1 ] || kill -0 "$FAKE_LOCK_PID" 2>/dev/null; then
	printf '%s\n' "$FAKE_LOCK_PID"
fi
EOF
	chmod +x "$BIN/lsof"
}

fake_quit_commands() {
	cat >"$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
[ -f "$FAKE_STATE/app_running" ] || exit 1
printf '%s\n' "${FAKE_APP_PID:-4242}"
EOF
	cat >"$BIN/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE/osascript.log"
[ "${FAKE_OSASCRIPT_QUITS:-0}" = 1 ] && rm -f "$FAKE_STATE/app_running"
exit 0
EOF
	cat >"$BIN/pkill" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE/pkill.log"
rm -f "$FAKE_STATE/app_running"
exit 0
EOF
	chmod +x "$BIN/pgrep" "$BIN/osascript" "$BIN/pkill"
	export FAKE_STATE="$STATE"
}

run_evict() {
	run "$EVICT" \
		--label net.chia.timelord.supervisor \
		--lock "$LOCK" \
		--binary "$BATS_TEST_TMPDIR/no-such-supervisor" \
		--launchctl "$BIN/launchctl" \
		--timeout 1
}

@test "evict is a no-op without a lock or matching process" {
	fake_launchctl
	run_evict
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
	[ ! -e "$BIN/lsof.log" ]
}

@test "evict terminates a lock holder" {
	touch "$LOCK"
	fake_launchctl
	fake_lsof
	sleep 60 &
	TRACK_PID=$!
	export FAKE_LOCK_PID=$TRACK_PID
	run_evict
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	! kill -0 "$TRACK_PID" 2>/dev/null
}

@test "evict KILLs a supervisor that ignores TERM" {
	touch "$LOCK"
	fake_launchctl
	fake_lsof
	bash -c 'trap "printf term >>\"$1\"" TERM; while :; do sleep 0.1; done' _ "$STATE/term" &
	TRACK_PID=$!
	export FAKE_LOCK_PID=$TRACK_PID
	run_evict
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	[ -s "$STATE/term" ]
	! kill -0 "$TRACK_PID" 2>/dev/null
}

@test "evict fails loudly when a lock holder survives" {
	touch "$LOCK"
	fake_launchctl
	fake_lsof
	export FAKE_LOCK_PID=424242
	export FAKE_LOCK_ALWAYS=1
	run bash -c 'exec "$@" 2>&1' _ "$EVICT" \
		--label net.chia.timelord.supervisor \
		--lock "$LOCK" \
		--binary "$BATS_TEST_TMPDIR/no-such-supervisor" \
		--launchctl "$BIN/launchctl" \
		--timeout 1
	[ "$status" -ne 0 ]
	[[ "$output" == *"eviction failed"* ]]
	[[ "$output" == *"424242"* ]]
}

@test "evict never kills the live launchd-owned PID" {
	touch "$LOCK"
	fake_launchctl
	fake_lsof
	sleep 60 &
	TRACK_PID=$!
	export FAKE_LIVE_PID=$TRACK_PID
	export FAKE_LOCK_PID=$TRACK_PID
	run_evict
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
	kill -0 "$TRACK_PID" 2>/dev/null
}

@test "quit is a no-op when the app is not running" {
	fake_quit_commands
	run "$QUIT" --app "$APP" --bundle-id net.chia.timelord.mac --timeout 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=false"* ]]
	[ ! -f "$STATE/osascript.log" ]
}

@test "quit uses osascript when the app is running" {
	fake_quit_commands
	touch "$STATE/app_running"
	export FAKE_OSASCRIPT_QUITS=1
	run "$QUIT" --app "$APP" --bundle-id net.chia.timelord.mac --timeout 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	grep -q 'quit app id "net.chia.timelord.mac"' "$STATE/osascript.log"
	[ ! -e "$STATE/pkill.log" ]
}

@test "quit falls back to pkill when osascript leaves the app running" {
	fake_quit_commands
	touch "$STATE/app_running"
	run "$QUIT" --app "$APP" --bundle-id net.chia.timelord.mac --timeout 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"changed=true"* ]]
	grep -q -- '-TERM' "$STATE/pkill.log"
	[ ! -f "$STATE/app_running" ]
}
