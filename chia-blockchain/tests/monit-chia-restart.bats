#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
	BIN="$BATS_TEST_TMPDIR/bin"
	STATE_DIR="$BATS_TEST_TMPDIR/state"
	SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
	NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"
	HW_LOG="$BATS_TEST_TMPDIR/hw.log"
	mkdir -p "$BIN" "$STATE_DIR"
	: >"$SYSTEMCTL_LOG"
	: >"$NOTIFY_LOG"
	: >"$HW_LOG"

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
fi
exit 0
EOF

	cat >"$BIN/date" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
	printf '%s\n' "$FAKE_NOW"
else
	exec /bin/date "$@"
fi
EOF

	cat >"$BIN/notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' notified >>"${BATS_TEST_TMPDIR}/notify.log"
EOF

	cat >"$BIN/hw-restart" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' restarted >>"${BATS_TEST_TMPDIR}/hw.log"
EOF

	chmod +x "$BIN/systemctl" "$BIN/date" "$BIN/notify" "$BIN/hw-restart"

	SCRIPT="$BATS_TEST_TMPDIR/monit-chia-restart.sh"
	ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
		ansible localhost -c local -m template \
		-a "src=${REPO_ROOT}/chia-blockchain/templates/monit-chia-restart.sh.j2 dest=${SCRIPT}" \
		-e "chia_service_base=chia" \
		-e "chia_monit_restart_min_seconds=600" \
		-e "chia_monit_restart_max_seconds=3600" \
		-e "chia_monit_restart_backoff_factor=2" \
		-e "chia_monit_restart_state_dir=${STATE_DIR}" >/dev/null
	sed -i \
		-e "s|^SYSTEMCTL=.*|SYSTEMCTL=\"${BIN}/systemctl\"|" \
		-e "s|^NOTIFY=.*|NOTIFY=\"${BIN}/notify\"|" \
		-e "s|^HW_RESTART=.*|HW_RESTART=\"${BIN}/hw-restart\"|" \
		-e "s|^STATE_DIR=.*|STATE_DIR=\"${STATE_DIR}\"|" \
		"$SCRIPT"
	chmod +x "$SCRIPT"

	export PATH="$BIN:$PATH"
	export FAKE_NOW=1000000
}

write_state() {
	local target_restarts=$1 target_last=$2
	printf 'target_restarts=%s\ntarget_last=%s\nhw_restarts=0\nhw_last=0\n' \
		"$target_restarts" "$target_last" >"$STATE_DIR/state"
}

restart_count() {
	grep -c '^restart chia.target$' "$SYSTEMCTL_LOG" || true
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
	! grep -q '^restart chia.target$' "$SYSTEMCTL_LOG"
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

@test "unknown command exits 2" {
	run "$SCRIPT" bogus
	[ "$status" -eq 2 ]
}
