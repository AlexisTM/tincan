#!/bin/sh
# Installs a built Tincan bundle for this user (or under PREFIX), with its
# menu entry and icon.
#
#   linux/install.sh [bundle]      install (default: the release bundle)
#   linux/install.sh --uninstall   remove it again
set -eu

here=$(cd "$(dirname "$0")" && pwd)
app=com.aukmind.tincan
prefix=${PREFIX:-$HOME/.local}
share=$prefix/share
dest=$prefix/lib/tincan
desktop=$share/applications/$app.desktop
icon=$share/icons/hicolor/512x512/apps/$app.png

refresh() {
  update-desktop-database "$share/applications" 2>/dev/null || true
  gtk-update-icon-cache -q -t "$share/icons/hicolor" 2>/dev/null || true
}

if [ "${1:-}" = "--uninstall" ]; then
  rm -rf "$dest"
  rm -f "$desktop" "$icon"
  refresh
  echo "Tincan removed from $prefix"
  exit 0
fi

bundle=${1:-}
if [ -z "$bundle" ]; then
  for arch in x64 arm64; do
    if [ -x "$here/../build/linux/$arch/release/bundle/tincan" ]; then
      bundle=$here/../build/linux/$arch/release/bundle
      break
    fi
  done
fi
if [ -z "$bundle" ] || [ ! -x "$bundle/tincan" ]; then
  echo "No Tincan bundle found. Build one first: make linux" >&2
  exit 1
fi

rm -rf "$dest"
mkdir -p "$dest" "$share/applications" "$(dirname "$icon")"
cp -R "$bundle/." "$dest/"
cp "$here/../assets/logo.png" "$icon"
# Desktop Entry quoting: \ $ ` " escaped twice, % doubled; then escaped for sed.
exec_line=$(printf '%s' "$dest/tincan" | sed -e 's/\\/\\\\\\\\/g' -e 's/["`$]/\\\\&/g' -e 's/%/%%/g')
exec_line=$(printf '%s' "\"$exec_line\"" | sed -e 's/[\\&|]/\\&/g')
sed "s|@EXEC@|$exec_line|" "$here/$app.desktop" > "$desktop"
refresh
echo "Tincan installed in $dest"
