#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Building CodexSwitch (Debug) ==="

# Generate project if needed
if [ ! -d "CodexSwitch.xcodeproj" ]; then
    echo "Generating Xcode project..."
    ruby generate_project.rb
fi

# Build
xcodebuild \
    -project CodexSwitch.xcodeproj \
    -target CodexSwitch \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    ARCHS=arm64 \
    2>&1 | tail -20

echo ""
echo "=== Build complete ==="
echo "App: build/Debug/CodexSwitch.app"
