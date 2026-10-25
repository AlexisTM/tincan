#!/bin/sh
# Regenerates Android and iOS app icons and in-app assets from brand/logo-color.svg
# (the tile) and brand/logo-mono.svg. Needs rsvg-convert and ImageMagick.
set -e
cd "$(dirname "$0")/.."
RES=android/app/src/main/res
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Legacy launcher icon: the tile is the icon.
for spec in "mdpi 48" "hdpi 72" "xhdpi 96" "xxhdpi 144" "xxxhdpi 192"; do
	set -- $spec
	mkdir -p "$RES/mipmap-$1"
	rsvg-convert -w "$2" -h "$2" brand/logo-color.svg -o "$RES/mipmap-$1/ic_launcher.png"
done

# Adaptive layers: background is the tile colour (values/ic_launcher_background.xml),
# foreground is the mark without the tile, monochrome is logo-mono.svg.
# The mark's farthest point (the tail tip) sits 102 canvas units from the
# mark's centre, so the 256 canvas at 77% of the 108dp icon keeps it inside
# the 66dp safe circle; the mark's centre is (125.5,134.5), hence the nudge.
grep -v 'rx="56"' brand/logo-color.svg > "$TMP/foreground.svg"
sed 's/currentColor/#000000/g' brand/logo-mono.svg > "$TMP/mono.svg"
layer() { # svg size out
	inner=$(( $2 * 77 / 100 ))
	dx=$(( (25 * inner + 1280) / 2560 ))
	dy=$(( -(65 * inner + 1280) / 2560 ))
	rsvg-convert -w "$inner" -h "$inner" "$1" -o "$TMP/layer.png"
	magick -size "$2x$2" xc:none "$TMP/layer.png" -gravity center -geometry "+$dx$dy" -composite "$3"
}
for spec in "mdpi 108" "hdpi 162" "xhdpi 216" "xxhdpi 324" "xxxhdpi 432"; do
	set -- $spec
	dir="$RES/mipmap-$1"
	layer "$TMP/foreground.svg" "$2" "$dir/ic_launcher_foreground.png"
	layer "$TMP/mono.svg" "$2" "$dir/ic_launcher_monochrome.png"
done

# iOS masks the corners itself and rejects alpha, so it gets the tile full bleed.
IOS=ios/Runner/Assets.xcassets/AppIcon.appiconset
sed -e 's/viewBox="0 0 256 256"/viewBox="16 16 224 224"/' -e 's/rx="56"/rx="0"/' \
	brand/logo-color.svg > "$TMP/ios.svg"
for f in "$IOS"/Icon-App-*.png; do
	px=$(basename "$f" .png | sed -E 's/Icon-App-([0-9.]+)x[0-9.]+@([0-9])x/\1*\2/' | awk -F'*' '{ printf "%d", $1 * $2 + 0.5 }')
	rsvg-convert -w "$px" -h "$px" "$TMP/ios.svg" -o "$TMP/ios.png"
	magick "$TMP/ios.png" -alpha off "PNG24:$f"
done

mkdir -p assets
rsvg-convert -w 512 -h 512 brand/logo-color.svg -o assets/logo.png
cp brand/logo-color.svg assets/logo.svg
cp brand/logo-mono.svg assets/logo-mono.svg

echo "icons regenerated from brand/logo-color.svg and brand/logo-mono.svg"
