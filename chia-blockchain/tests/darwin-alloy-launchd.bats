#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
	ROOT="$BATS_TEST_TMPDIR/root"
	BIN="$BATS_TEST_TMPDIR/bin"
	STATE="$BATS_TEST_TMPDIR/state"
	LOG="$STATE/launchctl.log"
	mkdir -p "$ROOT/bin" "$ROOT/plists" "$BIN" "$STATE"
	: >"$LOG"
	cat >"$BIN/brew" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = list ]; then
	echo "grafana-alloy 1.0"
	exit 0
fi
exit 0
EOF
	cat >"$BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
state="$FAKE_STATE/loaded"
cmd="${1:-}"
case "$cmd" in
print)
	[ -f "$state" ] && exit 0
	exit 1
	;;
bootout)
	rm -f "$state"
	printf 'bootout\n' >>"$FAKE_STATE/launchctl.log"
	;;
bootstrap)
	touch "$state"
	printf 'bootstrap\n' >>"$FAKE_STATE/launchctl.log"
	;;
enable | disable)
	printf '%s\n' "$cmd" >>"$FAKE_STATE/launchctl.log"
	;;
esac
exit 0
EOF
	chmod +x "$BIN/brew" "$BIN/launchctl"
	printf '#!/usr/bin/env bash\nexit 0\n' >"$ROOT/bin/alloy"
	chmod +x "$ROOT/bin/alloy"
	export FAKE_STATE="$STATE"
	export ANSIBLE_ROLES_PATH="$REPO_ROOT"
}

run_alloy() {
	run env ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
		ansible-playbook "$BATS_TEST_DIRNAME/darwin-alloy-launchd.yml" \
		-e "test_root=$ROOT" -e "test_bin=$BIN" \
		-e "test_owner=$(id -un)" -e "test_group=$(id -gn)" "$@"
}

@test "first start enables, bootstraps, then disables when boot is off" {
	run_alloy
	[ "$status" -eq 0 ]
	[ "$(grep -n '^enable$' "$LOG" | head -1 | cut -d: -f1)" -lt \
		"$(grep -n '^bootstrap$' "$LOG" | head -1 | cut -d: -f1)" ]
	[ "$(grep -n '^bootstrap$' "$LOG" | head -1 | cut -d: -f1)" -lt \
		"$(grep -n '^disable$' "$LOG" | head -1 | cut -d: -f1)" ]
}

@test "a loaded job is not bootstrapped again" {
	touch "$STATE/loaded"
	run_alloy
	[ "$status" -eq 0 ]
	! grep -q '^bootstrap$' "$LOG"
	grep -q '^disable$' "$LOG"
}

@test "a stopped job is booted out and left enabled for boot" {
	touch "$STATE/loaded"
	run_alloy -e test_start_now=false -e test_start_on_boot=true
	[ "$status" -eq 0 ]
	[ "$(grep -n '^bootout$' "$LOG" | head -1 | cut -d: -f1)" -lt \
		"$(grep -n '^enable$' "$LOG" | head -1 | cut -d: -f1)" ]
	! grep -q '^bootstrap$' "$LOG"
}

@test "the restart handler re-disables the job after bootstrap" {
	run_alloy
	[ "$status" -eq 0 ]
	[ "$(tail -4 "$LOG" | tr '\n' ' ')" = "bootout enable bootstrap disable " ]
}
