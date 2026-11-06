"""Check the Darwin seed publish include applies service-user escalation."""

from __future__ import annotations

import argparse
from pathlib import Path
from typing import Any

from ansible.parsing.dataloader import DataLoader
from ansible.playbook.block import Block
from ansible.plugins.loader import init_plugin_loader
from ansible.template import Templar
from ansible.vars.manager import VariableManager

INCLUDE = "darwin-db-seed-publish.yml"


def load(loader: DataLoader, path: Path) -> Any:
    """Load YAML as template input on both supported ansible-core versions."""
    try:
        return loader.load_from_file(str(path), trusted_as_template=True)
    except TypeError:
        return loader.load_from_file(str(path))


def main() -> None:
    """Resolve the real publish include and helper escalation directives."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tasks", required=True, type=Path)
    parser.add_argument("--defaults", required=True, type=Path)
    parser.add_argument("--service-user", required=True)
    parser.add_argument("--remote-user", required=True)
    args = parser.parse_args()
    assert args.service_user != args.remote_user, "service user is the SSH caller"

    init_plugin_loader()
    loader = DataLoader()
    variable_manager = VariableManager(loader=loader)
    root = Block.load(
        load(loader, args.tasks),
        variable_manager=variable_manager,
        loader=loader,
    )
    include = next(
        (task for task in root.get_tasks() if task.args.get("_raw_params") == INCLUDE),
        None,
    )
    assert include is not None, f"the seed tasks do not include {INCLUDE}"
    apply = include.args.get("apply")
    assert isinstance(apply, dict), "the publish include has no apply directives"

    defaults = load(loader, args.defaults)
    assert defaults.get("chia_darwin_db_seed_become") is True, "production knob is off"
    values = dict(defaults, user=args.service_user, ansible_user_id=args.remote_user)
    templar = Templar(loader=loader, variables=values)
    become = templar.template(apply["become"])
    user = templar.template(apply["become_user"])
    assert become is True, f"apply become was {become!r}, not true"
    assert user == args.service_user, f"apply become_user was {user!r}"

    helper = Block.load(
        load(loader, args.tasks.parent / INCLUDE),
        parent_block=include.copy().build_parent_block(),
        variable_manager=variable_manager,
        loader=loader,
    )
    task = helper.block[0]
    become = templar.template(task.become)
    user = templar.template(task.become_user)
    assert become is True, f"helper become was {become!r}, not true"
    assert user == args.service_user, f"helper become_user was {user!r}"

    values["chia_darwin_db_seed_become"] = False
    become = Templar(loader=loader, variables=values).template(apply["become"])
    assert become is False, "apply become ignores chia_darwin_db_seed_become"
    print(f"publish/helper become_user={args.service_user}, not {args.remote_user}")


if __name__ == "__main__":
    main()
