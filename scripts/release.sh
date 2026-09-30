#!/bin/bash
# Cut a JR-Bar release, stopping at the first thing that is not ready.
#
#   scripts/release.sh --dry-run   run the checks below, write the notes, publish nothing
#   scripts/release.sh             the real thing (Jonathan runs it; it publishes)
#
# No argument is a real run, and --dry-run is the only argument it takes: an
# empty or extra argument is a usage error, so a wrapper that expands an unset
# variable into the flag cannot publish by accident.
#
# Before anything is built it refuses:
#   - a dirty or untracked working tree;
#   - a branch other than main, or no gh on PATH;
#   - a local main that is not exactly origin/main (read with ls-remote, so
#     nothing is fetched);
#   - a CHANGELOG whose top section is not "## <version>" for the version in
#     pyproject.toml, or still says "(unreleased)";
#   - a tag v<version> that already exists here or on origin;
#   - a build number (commits on HEAD, what CFBundleVersion uses) that is not
#     higher than the last release tag's, since Sparkle orders updates by it.
# It then writes the release notes from that CHANGELOG section to
# dist/release-notes-<version>.md and runs scripts/publish_release.sh with
# those notes on the draft before publication. That script owns the rest: the
# release gate (verify_macos_release.sh), the notarized package, the signed
# assets and whether the GitHub release already exists. A dry run stops
# before it, so a passing dry run is not a passing release. Nothing here runs
# in CI, and a dry run touches no remote beyond reading origin's main and tags.
set -euo pipefail

ROOT_DIR="${JRBAR_RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PYTHON="${PYTHON:-$ROOT_DIR/.venv/bin/python}"
[ -x "$PYTHON" ] || PYTHON="$(command -v python3)"
DRY_RUN=0

case "$#" in
    0) ;;
    1)
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
            *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
        esac
        ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
fail() { echo "release: $*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

[ -z "$(git status --porcelain --untracked-files=all)" ] || fail "the working tree is dirty or has untracked files"

branch="$(git branch --show-current)"
[ "$branch" = "main" ] || fail "releases are cut from main, and this is '${branch:-a detached HEAD}'"
command -v gh >/dev/null 2>&1 || fail "GitHub CLI is required. Install gh and run gh auth login."
if [ "${JRBAR_RELEASE_SKIP_REMOTE:-0}" = "1" ]; then
    say "origin: not checked (JRBAR_RELEASE_SKIP_REMOTE=1)"
else
    origin_main="$(git ls-remote origin refs/heads/main 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
    [ -n "$origin_main" ] && [ "$origin_main" = "$(git rev-parse HEAD)" ] || \
        fail "local main is not exactly origin/main: push it, or check that origin is reachable"
fi

version="$(sed -n 's/^version = "\([^"]*\)"$/\1/p' pyproject.toml | head -1)"
[ -n "$version" ] || fail "pyproject.toml names no version"
tag="v$version"

top="$(grep -m1 '^## ' CHANGELOG.md || true)"
case "$top" in
    "## $version"|"## $version "*) ;;
    *) fail "the CHANGELOG's top section is '$top', not '## $version'" ;;
esac
case "$top" in
    *unreleased*|*Unreleased*) fail "the CHANGELOG's top section still says unreleased: $top" ;;
esac

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    fail "tag $tag already exists here"
fi
if [ "${JRBAR_RELEASE_SKIP_REMOTE:-0}" != "1" ] && \
   git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    fail "tag $tag already exists on origin"
fi

build="${JRBAR_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
last_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [ -n "$last_tag" ]; then
    last_build="$(git rev-list --count "$last_tag")"
    [ "$build" -gt "$last_build" ] || fail "build $build is not higher than $last_tag's build $last_build"
    say "build $build (last release $last_tag was build $last_build)"
else
    say "build $build (first release)"
fi

mkdir -p dist
notes="dist/release-notes-$version.md"
# The top section's body: everything after its heading up to the next "## ".
awk -v heading="$top" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
' CHANGELOG.md | sed -e '/./,$!d' > "$notes"
[ -s "$notes" ] || fail "the CHANGELOG section for $version is empty"
say "notes: $notes ($(wc -l < "$notes" | tr -d ' ') lines)"

if [ "$DRY_RUN" -eq 1 ]; then
    say "would run: scripts/publish_release.sh --notes-file $notes"
    say "dry run: the checks above passed; the release gate, signing and the GitHub release check run when you publish; nothing was published"
    exit 0
fi

"$ROOT_DIR/scripts/publish_release.sh" --notes-file "$notes"
say "released $tag"
