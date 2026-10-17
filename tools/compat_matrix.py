#!/usr/bin/env python3
"""Client x interface-version compatibility matrix (issue #1399).

Checks, for every interface version the versioning policy lists:
  * the version has a row in tests/compat-matrix/matrix.json;
  * the policy's "Client support" column agrees with the matrix status;
  * a `supported` version has a historical WASM fixture whose SHA-256 matches
    its manifest and whose ABI exposes every call each client package makes.

Emits a Markdown table (stdout, and --report <file>) with pass/fail per version
per client. Exit 1 on any failure. `legacy` versions are reported as such, never
as pass. Usage: tools/compat_matrix.py [--report FILE]
"""
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "docs" / "interface-versioning-policy.md"
MATRIX = ROOT / "tests" / "compat-matrix" / "matrix.json"


def policy_versions(text):
    """{version: 'supported'|'legacy'} from the section-2 table's last column."""
    out = {}
    for line in text.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if line.startswith("|") and len(cells) >= 4 and cells[0].isdigit():
            out[cells[0]] = cells[-1].split()[0].lower()
    return out


def kv(path):
    return dict(l.split("=", 1) for l in Path(path).read_text().splitlines() if "=" in l)


def check(root=ROOT, policy=POLICY, matrix=MATRIX):
    m = json.loads(Path(matrix).read_text())
    claimed = policy_versions(Path(policy).read_text())
    errors, rows = [], []
    if not claimed:
        errors.append("no versions parsed from the policy table")
    for v, status in sorted(claimed.items()):
        entry = m["versions"].get(v)
        if entry is None:
            errors.append(f"v{v}: claimed by policy but missing from matrix")
            continue
        if entry["status"] != status:
            errors.append(f"v{v}: policy says '{status}', matrix says '{entry['status']}'")
    for v in m["versions"]:
        if v not in claimed:
            errors.append(f"v{v}: in matrix but not in policy table")
    for v, entry in sorted(m["versions"].items()):
        abi_funcs, fixture_err = set(), None
        if entry["status"] == "supported":
            try:
                man = kv(Path(root) / entry["manifest"])
                wasm = Path(root) / man["wasm_path"]
                digest = hashlib.sha256(wasm.read_bytes()).hexdigest()
                if digest != man["wasm_sha256"]:
                    fixture_err = "fixture sha256 mismatch"
                abi = (Path(root) / entry["abi"]).read_text()
                abi_funcs = set(re.findall(r"^function (\w+)\(", abi, re.M))
            except (OSError, KeyError) as e:
                fixture_err = f"fixture unreadable: {e}"
        for name, client in sorted(m["clients"].items()):
            if entry["status"] != "supported":
                rows.append((v, name, "legacy", entry["reason"]))
                continue
            missing = sorted(set(client["calls"]) - abi_funcs)
            if fixture_err or missing:
                why = fixture_err or f"missing in fixture ABI: {', '.join(missing)}"
                rows.append((v, name, "FAIL", why))
                errors.append(f"v{v}/{name}: {why}")
            else:
                rows.append((v, name, "pass", f"{len(client['calls'])} calls verified"))
    return rows, errors


def render(rows, errors):
    lines = ["# Client compatibility matrix", "", "| Interface | Client | Result | Detail |", "|---|---|---|---|"]
    lines += [f"| v{v} | {c} | {r} | {d} |" for v, c, r, d in rows]
    lines += ["", "**FAILED**" if errors else "**OK**"] + [f"- {e}" for e in errors]
    return "\n".join(lines) + "\n"


def main(argv):
    rows, errors = check()
    out = render(rows, errors)
    print(out)
    if "--report" in argv:
        Path(argv[argv.index("--report") + 1]).write_text(out)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
