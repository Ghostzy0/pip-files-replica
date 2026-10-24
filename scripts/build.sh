#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
edition="${1:-replica}"
case "$edition" in
  baseline) name='Files Baseline'; version='0.1.0'; build='1';;
  replica) name='Files Replica'; version='0.1.0'; build='1';;
  pip) name='Pip Files'; version='0.1.0'; build='1';;
  baseline-plus) name='Files Baseline Plus'; version='0.2.0'; build='2';;
  pip-plus) name='Pip Files Plus'; version='0.2.0'; build='2';;
  *) echo 'Usage: build.sh [replica|baseline-plus|pip|pip-plus|baseline (legacy generic); default: replica]' >&2; exit 2;;
esac
swift build -c release --jobs 2
mkdir -p dist
stage_root="$(mktemp -d "dist/.package-$edition.XXXXXX")"
app="$stage_root/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/PipFiles "$app/Contents/MacOS/PipFiles"
# Keep local checkout paths from DWARF out of distributed executables. Sign only
# after stripping; the build cache retains its symbols for local diagnostics.
/usr/bin/strip -S "$app/Contents/MacOS/PipFiles"
/usr/bin/strings "$app/Contents/MacOS/PipFiles" > "$stage_root/executable-strings.txt"
if /usr/bin/grep -F -e "$PWD/" -e "$HOME/" "$stage_root/executable-strings.txt" > /dev/null; then
  echo 'Package still contains local build paths; refusing promotion.' >&2
  exit 1
else
  scan_status=$?
  if [ "$scan_status" -ne 1 ]; then
    echo 'Package path scan failed; refusing promotion.' >&2
    exit 1
  fi
fi
swift scripts/icon.swift "$stage_root/$edition.iconset" "$edition"
iconutil -c icns "$stage_root/$edition.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp LICENSE "$app/Contents/Resources/LICENSE"
cp THIRD-PARTY-NOTICES.md "$app/Contents/Resources/THIRD-PARTY-NOTICES.md"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>CFBundleExecutable</key><string>PipFiles</string>
<key>CFBundleIdentifier</key><string>com.pipreps.files.$edition</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundleDisplayName</key><string>$name</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>PipFilesEdition</key><string>$edition</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
# Atomically promote a verified package. A replaced bundle stays in the
# printed stage directory for recovery and later local cleanup.
output="dist/$name.app"
swift scripts/promote.swift "$app" "$output"
echo "$PWD/$output"
