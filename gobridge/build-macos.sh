#!/bin/sh
# Builds the bridge as a macOS dylib, one slice per arch in $ARCHS. Run from
# the Runner "Build Go Bridge" phase, it also embeds and signs the dylib in
# Contents/Frameworks.
set -e
cd "$(dirname "$0")"
# Xcode runs scripts with a minimal PATH.
export PATH="$PATH:/opt/homebrew/bin:/usr/local/go/bin:/usr/local/bin:$HOME/go/bin"

NAME=libtincan_bridge.dylib
mkdir -p build/macos
slices=""
for arch in ${ARCHS:-arm64 x86_64}; do
	case "$arch" in
		arm64) goarch=arm64 ;;
		x86_64) goarch=amd64 ;;
		*) echo "unsupported arch $arch" >&2; exit 1 ;;
	esac
	out="build/macos/$arch/$NAME"
	mkdir -p "build/macos/$arch"
	env CGO_ENABLED=1 GOOS=darwin GOARCH="$goarch" \
		go build -trimpath \
		-ldflags "-s -w -extldflags=-Wl,-install_name,@rpath/$NAME" \
		-buildmode=c-shared -o "$out" ./cshared
	rm -f "build/macos/$arch/libtincan_bridge.h"
	slices="$slices $out"
done
# shellcheck disable=SC2086
lipo -create $slices -output "build/$NAME"
echo "built gobridge/build/$NAME"

[ -n "$TARGET_BUILD_DIR" ] && [ -n "$FRAMEWORKS_FOLDER_PATH" ] || exit 0
dest="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$dest"
cp -f "build/$NAME" "$dest/$NAME"
if [ "$CODE_SIGNING_ALLOWED" != "NO" ]; then
	codesign --force --timestamp=none --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$dest/$NAME"
fi
echo "embedded $dest/$NAME"
