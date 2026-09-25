#!/bin/sh
# Builds build/Threek.app (universal, macOS 15+). The version comes from the
# latest vX.Y.Z tag; the build number is the commit count.
# Signs with $SIGN_IDENTITY, else a Developer ID certificate, else the
# "Threek Self-Signed" certificate (see README), else ad-hoc.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
dd="$root/build/DerivedData"
app="$root/build/Threek.app"
version=$(git -C "$root" describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')
version=${version:-0.0.0}
build=$(git -C "$root" rev-list --count HEAD)
identities=$(security find-identity -p codesigning)
identity=${SIGN_IDENTITY:-$(echo "$identities" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
if [ -z "$identity" ] && echo "$identities" | grep -q '"Threek Self-Signed"'; then identity="Threek Self-Signed"; fi

(cd "$root" && xcodegen generate --quiet)
# The project's source list needs the adapter output directory to exist.
mkdir -p "$root/Build/Adapter"
xcodebuild -project "$root/Threek.xcodeproj" -scheme Threek -configuration Release \
    -derivedDataPath "$dd" -destination 'generic/platform=macOS' \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    CODE_SIGNING_ALLOWED=NO -quiet build

rm -rf "$app"
ditto "$dd/Build/Products/Release/Threek.app" "$app"
# License notices for Threek and the code built into it.
licenses="$app/Contents/Resources/Licenses"
mkdir -p "$licenses"
cp "$root/LICENSE" "$licenses/Threek.txt"
cp "$root/Vendor/mediaremote-adapter/LICENSE" "$licenses/mediaremote-adapter.txt"
cp "$dd/SourcePackages/checkouts/Sparkle/LICENSE" "$licenses/Sparkle.txt"

if [ -n "$identity" ]; then
    # Inside out, as Sparkle's docs describe. A stable certificate keeps the
    # app's identity across updates, so macOS remembers the Accessibility
    # grant. Notarization (Developer ID only) needs the hardened runtime;
    # without an Apple team ID it would refuse to load Sparkle.framework.
    case $identity in Developer\ ID*) flags="--timestamp --options runtime" ;; *) flags= ;; esac
    sign() { codesign --force $flags --sign "$identity" "$@"; }
    fw="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    sign "$fw/XPCServices/Installer.xpc" "$fw/XPCServices/Downloader.xpc" "$fw/Autoupdate" "$fw/Updater.app"
    sign "$app/Contents/Frameworks/Sparkle.framework"
    sign "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
    sign --entitlements "$root/Threek.entitlements" "$app"
    echo "signed: $identity"
else
    codesign --force --deep --sign - "$app"
    echo "signed: ad-hoc (macOS forgets the Accessibility grant on every rebuild)"
fi
codesign --verify --deep --strict "$app"
echo "$app ($version, build $build)"
