#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION_FILE="$ROOT_DIR/VERSION"

if [ ! -f "$VERSION_FILE" ]; then
    echo "ERROR: VERSION file not found at $VERSION_FILE"
    exit 1
fi

CURRENT_VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
echo "Current version: $CURRENT_VERSION"

# Parse semver
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "${1:-patch}" in
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        ;;
    patch)
        PATCH=$((PATCH + 1))
        ;;
    *)
        echo "Usage: $0 [major|minor|patch]"
        exit 1
        ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
echo "New version: $NEW_VERSION"

# Calculate Android versionCode (major*10000 + minor*100 + patch)
VERSION_CODE=$((MAJOR * 10000 + MINOR * 100 + PATCH))

# 1. Update VERSION file
echo "$NEW_VERSION" > "$VERSION_FILE"

# 2. Update Android build.gradle.kts
GRADLE_FILE="$ROOT_DIR/AndroidClient/app/build.gradle.kts"
if [ -f "$GRADLE_FILE" ]; then
    sed -i '' "s/versionCode = [0-9]*/versionCode = $VERSION_CODE/" "$GRADLE_FILE"
    sed -i '' "s/versionName = \"[^\"]*\"/versionName = \"$NEW_VERSION\"/" "$GRADLE_FILE"
    echo "  ✓ Updated Android build.gradle.kts (versionCode=$VERSION_CODE, versionName=$NEW_VERSION)"
fi

# 3. Update macOS build script Info.plist version
BUILD_MAC="$ROOT_DIR/scripts/build_mac.sh"
if [ -f "$BUILD_MAC" ]; then
    sed -i '' "s/<string>[0-9]*\.[0-9]*\.[0-9]*<\/string><!-- VERSION -->/<string>$NEW_VERSION<\/string><!-- VERSION -->/" "$BUILD_MAC"
    echo "  ✓ Updated build_mac.sh"
fi

echo ""
echo "Version bumped to $NEW_VERSION"
echo "Next steps:"
echo "  git add -A && git commit -m \"chore: bump version to $NEW_VERSION\""
echo "  git tag v$NEW_VERSION"
echo "  git push && git push --tags"
