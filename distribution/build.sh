#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
output="${1:?usage: build.sh /absolute/path/to/CodexIdleUpdate-preview.zip}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

app="$scratch/Codex Idle Update.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Library/LaunchAgents" "$contents/Resources"
cp "$source_dir/../LICENSE" "$contents/Resources/LICENSE"
for arch in arm64 x86_64; do
    xcrun swiftc -O -parse-as-library -warnings-as-errors -target "$arch-apple-macosx14.0" \
        "$source_dir/../main.swift" -o "$scratch/worker-$arch"
    xcrun swiftc -O -parse-as-library -warnings-as-errors -target "$arch-apple-macosx14.0" \
        "$source_dir/ControlApp.swift" -o "$scratch/control-$arch"
done
/usr/bin/lipo -create "$scratch/worker-arm64" "$scratch/worker-x86_64" -output "$contents/MacOS/codex-idle-update"
/usr/bin/lipo -create "$scratch/control-arm64" "$scratch/control-x86_64" -output "$contents/MacOS/CodexIdleUpdate"
cat > "$contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.codex.idle-update</string>
    <key>CFBundleExecutable</key><string>CodexIdleUpdate</string>
    <key>CFBundleName</key><string>Codex Idle Update</string>
    <key>CFBundleDisplayName</key><string>Codex Idle Update</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>CFBundleShortVersionString</key><string>0.1.2</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
cat > "$contents/Library/LaunchAgents/local.codex-idle-update.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.codex-idle-update</string>
    <key>BundleProgram</key><string>Contents/MacOS/codex-idle-update</string>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>300</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$contents/Info.plist" "$contents/Library/LaunchAgents/local.codex-idle-update.plist"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$contents/MacOS/codex-idle-update"
    /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app"
else
    /usr/bin/codesign --force --sign - "$contents/MacOS/codex-idle-update"
    /usr/bin/codesign --force --sign - "$app"
fi
/usr/bin/codesign --verify --deep --strict "$app"
[[ ! -e "$output" ]] || { echo "Output already exists: $output" >&2; exit 1; }
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$output"
