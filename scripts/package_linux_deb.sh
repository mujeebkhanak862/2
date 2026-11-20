#!/usr/bin/env bash
# Linux .deb package banata hai (dpkg-deb chahiye).
#   flutter build linux --release
#   scripts/package_linux_deb.sh [version]
# Output: dist/universal-device-agent_<version>_amd64.deb
set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$ROOT/shared_app/build/linux/x64/release/bundle"
PKG="universal-device-agent"
STAGE="$ROOT/dist/${PKG}_${VERSION}_amd64"

if [ ! -x "$BUNDLE/device_agent" ]; then
  echo "Bundle nahi mila: $BUNDLE — pehle 'flutter build linux --release' chalayein." >&2
  exit 1
fi
command -v dpkg-deb >/dev/null || { echo "dpkg-deb install karein (dpkg)." >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/opt/$PKG" "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications"
cp -a "$BUNDLE/." "$STAGE/opt/$PKG/"
ln -s "/opt/$PKG/device_agent" "$STAGE/usr/bin/universal-device-agent"

# Desktop entry: Exec absolute path (PATH par depend nahi).
sed "s|^Exec=.*|Exec=/opt/$PKG/device_agent|" \
  "$ROOT/shared_app/linux/packaging/com.deviceagent.app.desktop" \
  > "$STAGE/usr/share/applications/com.deviceagent.app.desktop"

# Icons: hicolor set seedha system icon theme mein.
for d in "$ROOT"/shared_app/linux/packaging/icons/hicolor/*; do
  size="$(basename "$d")"
  mkdir -p "$STAGE/usr/share/icons/hicolor/$size/apps"
  cp "$d/apps/com.deviceagent.app.png" "$STAGE/usr/share/icons/hicolor/$size/apps/"
done

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Device Agent <noreply@example.invalid>
Depends: libgtk-3-0, libglib2.0-0, libpipewire-0.3-0, libx11-6, libxtst6, libturbojpeg0, libebook-1.2-21 | libebook-1.2-20 | libebook-1.2-19
Description: Universal Device Agent
 Apne devices ko authorized API ke zariye remotely manage/automate karne
 wala personal agent (screen, input, files, apps, browser).
CONTROL

cat > "$STAGE/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
exit 0
POST
chmod 755 "$STAGE/DEBIAN/postinst"

dpkg-deb --build --root-owner-group "$STAGE" "$ROOT/dist/${PKG}_${VERSION}_amd64.deb"
echo "Ready: dist/${PKG}_${VERSION}_amd64.deb"
