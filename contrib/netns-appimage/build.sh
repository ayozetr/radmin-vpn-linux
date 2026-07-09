#!/usr/bin/env bash
# Build the "netns edition" Radmin VPN AppImage.
#
# It wraps the *unmodified* upstream Radmin VPN AppImage so that it runs inside an
# isolated network namespace. That works around the "waiting for adapter / service
# never ready" hang that happens when the host has several network interfaces
# (docker / vmnet / tailscale / …). Running the original AppImage as-is (rather than
# its extracted contents) keeps its rendering identical to a direct launch.
#
# Usage:
#   ./build.sh [output.AppImage]        # default: ./RadminVPN-Linux-netns.AppImage
#
# Optional env overrides (otherwise both are downloaded and cached in ./.build-cache):
#   RADMIN_APPIMAGE=/path/to/RadminVPN-Linux-x86_64.AppImage
#   APPIMAGETOOL=/path/to/appimagetool          # a binary or an *.AppImage
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/RadminVPN-Linux-netns.AppImage}"
CACHE="$HERE/.build-cache"
mkdir -p "$CACHE"

RADMIN_URL="https://github.com/baptisterajaut/radmin-vpn-linux/releases/download/v0.3.4/RadminVPN-Linux-x86_64.AppImage"
TOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required" >&2; exit 1; }; }
need curl

# 1. The upstream Radmin VPN AppImage (bundled inside, run as-is at launch).
RADMIN="${RADMIN_APPIMAGE:-}"
if [ -z "$RADMIN" ]; then
    RADMIN="$CACHE/RadminVPN-Linux-x86_64.AppImage"
    if [ ! -f "$RADMIN" ]; then
        echo "[*] downloading upstream Radmin VPN AppImage…"
        curl -fL --progress-bar -o "$RADMIN" "$RADMIN_URL"
    fi
fi
[ -f "$RADMIN" ] || { echo "error: Radmin AppImage not found: $RADMIN" >&2; exit 1; }

# 2. appimagetool (system binary if present, else download the AppImage build).
TOOL="${APPIMAGETOOL:-}"
if [ -z "$TOOL" ]; then
    if command -v appimagetool >/dev/null 2>&1; then
        TOOL="appimagetool"
    else
        TOOL="$CACHE/appimagetool.AppImage"
        if [ ! -f "$TOOL" ]; then
            echo "[*] downloading appimagetool…"
            curl -fL --progress-bar -o "$TOOL" "$TOOL_URL"
        fi
        chmod +x "$TOOL"
    fi
fi

# 3. Assemble the AppDir in a temp dir (bundling the upstream AppImage as RadminVPN.AppImage).
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
cp -a "$HERE/AppDir" "$BUILD/AppDir"
cp "$RADMIN" "$BUILD/AppDir/RadminVPN.AppImage"
chmod +x "$BUILD/AppDir/AppRun" "$BUILD/AppDir/netns-orch.sh" \
         "$BUILD/AppDir/radmin-askpass.sh" "$BUILD/AppDir/RadminVPN.AppImage"

# 4. Build. APPIMAGE_EXTRACT_AND_RUN lets an appimagetool.AppImage run without FUSE;
#    a system appimagetool binary just ignores it.
echo "[*] building AppImage → $OUT"
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$TOOL" "$BUILD/AppDir" "$OUT"
chmod +x "$OUT"
echo "[+] done: $OUT"
