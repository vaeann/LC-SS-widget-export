#!/bin/sh
# Linux cross-compile for the iOS arm64 dylib: plain clang (LLVM) with an
# Apple target, ld64.lld as the Mach-O linker, and a community iPhoneOS SDK
# (theos/sdks). Mirrors LCOrbit/Build/build.sh but skips the macOS-only
# harness suites (they need xcrun + the macOS SDK).
#
# Required environment:
#   SDK   path to an iPhoneOS*.sdk
#   LDID  optional path to an ldid binary (fallback: `ldid` on PATH)
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${SDK:?set SDK to an iPhoneOS.sdk path}"
LDID="${LDID:-ldid}"
OUT="${1:-$ROOT/dist/LCFloatingMenu.dylib}"
# Embed the source commit so Settings can compare against GitHub accurately.
BUILD_COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
case "$BUILD_COMMIT" in
    *[!0-9a-f]*|"") BUILD_COMMIT="unknown" ;;
esac
BUILD_COMMIT_FLAG="-DFM_BUILD_COMMIT=@\"$BUILD_COMMIT\""

# Pure-source assertions: cheap and platform-independent.
python3 "$ROOT/LCOrbit/Tests/check-running-close-controls.py"
python3 "$ROOT/LCOrbit/Tests/check-host-gestures.py"

mkdir -p "$(dirname "$OUT")"
# -target carries the deployment min version (16.0); ld64.lld resolves the
# SDK's .tbd stubs for every -framework argument.
clang "$BUILD_COMMIT_FLAG" -target arm64-apple-ios16.0 \
    -isysroot "$SDK" -fobjc-arc -O2 -dynamiclib -fuse-ld=lld \
    -framework Foundation -framework UIKit -framework QuartzCore -framework AVFoundation \
    -framework CoreGraphics -framework Security -lobjc \
    -install_name '@rpath/LCFloatingMenu.dylib' \
    -Wl,-U,'_OBJC_CLASS_$_UITraitUserInterfaceStyle' \
    "$ROOT/LCOrbit/Core/LCOrbitCore.m" \
    "$ROOT/LCOrbit/Core/LCOrbitHost.m" \
    "$ROOT/LCOrbit/Core/LCOrbitGuestService.m" \
    "$ROOT/LCOrbit/Core/LCOrbitMultitask.m" \
    "$ROOT/LCOrbit/Core/LCOrbitAutomaticPiP.m" \
    "$ROOT/LCOrbit/Core/LCOrbitMultitaskUI.m" \
    "$ROOT/LCOrbit/Core/LCOrbitHostSettings.m" \
    "$ROOT/LCOrbit/Core/LCOrbitEventBus.m" \
    "$ROOT/LCOrbit/Core/LCOrbitOverlayManager.m" \
    "$ROOT/LCOrbit/Core/LCOrbitStorage.m" \
    "$ROOT/LCOrbit/Core/LCOrbitGitHub.m" \
    "$ROOT/LCOrbit/Core/LCOrbitUpdateRelease.m" \
    "$ROOT/LCOrbit/Core/LCOrbitLog.m" \
    "$ROOT/LCOrbit/Core/LCOrbitTweakAudit.m" \
    "$ROOT/LCOrbit/Core/LCOrbitTweakSync.m" \
    "$ROOT/LCOrbit/Core/LCOrbitTweakCenter.m" \
    "$ROOT/LCOrbit/Core/LCOrbitPluginUpdater.m" \
    "$ROOT/LCOrbit/Core/LCOrbitTweakCenterViews.m" \
    "$ROOT/LCOrbit/Core/LCOrbitSharedTweaksViewController.m" \
    "$ROOT/LCOrbit/Core/LCOrbitLogViewer.m" \
    "$ROOT/LCOrbit/Modules/HiddenBead/FMHiddenBeadModule.m" \
    "$ROOT/LCOrbit/Modules/KeepAlive/FMKeepAlive.m" \
    "$ROOT/LCFloatingMenu/LCFloatingMenu.m" \
    -o "$OUT"
file "$OUT"
# Pseudo-sign so the artifact exports cleanly; LC re-signs on import anyway.
"$LDID" -S "$OUT"
