#!/usr/bin/env bash
# Picks the next version, puts it on main, and watches the release build it starts.
#
#   scripts/release.sh            # patch
#   scripts/release.sh minor
#   scripts/release.sh major
#
# What starts a release is the push, not this script: the workflow runs on any
# push to main and decides by asking whether the version in VERSION is already
# released. So a failure here does not stop the build, and pushing the same
# version again does nothing.
#
# The number is picked here rather than typed because a release workflow that is
# re-run at a version already published fails partway through, and the way to
# never be in that position is to never reuse one.
#
# Needs the gh CLI, authenticated.
set -euo pipefail

cd "$(dirname "$0")/.."

BUMP="${1:-patch}"
case "${BUMP}" in
  patch | minor | major) ;;
  *)
    echo "Usage: scripts/release.sh [patch|minor|major]  (default: patch)" >&2
    exit 1
    ;;
esac

# Checked before anything is written. The build would still run without gh, but
# this script could not follow it, and saying so afterwards is worse than saying
# so now.
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: gh CLI not found. Install it and run 'gh auth login'." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run 'gh auth login'." >&2
  exit 1
fi

# Only from a clean main that matches the remote: the build runs on what is on
# origin/main, so anything else here would release something never seen.
if [ "$(git branch --show-current)" != "main" ]; then
  echo "Error: not on the 'main' branch. Switch to main first." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Error: working tree is not clean. Commit or stash your changes first." >&2
  exit 1
fi
# The + is the same forced update the default refspec uses: a fetch after a force
# push still succeeds, and the comparison below is what catches the divergence.
git fetch origin +main:refs/remotes/origin/main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "Error: local HEAD does not match origin/main. Push (or pull) first." >&2
  exit 1
fi

CURRENT=$(tr -d '[:space:]' < VERSION)
if ! printf '%s' "$CURRENT" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
  echo "Error: VERSION is not X.Y.Z: ${CURRENT}" >&2
  exit 1
fi
MAJOR=${CURRENT%%.*}
REST=${CURRENT#*.}
MINOR=${REST%%.*}
PATCH=${REST#*.}
case "${BUMP}" in
  major) VERSION="$((MAJOR + 1)).0.0" ;;
  minor) VERSION="${MAJOR}.$((MINOR + 1)).0" ;;
  patch) VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
esac

echo "Bumping version: ${CURRENT} -> ${VERSION} (${BUMP})"
echo "${VERSION}" > VERSION

git add VERSION
git commit -m "Release v${VERSION}"
if ! git push origin HEAD:main; then
  echo "Error: push failed. The local release commit remains." >&2
  echo "  Undo it:  git reset --hard origin/main" >&2
  echo "  Or retry: git push origin HEAD:main" >&2
  exit 1
fi

echo "Waiting for the release build of v${VERSION} ..."

# The run takes a moment to appear, so it is polled for. What is looked for is a
# run whose head is the commit just pushed rather than the newest run: a push
# that lands in between must not be the one watched.
RELEASE_SHA=$(git rev-parse HEAD)

# Without `|| true`, a momentary API error would kill the loop through set -e
# (X=$(failing-cmd) exits). Here a failure means "not there yet".
# 60 x 2s = two minutes; the run list lags, and a shorter wait reads as absent.
RUN_ID=""
for _ in $(seq 1 60); do
  sleep 2
  RUN_ID=$(gh run list --workflow=release.yml --branch main --limit 20 \
    --json databaseId,headSha \
    --jq "[.[] | select(.headSha == \"${RELEASE_SHA}\")] | .[0].databaseId // \"\"" \
    2>/dev/null || true)
  if [ -n "${RUN_ID}" ]; then
    break
  fi
done
if [ -z "${RUN_ID}" ]; then
  # Not finding it says nothing about whether it is running; only that this
  # script cannot follow it.
  echo "Error: could not find the workflow run within 2 minutes." >&2
  echo "  The build may still be running. Check it with:" >&2
  echo "    gh run list --workflow=release.yml" >&2
  exit 1
fi
echo "Watching run ${RUN_ID} ..."
gh run watch "${RUN_ID}" --exit-status

echo "Done: https://github.com/cyberneura/octetly/releases/tag/v${VERSION}"
