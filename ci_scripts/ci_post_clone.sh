#!/bin/bash
# Xcode Cloud post-clone hook.
#
# Writ.xcodeproj is generated from project.yml by XcodeGen. It is *also*
# committed, because Xcode Cloud validates the repository before it will accept
# a workflow at all and refuses one whose project is not at the root:
#
#   Project Writ.xcodeproj does not exist at the root of the repository
#   (exit 66)
#
# That check runs BEFORE this hook, so the hook cannot substitute for the
# committed file — the two are not alternatives. The committed copy satisfies
# the check; regenerating it here is what keeps it from mattering, because a
# committed generated file can go stale. Gridka's did, and it uploaded version
# 1.2.1 long after that train had closed in App Store Connect (f8e3203). CI
# also fails any pull request where the committed project has drifted from
# project.yml, so there are two independent guards against that failure.
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
