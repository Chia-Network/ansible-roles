"""Check a rendered Alloy config for invalid or duplicate block labels."""

import argparse
import re
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--require-label", action="append", default=[])
    parser.add_argument("--require-job", action="append", default=[])
    args = parser.parse_args()

    text = Path(args.path).read_text()
    blocks = re.findall(r'(?m)^([A-Za-z_][A-Za-z0-9_.]*)\s+"([^"]+)"\s*\{', text)
    labels = [label for _, label in blocks]

    bad = [
        label for label in labels if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", label)
    ]
    if bad:
        print("invalid Alloy block labels: " + ", ".join(bad), file=sys.stderr)
        return 1

    seen = set()
    dupes = set()
    for component, label in blocks:
        key = (component, label)
        if key in seen:
            dupes.add(f'{component} "{label}"')
        seen.add(key)
    if dupes:
        print(
            "duplicate Alloy components: " + ", ".join(sorted(dupes)),
            file=sys.stderr,
        )
        return 1

    for label in args.require_label:
        if label not in labels:
            print(f"missing Alloy block label: {label}", file=sys.stderr)
            return 1

    for job in args.require_job:
        if not re.search(r'job\s*=\s*"' + re.escape(job) + r'"', text):
            print(f"missing or sanitized Alloy job value: {job}", file=sys.stderr)
            return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
