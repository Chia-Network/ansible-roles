#!/usr/bin/env python3
"""Render chia-blockchain/templates/darwin/*.j2 for each Darwin topology.

Usage: render_darwin_templates.py OUTDIR
Writes OUTDIR/<topology>/<template name without .j2>.
"""

import pathlib
import shlex
import sys

import jinja2
import yaml

ROLE = pathlib.Path(__file__).resolve().parents[2] / "chia-blockchain"
TOPOLOGIES = ["local-internal", "local-external", "remote-node"]
JOB_VARS = {
    "name": "timelord",
    "label": "net.chia.timelord",
    "wrapper": "/Users/timelord/bin/chia-timelord-run.sh",
    "throttle": 10,
    "exit_timeout": 30,
}


def to_bool(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def make_env():
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(ROLE / "templates" / "darwin")),
        undefined=jinja2.StrictUndefined,
        trim_blocks=True,
        keep_trailing_newline=True,
    )
    env.filters["quote"] = lambda v: shlex.quote(str(v))
    env.filters["bool"] = to_bool
    return env


def resolve(env, variables):
    # Defaults reference each other; render string values until stable.
    for _ in range(10):
        changed = False
        for key, value in variables.items():
            if isinstance(value, str) and "{{" in value:
                new = env.from_string(value).render(variables)
                if new != value:
                    variables[key] = new
                    changed = True
        if not changed:
            return variables
    raise SystemExit("defaults did not resolve")


def main():
    out = pathlib.Path(sys.argv[1])
    env = make_env()
    defaults = yaml.safe_load((ROLE / "defaults" / "main.yml").read_text())
    for topology in TOPOLOGIES:
        variables = dict(defaults)
        variables.update(
            user="timelord",
            chia_root="/Users/timelord/.chia",
            chia_darwin_topology=topology,
            chia_darwin_hw_vdf_expected_serial="FT'TEST 01",
            chia_job=JOB_VARS,
        )
        if topology == "remote-node":
            variables["chia_timelord_full_node_peer_host"] = "10.0.0.5"
        variables = resolve(env, variables)
        dest = out / topology
        dest.mkdir(parents=True, exist_ok=True)
        for name in env.list_templates(extensions=["j2"]):
            text = env.get_template(name).render(variables)
            (dest / name[: -len(".j2")]).write_text(text)


if __name__ == "__main__":
    main()
