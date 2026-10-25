#!/bin/sh
# Builds the bridge as static archives for iOS, which has no c-shared mode.
# The Runner force-loads them (see OTHER_LDFLAGS in project.pbxproj), so
# Dart finds the symbols through DynamicLibrary.process(). Needs macOS + Xcode.
set -e
cd "$(dirname "$0")"

MIN=15.0
OUT=build/ios

build() { # sdk goarch clang-target out
	sdk="$1"; goarch="$2"; target="$3"; out="$4"
	sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
	flags="-target $target -isysroot $sysroot"
	mkdir -p "$(dirname "$out")"
	echo "building $target…"
	env CGO_ENABLED=1 GOOS=ios GOARCH="$goarch" CC="$(xcrun --sdk "$sdk" --find clang)" \
		CGO_CFLAGS="$flags" CGO_LDFLAGS="$flags" \
		go build -trimpath -ldflags "-s -w" -buildmode=c-archive -o "$out" ./cshared
	rm -f "${out%.a}.h"
}

build iphoneos        arm64 "arm64-apple-ios$MIN"            "$OUT/iphoneos/libtincan_bridge.a"
build iphonesimulator arm64 "arm64-apple-ios$MIN-simulator"  "$OUT/sim-arm64/libtincan_bridge.a"
build iphonesimulator amd64 "x86_64-apple-ios$MIN-simulator" "$OUT/sim-x86_64/libtincan_bridge.a"

mkdir -p "$OUT/iphonesimulator"
lipo -create "$OUT/sim-arm64/libtincan_bridge.a" "$OUT/sim-x86_64/libtincan_bridge.a" \
	-output "$OUT/iphonesimulator/libtincan_bridge.a"
rm -rf "$OUT/sim-arm64" "$OUT/sim-x86_64"

echo "built gobridge/$OUT/{iphoneos,iphonesimulator}/libtincan_bridge.a"
