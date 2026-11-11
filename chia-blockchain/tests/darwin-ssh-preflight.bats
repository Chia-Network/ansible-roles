#!/usr/bin/env bats

setup() {
	ROOT="$BATS_TEST_TMPDIR/root"
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$ROOT" "$BIN"
	cat >"$ROOT/sshd_config" <<'EOF'
#PasswordAuthentication yes
#PermitRootLogin prohibit-password
#KbdInteractiveAuthentication no
EOF
	printf 'ssh-ed25519 AAAATEST\n' >"$ROOT/authorized_keys"
	cat >"$BIN/sshd" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-t" ]; then
	if grep -q 'BadOption' "$3" 2>/dev/null; then
		echo "bad option" >&2
		exit 1
	fi
	exit 0
fi
if [ "$1" = "-T" ]; then
	echo "passwordauthentication ${FAKE_EFFECTIVE_PASSWORD:-no}"
	echo "kbdinteractiveauthentication no"
	echo "permitrootlogin no"
	exit 0
fi
exit 1
EOF
	chmod +x "$BIN/sshd"
}

run_preflight() {
	run env ANSIBLE_LOCALHOST_WARNING=False ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
		ansible-playbook "$BATS_TEST_DIRNAME/darwin-ssh-preflight.yml" \
		-e "test_root=$ROOT" -e "test_bin=$BIN" "$@"
}

@test "a missing authorized_keys refuses password login" {
	rm -f "$ROOT/authorized_keys"
	run_preflight
	[ "$status" -ne 0 ]
	[[ "$output" == *"Refusing to disable SSH password authentication"* ]]
}

@test "a non-empty authorized_keys applies all three hardening lines" {
	run_preflight
	[ "$status" -eq 0 ]
	grep -q '^PasswordAuthentication no$' "$ROOT/sshd_config"
	grep -q '^KbdInteractiveAuthentication no$' "$ROOT/sshd_config"
	grep -q '^PermitRootLogin no$' "$ROOT/sshd_config"
}

@test "the sshd config validation rejects a bad option" {
	printf 'BadOption yes\n' >>"$ROOT/sshd_config"
	run_preflight
	[ "$status" -ne 0 ]
	[[ "$output" == *"bad option"* ]]
}

@test "the effective sshd config refuses password authentication" {
	run_preflight -e fake_effective_password=yes
	[ "$status" -ne 0 ]
	[[ "$output" == *"still allows password"* ]]
}
