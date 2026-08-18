#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
install_root="${1:-${HOME}/Applications}"
app_bundle="$install_root/AI Subscription Status.app"

cd "$project_dir"
swift build -c release

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
/usr/bin/install -m 755 ".build/release/AISubscriptionStatus" "$app_bundle/Contents/MacOS/AISubscriptionStatus"
/usr/bin/install -m 644 "Resources/Info.plist" "$app_bundle/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$app_bundle" >/dev/null

echo "$app_bundle"
