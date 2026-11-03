#!/usr/bin/env bash
set -euo pipefail

baseline_ref=${1:-origin/main}
repo_root=$(git rev-parse --show-toplevel)
template_dir="${repo_root}/chia-blockchain/templates"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

cat >"${workdir}/vars.yml" <<'EOF'
chia_service_base: chia
chia_monit_progress_restart_seconds: 480
chia_healthcheck_threshold_seconds: 60
chia_monit_cycle_seconds: 60
chia_healthcheck_port: 9950
chia_monit_log_debug_threshold: 2
chia_monit_failure_threshold: 3
chia_monit_hw_vdf_failure_threshold: 5
chia_monit_restart_script: "/etc/monit/monit-chia-restart-chia.sh"
EOF

export ANSIBLE_LOCALHOST_WARNING=False
export ANSIBLE_INVENTORY_UNPARSED_WARNING=False

render() {
	local src=$1 dest=$2 extra=$3
	ansible localhost -c local -m template \
		-a "src=${src} dest=${dest}" \
		-e @"${workdir}/vars.yml" \
		-e "$extra" >/dev/null
}

for name in monit_config.j2 monit_hw_vdf.j2; do
	git -C "$repo_root" show "${baseline_ref}:chia-blockchain/templates/${name}" >"${workdir}/baseline-${name}"
done

services_options=(
	'["full-node","timelord"]'
	'["full-node"]'
)
backoff_options=('false' '"false"' '"no"')

total=0
matched=0
failures=0
first_diff=0

for services in "${services_options[@]}"; do
	for ports in true false; do
		for alert in true false; do
			for healthcheck in true false; do
				for backoff in "${backoff_options[@]}"; do
					total=$((total + 1))
					extra=$(printf '{"chia_enabled_services":%s,"chia_monit_check_full_node_ports":%s,"chia_monit_alert_on_restart":%s,"chia_add_healthcheck_service":%s,"chia_monit_restart_backoff":%s}' \
						"$services" "$ports" "$alert" "$healthcheck" "$backoff")
					combo="services=${services} ports=${ports} alert=${alert} healthcheck=${healthcheck} backoff=${backoff}"
					combo_failed=0
					for name in monit_config.j2 monit_hw_vdf.j2; do
						render "${template_dir}/${name}" "${workdir}/actual-${name}" "$extra"
						render "${workdir}/baseline-${name}" "${workdir}/expected-${name}" "$extra"
						if cmp -s "${workdir}/expected-${name}" "${workdir}/actual-${name}"; then
							continue
						fi
						combo_failed=1
						failures=$((failures + 1))
						printf 'FAIL %s template=%s\n' "$combo" "$name"
						if [ "$first_diff" -eq 0 ]; then
							diff -u "${workdir}/expected-${name}" "${workdir}/actual-${name}" || true
							first_diff=1
						fi
					done
					if [ "$combo_failed" -eq 0 ]; then
						matched=$((matched + 1))
					fi
				done
			done
		done
	done
done

if [ "$failures" -ne 0 ]; then
	printf '%d of %d combinations matched; %d template render(s) differed\n' "$matched" "$total" "$failures"
	exit 1
fi

for pair in "monit_config.j2 target" "monit_hw_vdf.j2 hw-vdf"; do
	name=${pair% *}
	command_name=${pair#* }
	render "${template_dir}/${name}" "${workdir}/backoff-${name}" \
		'{"chia_enabled_services":["full-node"],"chia_monit_check_full_node_ports":false,"chia_monit_alert_on_restart":false,"chia_add_healthcheck_service":true,"chia_monit_restart_backoff":true}'
	expected="restart program = \"/etc/monit/monit-chia-restart-chia.sh ${command_name}\""
	if ! grep -Fq "$expected" "${workdir}/backoff-${name}"; then
		printf 'FAIL backoff=true %s is missing: %s\n' "$name" "$expected"
		exit 1
	fi
	if grep -Fq 'reset-' "${workdir}/backoff-${name}"; then
		printf 'FAIL backoff=true %s contains reset-\n' "$name"
		exit 1
	fi
done

printf '%d combinations matched\n' "$matched"
