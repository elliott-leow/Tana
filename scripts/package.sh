#!/bin/sh
# Build a local app bundle.  This deliberately does not install, launch, or
# request permissions for the application.
set -eu

usage() {
    printf '%s\n' "usage: scripts/package.sh [--no-build]"
}

no_build=0
case "${1-}" in
    "") ;;
    --no-build) no_build=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir="$root_dir/build"
binary="$build_dir/tana"
app="$build_dir/Tana.app"
identity=${TANA_SIGN_ID:-${HORIZONTALWM_SIGN_ID:-}}
if [ -z "$identity" ] && [ -f "$build_dir/signing-identity" ]; then
    identity=$(cat "$build_dir/signing-identity")
fi
identity=${identity:--}

if [ "$no_build" -eq 0 ]; then
    make -C "$root_dir" all
fi
if [ ! -f "$binary" ] || [ ! -x "$binary" ]; then
    printf '%s\n' "package.sh: missing executable $binary (run make all first)" >&2
    exit 1
fi

# The target is fixed under this repository's build directory.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/tana"
chmod 0755 "$app/Contents/MacOS/tana"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>Tana</string>
  <key>CFBundleExecutable</key><string>tana</string>
  <key>CFBundleIdentifier</key><string>dev.horizontalwm.manager</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Tana</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if ! /usr/bin/codesign --force --sign "$identity" --timestamp=none "$app/Contents/MacOS/tana"; then
    printf '%s\n' "package.sh: codesign failed for executable" >&2
    exit 1
fi
if ! /usr/bin/codesign --force --sign "$identity" --timestamp=none "$app"; then
    printf '%s\n' "package.sh: codesign failed for app bundle" >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$app"
if [ "$identity" != "-" ]; then
    (umask 077; printf '%s\n' "$identity" > "$build_dir/signing-identity")
fi

printf '%s\n' "created $app"
printf '%s\n' "signing identity: $identity"
