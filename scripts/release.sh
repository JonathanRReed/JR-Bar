#!/bin/bash
# Cut a JR-Bar release, stopping at the first thing that is not ready.
#
#   scripts/release.sh --dry-run   check everything and print what would run
#   scripts/release.sh             the real thing (Jonathan runs it; it publishes)
#
# Before anything is built it refuses:
#   - a dirty or untracked working tree;
#   - a CHANGELOG whose top section is not "## <version>" for the version in
#     pyproject.toml, or still says "(unreleased)";
#   - a tag v<version> that already exists here or on origin;
#   - a build number (commits on HEAD, what CFBundleVersion uses) that is not
#     higher than the last release tag's, since Sparkle orders updates by it.
# It then writes the release notes from that CHANGELOG section to
# dist/release-notes-<version>.md, runs scripts/publish_release.sh (verify,
# notarized package, signed assets, GitHub release) and puts those notes on
# the release. Nothing here runs in CI, and a dry run touches no remote but a
# read of origin's tags.
set -euo pipefail

ROOT_DIR="${JRBAR_RELEASE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PYTHON="${PYTHON:-$ROOT_DIR/.venv/bin/python}"
[ -x "$PYTHON" ] || PYTHON="$(command -v python3)"
DRY_RUN=0

case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
fail() { echo "release: $*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

[ -z "$(git status --porcelain --untracked-files=all)" ] || fail "the working tree is dirty or has untracked files"

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
    say "would run: scripts/publish_release.sh"
    say "would run: gh release edit $tag --repo JonathanRReed/JR-Bar --notes-file $notes"
    say "dry run: every check passed; nothing was published"
    exit 0
fi

"$ROOT_DIR/scripts/publish_release.sh"
gh release edit "$tag" --repo JonathanRReed/JR-Bar --notes-file "$notes"
say "released $tag"
