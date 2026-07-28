#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 OFFICIAL_TAG" >&2
  exit 2
fi

OFFICIAL_TAG=$1
ROOT=$(git rev-parse --show-toplevel)
CANDIDATE_LOG=$(mktemp)
BASELINE_LOG=$(mktemp)
BASELINE_ROOT=$(mktemp -d)
BASELINE_WORKTREE="$BASELINE_ROOT/official"

cleanup() {
  git -C "$ROOT" worktree remove --force "$BASELINE_WORKTREE" >/dev/null 2>&1 || true
  rmdir "$BASELINE_ROOT" >/dev/null 2>&1 || true
  rm -f "$CANDIDATE_LOG" "$BASELINE_LOG"
}
trap cleanup EXIT

has_known_analyzer_crash() {
  local log=$1
  grep -Fq "An error occurred while executing an analyzer plugin: Null check operator used on a null value" "$log" &&
    grep -Fq "CommentReferenceResolver._resolveSimpleIdentifier" "$log" &&
    grep -Fq "Analyzer check failed: unexpected stderr output (exit 2)" "$log"
}

normalized_diagnostics() {
  local log=$1
  local root=$2
  grep -E '^(ERROR|WARNING|INFO)\|' "$log" | sed "s|$root/|<root>/|g" || true
}

set +e
scripts/ci_checks.sh 2>&1 | tee "$CANDIDATE_LOG"
CANDIDATE_STATUS=${PIPESTATUS[0]}
set -e

if [[ $CANDIDATE_STATUS -eq 0 ]]; then
  exit 0
fi

FAILURE_COUNT=$(grep -c '^  FAIL  ' "$CANDIDATE_LOG" || true)
if [[ $FAILURE_COUNT -ne 1 ]] ||
  ! grep -Fq '  FAIL  analyzer errors, warnings, unexpected infos, or tool failure' "$CANDIDATE_LOG" ||
  ! has_known_analyzer_crash "$CANDIDATE_LOG"; then
  echo "Labs candidate failed checks for a reason other than the known upstream analyzer crash." >&2
  exit "$CANDIDATE_STATUS"
fi

echo "Candidate hit the known analyzer crash; reproducing it on official $OFFICIAL_TAG."
git -C "$ROOT" worktree add --detach "$BASELINE_WORKTREE" "$OFFICIAL_TAG"
(
  cd "$BASELINE_WORKTREE"
  flutter pub get
  (cd packages/saf_util && flutter pub get)
  dart run scripts/check_analyzer.dart
) 2>&1 | tee "$BASELINE_LOG" || BASELINE_STATUS=${PIPESTATUS[0]}
BASELINE_STATUS=${BASELINE_STATUS:-0}

if [[ $BASELINE_STATUS -eq 0 ]]; then
  echo "Official $OFFICIAL_TAG unexpectedly passed analyzer validation, so the candidate crash cannot be accepted." >&2
  exit "$CANDIDATE_STATUS"
fi

if ! diff -u \
  <(normalized_diagnostics "$BASELINE_LOG" "$BASELINE_WORKTREE") \
  <(normalized_diagnostics "$CANDIDATE_LOG" "$ROOT"); then
  echo "Labs candidate analyzer diagnostics differ from official $OFFICIAL_TAG." >&2
  exit "$CANDIDATE_STATUS"
fi

if has_known_analyzer_crash "$BASELINE_LOG"; then
  echo "::warning::Official $OFFICIAL_TAG reproduces the same analyzer-plugin crash and diagnostics; accepting the upstream baseline failure."
elif grep -Eq '^Analyzer check failed: unexpected (ERROR|WARNING|INFO) diagnostic:' "$BASELINE_LOG"; then
  echo "::warning::Official $OFFICIAL_TAG emitted identical diagnostics without reproducing the nondeterministic analyzer-plugin crash; accepting the upstream baseline failure."
else
  echo "Official $OFFICIAL_TAG failed analyzer validation for an unexpected reason." >&2
  exit "$CANDIDATE_STATUS"
fi
