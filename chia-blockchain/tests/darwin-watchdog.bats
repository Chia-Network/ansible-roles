#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
	ROOT="$BATS_TEST_TMPDIR/root"
	BIN="$BATS_TEST_TMPDIR/bin"
	FAKE_STATE="$BATS_TEST_TMPDIR/state"
	LOG="$BATS_TEST_TMPDIR/watchdog.log"
	mkdir -p "$ROOT" "$BIN" "$FAKE_STATE" "$ROOT/venv/bin" "$ROOT/home/bin" "$ROOT/home/etc" "$ROOT/home/logs" "$ROOT/plists"
	: >"$LOG"
	export FAKE_STATE LOG
	export FAKE_NOW=1000000
	export FAKE_VDF_PORT=8000
	export FAKE_VDF_CONNS=3
	unset FAKE_BOARD_DOWN FAKE_TL_RECOVER_AFTER

	cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
case "$url" in
*/full_node/ports) printf '%s' "$(cat "$FAKE_STATE/fnp" 2>/dev/null || echo 200)" ;;
*/full_node) printf '%s' "$(cat "$FAKE_STATE/fn" 2>/dev/null || echo 200)" ;;
*/timelord)
	if [ -n "${FAKE_TL_RECOVER_AFTER:-}" ]; then
		c=$(($(cat "$FAKE_STATE/tl_count" 2>/dev/null || echo 0) + 1))
		echo "$c" >"$FAKE_STATE/tl_count"
		if [ "$c" -le "$FAKE_TL_RECOVER_AFTER" ]; then printf '500'; else printf '200'; fi
	else
		printf '%s' "$(cat "$FAKE_STATE/tl" 2>/dev/null || echo 200)"
	fi
	;;
*) printf '200' ;;
esac
EOF

	cat >"$BIN/netstat" <<'EOF'
#!/usr/bin/env bash
count="${FAKE_VDF_CONNS:-3}"
i=0
while [ "$i" -lt "$count" ]; do
	printf 'tcp4 0 0 127.0.0.1.5000%s 127.0.0.1.%s ESTABLISHED\n' "$i" "${FAKE_VDF_PORT:-8000}"
	i=$((i + 1))
done
EOF

	cat >"$BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
state="$FAKE_STATE/launchd"
mkdir -p "$state"
cmd="${1:-}"
case "$cmd" in
print)
	label="${2:-}"
	label="${label#system/}"
	if [ "${FAKE_BOARD_DOWN:-0}" = 1 ] && [[ "$label" == *hw-vdf* ]]; then exit 1; fi
	if [ -f "$state/$label" ]; then echo "state = running"; exit 0; fi
	exit 1
	;;
bootstrap)
	plist="${4:-}"
	label=$(basename "$plist" .plist)
	touch "$state/$label"
	printf 'bootstrap %s\n' "$label" >>"$FAKE_STATE/launchctl.log"
	exit 0
	;;
bootout)
	label="${2:-}"
	label="${label#system/}"
	rm -f "$state/$label"
	printf 'bootout %s\n' "$label" >>"$FAKE_STATE/launchctl.log"
	exit 0
	;;
kickstart)
	label="${@: -1}"
	label="${label#system/}"
	touch "$state/$label"
	printf 'kickstart %s\n' "$label" >>"$FAKE_STATE/launchctl.log"
	exit 0
	;;
enable | disable)
	printf '%s %s\n' "$cmd" "${2:-}" >>"$FAKE_STATE/launchctl.log"
	exit 0
	;;
esac
exit 0
EOF

	cat >"$BIN/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s" ]; then
	total=0
	if [ -s "$FAKE_STATE/slept" ]; then
		total=$(awk '{ s += $1 } END { printf "%d", s }' "$FAKE_STATE/slept")
	fi
	printf '%s\n' "$((FAKE_NOW + total))"
else
	exec /bin/date "$@"
fi
EOF

	cat >"$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-0}" >>"$FAKE_STATE/slept"
count=$(($(cat "$FAKE_STATE/sleep_count" 2>/dev/null || echo 0) + 1))
echo "$count" >"$FAKE_STATE/sleep_count"
if [ "$count" -ge "${FAKE_MAX_SLEEPS:-100}" ]; then
	kill -TERM "$PPID" 2>/dev/null || true
fi
exit 0
EOF

	cat >"$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE/sudo.log"
if [ "${1:-}" = "-u" ]; then shift 2; fi
if [ "${1:-}" = "env" ]; then
	shift
	while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do shift; done
fi
exec "$@"
EOF

	cat >"$BIN/stat" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-f" ] && [ "${2:-}" = "%z" ]; then
	wc -c <"${3:-/dev/null}"
else
	exec /usr/bin/stat "$@"
fi
EOF

	cat >"$ROOT/venv/bin/chia" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STATE/chia.log"
exit 0
EOF

	chmod +x "$BIN/curl" "$BIN/netstat" "$BIN/launchctl" "$BIN/date" \
		"$BIN/sleep" "$BIN/sudo" "$BIN/stat" "$ROOT/venv/bin/chia"

	# Seed every job as loaded so only the scenario-specific failures matter.
	mkdir -p "$FAKE_STATE/launchd"
	for label in net.chia.timelord.daemon net.chia.timelord.full-node \
		net.chia.timelord.timelord net.chia.timelord.chia-exporter \
		net.chia.timelord.chia-healthcheck net.chia.timelord.node-exporter \
		net.chia.timelord.watchdog net.chia.timelord.hw-vdf \
		net.chia.timelord.hw-vdf-2 net.chia.timelord.hw-vdf-3; do
		touch "$FAKE_STATE/launchd/$label"
		touch "$ROOT/plists/$label.plist"
	done
}

render_watchdog() {
	local topology=$1
	SCRIPT="$BATS_TEST_TMPDIR/watchdog-$topology.sh"
	ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
		ansible-playbook "$BATS_TEST_DIRNAME/darwin-watchdog-render.yml" \
		-e "watchdog_topology=$topology" \
		-e "watchdog_out=$SCRIPT" \
		-e "test_root=$ROOT" >/dev/null
	sed "s|^export PATH=.*|export PATH=\"$BIN:/usr/bin:/bin:/usr/sbin:/sbin\"|" "$SCRIPT" >"$SCRIPT.tmp"
	mv "$SCRIPT.tmp" "$SCRIPT"
	chmod +x "$SCRIPT"
}

run_watchdog() {
	local max_sleeps=$1
	run env WATCHDOG_BOOT_GRACE=0 WATCHDOG_LOG="$LOG" \
		FAKE_STATE="$FAKE_STATE" FAKE_MAX_SLEEPS="$max_sleeps" "$SCRIPT"
	[ "$status" -eq 0 ] || [ "$status" -eq 143 ]
}

@test "DEBUG is raised at the threshold and restored on recovery" {
	render_watchdog local-external
	export FAKE_TL_RECOVER_AFTER=5
	run_watchdog 40
	grep -q "log level raised to DEBUG after 2 failed health checks" "$LOG"
	grep -q "log level restored to INFO" "$LOG"
}

@test "DEBUG can be raised again after a full restart" {
	render_watchdog local-external
	printf '500\n' >"$FAKE_STATE/tl"
	run_watchdog 60
	[ "$(grep -c 'log level raised to DEBUG' "$LOG")" -ge 2 ]
}

@test "the watchdog restores the configured log level at startup" {
	render_watchdog local-external
	run_watchdog 3
	grep -q 'rpc full_node set_log_level' "$FAKE_STATE/chia.log"
	grep -q '"level":"INFO"' "$FAKE_STATE/chia.log"
}

@test "remote-node never restarts on the ports probe" {
	render_watchdog remote-node
	printf '500\n' >"$FAKE_STATE/fnp"
	run_watchdog 20
	grep -q 'CHECK_FULL_NODE_PORTS="0"' "$SCRIPT"
	! grep -q 'full_node-ports' "$LOG"
	! grep -q 'RESTART full stack' "$LOG"
}

@test "a restart uses the 600 second restart grace" {
	render_watchdog local-external
	printf '500\n' >"$FAKE_STATE/tl"
	run_watchdog 20
	grep -q 'grace until +600s' "$LOG"
	! grep -q 'grace until +3600s' "$LOG"
}

@test "vdf-only restarts when a board job is down" {
	render_watchdog vdf-only
	export FAKE_BOARD_DOWN=1
	run_watchdog 12
	grep -q 'a board job is not running' "$LOG"
	grep -q 'RESTART hw-vdf boards' "$LOG"
	! grep -q 'CHECK_VDF_CONNS' "$SCRIPT"
}

@test "vdf-only checks the remote VDF connection count" {
	render_watchdog vdf-only
	export FAKE_VDF_CONNS=0
	run_watchdog 12
	grep -q 'established=0 (want 3)' "$LOG"
	grep -q 'RESTART hw-vdf boards' "$LOG"
}
