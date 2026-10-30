#!/bin/bash
# Xcode Cloud post-clone hook.
#
# Writ.xcodeproj is NOT in the repository — it is generated from project.yml by
# XcodeGen, and .gitignore excludes it. So a fresh Xcode Cloud clone contains no
# Xcode project at all, and without this hook the build fails before it starts.
#
# This is the opposite trade-off from Gridka, which commits its generated
# project. That let Xcode Cloud build it without a hook, and then bit back:
# commit f8e3203 fixes a build where the committed project was stale and App
# Store Connect rejected the upload with "train version 1.2.1 is closed". Not
# committing the project cannot go stale, but it does make this hook mandatory.
set -euo pipefail

cd "$CI_PRIMARY_REPOSITORY_PATH"

echo "==> Installing XcodeGen..."
brew install xcodegen

echo "==> Generating Writ.xcodeproj from project.yml..."
xcodegen generate

# The preview's offline dependencies (KaTeX, MathJax, Mermaid, highlight.js)
# ARE tracked, so unlike Gridka there is nothing to download here. Assert it
# rather than assume: if these ever become untracked, the app still builds and
# still launches, but every preview silently renders without math, diagrams or
# syntax highlighting — a failure that would reach the App Store looking fine.
echo "==> Checking bundled preview assets..."
for lib in katex mathjax mermaid highlight; do
  dir="Resources/preview/vendor/$lib"
  if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir")" ]; then
    echo "ERROR: $dir is missing or empty." >&2
    echo "  These are tracked in git and must arrive with the clone." >&2
    echo "  Locally, Scripts/fetch-vendor.sh repopulates them." >&2
    exit 1
  fi
done

echo "==> Verifying the version the build will actually carry..."
# Printed so the version is visible in the Xcode Cloud log next to the upload,
# which is the one place it is cheap to notice a stale or wrong version before
# it closes a train in App Store Connect.
xcodebuild -project Writ.xcodeproj -scheme Writ -configuration Release \
  -showBuildSettings 2>/dev/null \
  | grep -E ' MARKETING_VERSION =| CURRENT_PROJECT_VERSION =' || true

echo "==> ci_post_clone complete."
