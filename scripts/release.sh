#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=$(cat "$ROOT_DIR/VERSION" | tr -d '[:space:]')

echo "======================================="
echo "  Side Screen - Release v$VERSION"
echo "======================================="
echo ""

# 1. Lint
echo "[1/3] Linting..."
cd "$ROOT_DIR/MacHost"
if command -v swiftlint &>/dev/null; then
    swiftlint lint --config .swiftlint.yml --strict --quiet
    echo "  Swift lint OK"
fi

cd "$ROOT_DIR/AndroidClient"
if command -v ktlint &>/dev/null; then
    ktlint "app/src/main/java/**/*.kt" --relative
    echo "  Kotlin lint OK"
fi

# 2. Commit & push
echo "[2/3] Pushing to GitHub..."
cd "$ROOT_DIR"
if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git status --short
    read -p "Commit message: " MSG
    git commit -m "$MSG"
fi
git push

# 3. Tag & release
echo "[3/3] Creating release tag..."
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "  Tag $VERSION already exists, skipping"
else
    git tag "$VERSION"
    git push origin "$VERSION"
    echo "  Tag $VERSION pushed - GitHub Actions will build the release"
fi

echo ""
echo "======================================="
echo "  Done! Check: gh release view $VERSION"
echo "======================================="
