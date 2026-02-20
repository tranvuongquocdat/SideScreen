#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
echo "Current version: $CURRENT_VERSION"

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "${1:-patch}" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    *) echo "Usage: $0 [major|minor|patch]"; exit 1 ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"

# Only update VERSION file - everything else reads from it:
#   - build.gradle.kts reads ../VERSION at build time
#   - build_mac.sh reads VERSION at build time
#   - release.yml reads VERSION at build time
#   - README badge auto-fetches from GitHub Release API
#   - Website auto-fetches from GitHub Release API
echo "$NEW_VERSION" > "$VERSION_FILE"

echo ""
echo "  $CURRENT_VERSION -> $NEW_VERSION"
echo ""
echo "Next steps:"
echo "  git add VERSION && git commit -m \"chore: bump version to $NEW_VERSION\""
echo "  git tag $NEW_VERSION && git push && git push origin $NEW_VERSION"
