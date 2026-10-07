#!/usr/bin/env bash
# Cuts a release: bumps the version, runs the tests, builds the universal zip, publishes a GitHub
# release and bumps the Homebrew cask in stefansdev/homebrew-tap.
#
#   scripts/release.sh 1.2.0 notes.md
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> <notes.md>}"
NOTES="${2:?usage: scripts/release.sh <version> <notes.md>}"
TAP_REPO="stefansdev/homebrew-tap"

[[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean" >&2; exit 1; }

echo "==> Running tests"
swift build >/dev/null
TMPDEF="MiniNotes"   # debug builds use their own defaults domain
for t in selftest themetest; do
    out=$(MININOTES_NO_HOTKEY=1 MININOTES_SNAPSHOT=/dev/null MININOTES_ACTION=$t .build/debug/MiniNotes --background 2>&1 | tail -1)
    [[ "$out" == "ALL PASSED" ]] || { echo "$t: $out" >&2; exit 1; }
    echo "    $t: $out"
done

echo "==> Bumping version to $VERSION"
BUILD=$(( $(plutil -extract CFBundleVersion raw Resources/Info.plist) + 1 ))
plutil -replace CFBundleShortVersionString -string "$VERSION" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist
git commit -qam "Release $VERSION"

echo "==> Building"
./build.sh dist
SHA=$(shasum -a 256 build/MiniNotes.zip | cut -d' ' -f1)

echo "==> Publishing GitHub release v$VERSION"
git push -q origin HEAD
gh release create "v$VERSION" build/MiniNotes.zip --title "Mini Notes $VERSION" --notes-file "$NOTES"

echo "==> Bumping Homebrew cask"
TAP=$(mktemp -d)
gh repo clone "$TAP_REPO" "$TAP" -- -q
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/mini-notes.rb"
git -C "$TAP" commit -qam "mini-notes $VERSION"
git -C "$TAP" push -q
rm -rf "$TAP"

echo "==> Released $VERSION (sha256 $SHA)"
