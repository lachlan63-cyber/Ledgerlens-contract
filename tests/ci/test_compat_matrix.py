"""Tests for tools/compat_matrix.py (issue #1399)."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import compat_matrix  # noqa: E402


class CompatMatrixTest(unittest.TestCase):
    def test_repo_matrix_passes(self):
        rows, errors = compat_matrix.check()
        self.assertEqual(errors, [])
        self.assertTrue(any(r[2] == "pass" for r in rows))

    def _variant(self, mutate_matrix=None, policy_edit=None):
        d = Path(tempfile.mkdtemp())
        m = json.loads(compat_matrix.MATRIX.read_text())
        if mutate_matrix:
            mutate_matrix(m)
        (d / "m.json").write_text(json.dumps(m))
        text = compat_matrix.POLICY.read_text()
        if policy_edit:
            text = policy_edit(text)
        (d / "p.md").write_text(text)
        return compat_matrix.check(ROOT, d / "p.md", d / "m.json")

    def test_missing_version_in_matrix_fails(self):
        _, errors = self._variant(lambda m: m["versions"].pop("2"))
        self.assertTrue(any("v2" in e and "missing" in e for e in errors))

    def test_policy_matrix_disagreement_fails(self):
        _, errors = self._variant(lambda m: m["versions"]["1"].update(status="supported"))
        self.assertTrue(any("v1" in e for e in errors))

    def test_client_call_absent_from_abi_fails(self):
        _, errors = self._variant(lambda m: m["clients"]["python"]["calls"].append("nope"))
        self.assertTrue(any("v3/python" in e and "nope" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
