#!/usr/bin/env python3
"""Tests for deterministic Plezy Labs reconstruction."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("rebuild-labs.py")


def run(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=repo,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def git(repo: Path, *args: str) -> str:
    return run(repo, "git", *args).stdout.strip()


def write(repo: Path, path: str, value: str) -> None:
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(value, encoding="utf-8")


def commit(repo: Path, message: str, files: dict[str, str]) -> str:
    for path, value in files.items():
        write(repo, path, value)
    git(repo, "add", ".")
    git(repo, "commit", "-m", message)
    return git(repo, "rev-parse", "HEAD")


class RebuildLabsTest(unittest.TestCase):
    def make_repo(self, *, official_has_feature: bool = False, conflict: bool = False) -> tuple[Path, tempfile.TemporaryDirectory[str]]:
        temporary = tempfile.TemporaryDirectory()
        repo = Path(temporary.name)
        git(repo, "init", "-b", "main")
        git(repo, "config", "user.name", "Test User")
        git(repo, "config", "user.email", "test@example.com")
        commit(
            repo,
            "official 1.0.0",
            {"pubspec.yaml": "version: 1.0.0+1\n", "shared.txt": "official\n"},
        )
        git(repo, "tag", "1.0.0")

        git(repo, "switch", "-c", "feature/example")
        feature_value = "feature\n"
        feature_commit = commit(repo, "feat: example", {"feature.txt": feature_value})

        git(repo, "switch", "main")
        if official_has_feature:
            git(repo, "cherry-pick", feature_commit)
        official_files = {"pubspec.yaml": "version: 1.0.1+2\n", "official.txt": "minor\n"}
        if conflict:
            official_files["shared.txt"] = "official changed\n"
        commit(repo, "official 1.0.1", official_files)
        git(repo, "tag", "1.0.1")

        git(repo, "switch", "-c", "labs", "1.0.0")
        core_value = "labs\n" if conflict else "official\nlabs\n"
        commit(repo, "feat(labs): base release channel", {"shared.txt": core_value, "labs.txt": "updater\n"})
        manifest = {
            "schema_version": 1,
            "features": [
                {
                    "id": "example",
                    "enabled": True,
                    "source_ref": "feature/example",
                    "commits": [feature_commit],
                    "description": "Example feature",
                }
            ],
        }
        commit(repo, "chore(labs): register enabled feature overlays", {"tool/labs_features.json": json.dumps(manifest, indent=2) + "\n"})
        if not official_has_feature:
            git(repo, "cherry-pick", feature_commit)
        return repo, temporary

    def rebuild(self, repo: Path) -> subprocess.CompletedProcess[str]:
        return run(
            repo,
            "python3",
            str(SCRIPT),
            "--repo",
            str(repo),
            "--official-tag",
            "1.0.1",
            "--report",
            str(repo / ".git" / "report.json"),
            "--skip-translation-generation",
            check=False,
        )

    def test_rebuilds_linear_stack_on_new_official_tag(self) -> None:
        repo, temporary = self.make_repo()
        self.addCleanup(temporary.cleanup)
        result = self.rebuild(repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(repo, "merge-base", "1.0.1", "HEAD"), git(repo, "rev-parse", "1.0.1"))
        subjects = git(repo, "log", "--reverse", "--format=%s", "1.0.1..HEAD").splitlines()
        self.assertEqual(
            subjects,
            [
                "feat(labs): base release channel on Plezy 1.0.1",
                "chore(labs): register enabled feature overlays",
                "feat: example",
            ],
        )
        self.assertEqual((repo / "official.txt").read_text(), "minor\n")
        self.assertEqual((repo / "labs.txt").read_text(), "updater\n")
        self.assertEqual((repo / "feature.txt").read_text(), "feature\n")

    def test_skips_feature_patch_already_in_official_release(self) -> None:
        repo, temporary = self.make_repo(official_has_feature=True)
        self.addCleanup(temporary.cleanup)
        result = self.rebuild(repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads((repo / ".git" / "report.json").read_text())
        self.assertEqual(report["applied_features"], [])
        self.assertEqual(report["skipped_official_features"][0]["id"], "example")

    def test_reports_core_conflict_without_release_candidate(self) -> None:
        repo, temporary = self.make_repo(conflict=True)
        self.addCleanup(temporary.cleanup)
        result = self.rebuild(repo)
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((repo / ".git" / "report.json").read_text())
        self.assertEqual(report["status"], "failure")
        self.assertEqual(report["stage"], "labs-base")
        self.assertIn("shared.txt", report["files"])


if __name__ == "__main__":
    unittest.main()
