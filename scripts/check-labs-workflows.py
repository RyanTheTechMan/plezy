#!/usr/bin/env python3
"""Guard the release-channel invariants that keep Labs independent of upstream."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def require(path: str, snippets: list[str]) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    missing = [snippet for snippet in snippets if snippet not in text]
    if missing:
        formatted = "\n".join(f"  - {snippet}" for snippet in missing)
        raise SystemExit(f"{path} is missing required Labs behavior:\n{formatted}")


require(
    ".github/workflows/labs-release.yml",
    ["gh workflow run labs-build.yml", '--repo "${{ github.repository }}"'],
)
require(
    ".github/workflows/labs-build.yml",
    [
        "name: Build Plezy Labs Desktop Artifacts",
        "--dart-define=PLEZY_LABS=true",
        "tag_name: ${{ inputs.labs_tag }}",
        "prerelease: true",
        "LABS_PACKAGE_ITERATION=labs.${{ inputs.labs_revision }}",
    ],
)
require(
    ".github/workflows/labs-sync.yml",
    [
        "scripts/resolve-labs-generated-conflicts.sh",
        "scripts/prepare-labs-translations.py",
        "scripts/check-labs-workflows.py",
        "gh workflow disable release.yml",
        "gh workflow disable update-packages.yml",
    ],
)
require(
    ".github/workflows/labs-watch.yml",
    [".draft == false and .prerelease == true"],
)

print("Plezy Labs workflow guards passed.")
