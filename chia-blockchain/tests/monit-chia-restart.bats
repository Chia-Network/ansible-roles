#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
	BIN="$BATS_TEST_TMPDIR/bin"
	STATE_DIR="$BATS_TEST_TMPDIR/state"
	SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
	NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
	HW_LOG="$BATS_TEST_TMPDIR/hw.log"
	KILL_LOG="$BATS_TEST_TMPDIR/kill.log"
	mkdir -p "$BIN" "$STATE_DIR"
	: >"$SYSTEMCTL_LOG"
	: >"$NOTIFY_LOG"
	: >"$HW_LOG"
	: >"$KILL_LOG"

	cat >"$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BATS_TEST_TMPDIR}/systemctl.log"
if [ "${1:-}" = show ]; then
	unit=${5:-}
	case "$unit" in
	*.target)
		if [ -n "${TARGET_START:-}" ]; then printf '@%s\n' "$TARGET_START"; else printf 'n/a\n'; fi
		;;
	*-hw-vdf.service)
		if [ -n "${HW_START:-}" ]; then printf '@%s\n' "$HW_START"; else printf 'n/a\n'; fi
		;;
	*) printf 'n/a\n' ;;
	esac
	exit 0
fi
if [ "${1:-}" = is-active ]; then
	unit=${!#}
	for inactive in ${FAKE_INACTIVE_UNITS:-}; do
		[ "$unit" = "$inactive" ] && exit 3
	done
fi
exit 0
EOF

	cat >"$BIN/date" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
	total=0
	if [ -s "${BATS_TEST_TMPDIR}/slept" ]; then
		total=$(awk '{ s += $1 } END { printf "%d", s }' "${BATS_TEST_TMPDIR}/slept")
	fi
	printf '%s\n' "$((FAKE_NOW + total))"
else
	exec /bin/date "$@"
fi
EOF

	cat >"$BIN/notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BATS_TEST_TMPDIR}/notify.log"
EOF

	cat >"$BIN/hw-restart" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' restarted >>"${BATS_TEST_TMPDIR}/hw.log"
EOF

	cat >"$BIN/ss" <<'EOF'
#!/usr/bin/env bash
[ "${FAKE_SS_EMPTY:-}" = 1 ] && exit 0
printf '%s\n' 'LISTEN 0 128 0.0.0.0:8444 0.0.0.0:*'
EOF

	cat >"$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-0}" >>"${BATS_TEST_TMPDIR}/slept"
exit 0
EOF

	cat >"$BIN/id" <<'EOF'
#!/usr/bin/env bash
if [ "${FAKE_ID_FAIL:-}" = 1 ]; then exit 1; fi
printf '%s\n' "${FAKE_UID:-1001}"
EOF

	cat >"$BIN/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF

	chmod +x "$BIN/systemctl" "$BIN/date" "$BIN/notify" "$BIN/hw-restart" \
		"$BIN/ss" "$BIN/sleep" "$BIN/id" "$BIN/timeout"

	render_script

	export PATH="$BIN:$PATH"
	export FAKE_NOW=1000000
}

render_script() {
	SCRIPT="$BATS_TEST_TMPDIR/monit-chia-restart.sh"
	local enabled='["full-node","timelord"]'
	[ -n "${ENABLED_SERVICES:-}" ] && enabled=$ENABLED_SERVICES
	ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
		ansible localhost -c local -m template \
		-a "src=${REPO_ROOT}/chia-blockchain/templates/monit-chia-restart.sh.j2 dest=${SCRIPT}" \
		-e "chia_service_base=chia" \
		-e "chia_monit_restart_min_seconds=600" \
		-e "chia_monit_restart_max_seconds=3600" \
		-e "chia_monit_restart_backoff_factor=2" \
		-e "chia_monit_restart_verify_seconds=90" \
		-e "chia_monit_restart_state_dir=${STATE_DIR}" \
		-e "user=chia-test" \
		-e "full_node_port=8444" \
		-e "chia_timelord_port=8446" \
		-e "{\"chia_enabled_services\": ${enabled}}" \
		-e '{"chia_all_services":["daemon","full-node","timelord"]}' \
		-e "{\"chia_monit_alert_on_restart\": ${ALERT:-false}}" >/dev/null
	sed -i \
		-e "s|^SYSTEMCTL=.*|SYSTEMCTL=\"${BIN}/systemctl\"|" \
		-e "s|^KILL=.*|KILL=\"${BIN}/kill\"|" \
		-e "s|^PROC=.*|PROC=\"${BATS_TEST_TMPDIR}/proc\"|" \
		-e "s|^NOTIFY=.*|NOTIFY=\"${BIN}/notify\"|" \
		-e "s|^HW_RESTART=.*|HW_RESTART=\"${BIN}/hw-restart\"|" \
		-e "s|^STATE_DIR=.*|STATE_DIR=\"${STATE_DIR}\"|" \
		"$SCRIPT"
	mkdir -p "$BATS_TEST_TMPDIR/proc"
	cat >"$BIN/kill" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${BATS_TEST_TMPDIR}/kill.log"
EOF
	chmod +x "$SCRIPT" "$BIN/kill"
}

write_state() {
	local target_restarts=$1 target_last=$2
	printf 'target_restarts=%s\ntarget_last=%s\nhw_restarts=0\nhw_last=0\n' \
		"$target_restarts" "$target_last" >"$STATE_DIR/state"
}

restart_count() {
	grep -c '^start chia.target$' "$SYSTEMCTL_LOG" || true
}

make_proc() {
	local pid=$1 name=$2 cgroup=$3
	mkdir -p "$BATS_TEST_TMPDIR/proc/$pid"
	printf '%s\0' "$name" >"$BATS_TEST_TMPDIR/proc/$pid/cmdline"
	printf '%s\n' "$cgroup" >"$BATS_TEST_TMPDIR/proc/$pid/cgroup"
}

require_non_root() {
	local uid
	uid=$(/usr/bin/id -u)
	[ "$uid" -ne 0 ] || skip "stray tests require a non-root user"
	export FAKE_UID=$uid
}

@test "first call with no state restarts chia.target" {
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ "$(restart_count)" -eq 1 ]
	grep -q '^target_restarts=1$' "$STATE_DIR/state"
}

@test "a call five minutes later is skipped" {
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	FAKE_NOW=$((FAKE_NOW + 300))
	export FAKE_NOW
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ "$(restart_count)" -eq 1 ]
	[[ "$output" == *"skip target"* ]]
}

@test "continuous failure backs off 1200 2400 3600 3600" {
	local base=$FAKE_NOW i count prev
	local -a times gaps
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	times=("$base")
	prev=$(restart_count)
	for ((i = 1; i <= 300; i++)); do
		FAKE_NOW=$((base + i * 60))
		export FAKE_NOW
		run "$SCRIPT" target
		[ "$status" -eq 0 ]
		count=$(restart_count)
		if [ "$count" -gt "$prev" ]; then times+=("$FAKE_NOW"); fi
		prev=$count
	done
	[ "${#times[@]}" -ge 5 ]
	gaps=()
	for ((i = 1; i < ${#times[@]}; i++)); do
		gaps+=($((times[i] - times[i - 1])))
	done
	[ "${gaps[0]}" -eq 1200 ]
	[ "${gaps[1]}" -eq 2400 ]
	[ "${gaps[2]}" -eq 3600 ]
	[ "${gaps[3]}" -eq 3600 ]
}

@test "state older than twice the maximum resets the counter" {
	local now=$FAKE_NOW
	write_state 5 $((now - 8000))
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	grep -q '^target_restarts=1$' "$STATE_DIR/state"
}

@test "state between maximum and twice maximum increments the counter" {
	local now=$FAKE_NOW
	write_state 5 $((now - 5000))
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	grep -q '^target_restarts=6$' "$STATE_DIR/state"
}

@test "unusable state is repaired and notify is called" {
	printf 'garbage\n' >"$STATE_DIR/state"
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	grep -q '^target_restarts=32$' "$STATE_DIR/state"
	grep -q '^hw_restarts=32$' "$STATE_DIR/state"
	[ -s "$NOTIFY_LOG" ]
	! grep -q '^start chia.target$' "$SYSTEMCTL_LOG"
}

@test "with alerts enabled a restart notifies" {
	export ALERT=true
	render_script
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	grep -q 'restarted' "$NOTIFY_LOG"
}

@test "with alerts enabled a skipped call does not notify" {
	export ALERT=true
	render_script
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	local before
	before=$(grep -c 'restarted' "$NOTIFY_LOG" || true)
	FAKE_NOW=$((FAKE_NOW + 300))
	export FAKE_NOW
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ "$(grep -c 'restarted' "$NOTIFY_LOG" || true)" -eq "$before" ]
}

@test "with alerts disabled a restart does not notify" {
	unset ALERT
	render_script
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ ! -s "$NOTIFY_LOG" ]
}

@test "state repair notify passes the unusable message" {
	printf 'garbage\n' >"$STATE_DIR/state"
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	grep -q 'unusable' "$NOTIFY_LOG"
}

@test "a held lock skips without restarting" {
	local lock_pid
	flock "$STATE_DIR/lock" /bin/sleep 5 &
	lock_pid=$!
	for _ in {1..100}; do
		if ! flock -n "$STATE_DIR/lock" true 2>/dev/null; then break; fi
		/bin/sleep 0.02
	done
	run "$SCRIPT" target
	kill "$lock_pid" 2>/dev/null || true
	wait "$lock_pid" 2>/dev/null || true
	[ "$status" -eq 0 ]
	[[ "$output" == *"holds"* ]]
	! grep -q '^start chia.target$' "$SYSTEMCTL_LOG"
	! grep -q '^stop chia.target$' "$SYSTEMCTL_LOG"
}

@test "state with duplicate and missing keys is repaired" {
	printf 'target_restarts=1\ntarget_restarts=1\ntarget_last=1000000\nhw_restarts=1\n' >"$STATE_DIR/state"
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	grep -q '^target_restarts=32$' "$STATE_DIR/state"
	grep -q '^hw_restarts=32$' "$STATE_DIR/state"
	[ ! -s "$SYSTEMCTL_LOG" ]
}

@test "hw-vdf is skipped while the target unit started recently" {
	export TARGET_START=$((FAKE_NOW - 60))
	run "$SCRIPT" hw-vdf
	[ "$status" -eq 0 ]
	[[ "$output" == *"skip target"* ]]
	[ ! -s "$HW_LOG" ]
}

@test "hw-vdf restarts through the hw restart script when due" {
	unset TARGET_START HW_START
	run "$SCRIPT" hw-vdf
	[ "$status" -eq 0 ]
	[ -s "$HW_LOG" ]
	grep -q '^hw_restarts=1$' "$STATE_DIR/state"
	! grep -q '^restart chia-hw-vdf.service$' "$SYSTEMCTL_LOG"
}

@test "hw-vdf is skipped while the hw unit started recently" {
	export TARGET_START=$((FAKE_NOW - 5000))
	export HW_START=$((FAKE_NOW - 60))
	run "$SCRIPT" hw-vdf
	[ "$status" -eq 0 ]
	[[ "$output" == *"skip hw"* ]]
	[ ! -s "$HW_LOG" ]
}

@test "missing state directory exits cleanly and notifies" {
	rm -rf "$STATE_DIR"
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[[ "$output" == *"not a usable directory"* ]]
	[ -s "$NOTIFY_LOG" ]
	[ ! -s "$SYSTEMCTL_LOG" ]
}

@test "a due target restart stops, kills, resets and starts in order" {
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	local actions
	actions=$(grep -E '^(stop|kill|reset-failed|start) ' "$SYSTEMCTL_LOG" || true)
	[ "$actions" = "stop chia.target
kill --kill-who=all --signal=SIGKILL chia-daemon.service
kill --kill-who=all --signal=SIGKILL chia-full-node.service
kill --kill-who=all --signal=SIGKILL chia-timelord.service
reset-failed chia.target
reset-failed chia-daemon.service
reset-failed chia-full-node.service
reset-failed chia-timelord.service
start chia.target" ]
}

@test "verify success does not notify" {
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ ! -s "$NOTIFY_LOG" ]
	[[ "$output" == *"active and listening"* ]]
}

@test "verify timeout notifies and still exits 0" {
	sed -i 's/^VERIFY_SECONDS=.*/VERIFY_SECONDS=0/' "$SCRIPT"
	export FAKE_SS_EMPTY=1
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ -s "$NOTIFY_LOG" ]
	[[ "$output" == *"timed out waiting"* ]]
}

@test "kill_strays refuses when the user resolves to uid 0" {
	export FAKE_UID=0
	make_proc 9001 chia_full_node '0::/user.slice/user-1000.slice/session-3.scope'
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[[ "$output" == *"refusing to kill strays"* ]]
	[ ! -s "$KILL_LOG" ]
}

@test "kill_strays does not signal when the user cannot be resolved" {
	export FAKE_ID_FAIL=1
	make_proc 9002 chia_full_node '0::/user.slice/user-1000.slice/session-3.scope'
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[[ "$output" == *"refusing to kill strays"* ]]
	[ ! -s "$KILL_LOG" ]
}

@test "a listed stray outside managed units is terminated then killed" {
	require_non_root
	make_proc 9003 chia_full_node '0::/user.slice/user-1000.slice/session-3.scope'
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ "$(cat "$KILL_LOG")" = "-s TERM 9003
-s KILL 9003" ]
}

@test "a listed process in an active managed unit is not signalled" {
	require_non_root
	make_proc 9004 chia_full_node '0::/system.slice/chia-full-node.service'
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ ! -s "$KILL_LOG" ]
}

@test "unlisted process names are not signalled" {
	require_non_root
	make_proc 9005 sleep '0::/user.slice/user-1000.slice/session-3.scope'
	make_proc 9006 start_other_tool '0::/user.slice/user-1000.slice/session-3.scope'
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ ! -s "$KILL_LOG" ]
}

@test "an exact start_ stray name is signalled" {
	require_non_root
	make_proc 9007 start_full_node '0::/user.slice/user-1000.slice/session-3.scope'
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[[ "$(cat "$KILL_LOG")" == *"-s TERM 9007"* ]]
}

@test "a process in an inactive managed unit is signalled" {
	require_non_root
	export FAKE_INACTIVE_UNITS="chia-full-node.service"
	make_proc 9008 chia_full_node '0::/system.slice/chia-full-node.service'
	sed -i 's/^VERIFY_SECONDS=.*/VERIFY_SECONDS=0/' "$SCRIPT"
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[[ "$(cat "$KILL_LOG")" == *"-s TERM 9008"* ]]
}

@test "verify failure names the only enabled unit" {
	export ENABLED_SERVICES='["full-node"]'
	export FAKE_SS_EMPTY=1
	render_script
	unset ENABLED_SERVICES
	sed -i 's/^VERIFY_SECONDS=.*/VERIFY_SECONDS=0/' "$SCRIPT"
	run "$SCRIPT" target
	[ "$status" -eq 0 ]
	[ -s "$NOTIFY_LOG" ]
	grep -q 'chia-full-node.service' "$NOTIFY_LOG"
}

@test "unknown command exits 2" {
	run "$SCRIPT" bogus
	[ "$status" -eq 2 ]
}
