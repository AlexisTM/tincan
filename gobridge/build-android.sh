#!/bin/sh
# Cross-compiles the bridge into jniLibs, so the APK carries one per ABI.
# minSdk is 28. The 16KB max-page-size flag matters: Android 15 devices
# run 16KB page kernels and refuse 4KB-aligned libraries.
set -e
cd "$(dirname "$0")"

NDK="${ANDROID_NDK_HOME:-$(ls -d "${ANDROID_HOME:-$HOME/.android}"/ndk/* 2>/dev/null | sort -V | tail -1)}"
[ -d "$NDK" ] || { echo "Android NDK not found; set ANDROID_NDK_HOME" >&2; exit 1; }
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
API=28
OUT="../android/app/src/main/jniLibs"

build() { # ABI GOARCH CC [extra go env...]
	abi="$1"; goarch="$2"; cc="$3"; shift 3
	mkdir -p "$OUT/$abi"
	echo "building $abi…"
	env CGO_ENABLED=1 GOOS=android GOARCH="$goarch" CC="$TC/$cc" "$@" \
		go build -trimpath \
		-ldflags "-s -w -extldflags=-Wl,-z,max-page-size=16384" \
		-buildmode=c-shared -o "$OUT/$abi/libtincan_bridge.so" ./cshared
	rm -f "$OUT/$abi/libtincan_bridge.h"
}

build arm64-v8a   arm64 "aarch64-linux-android$API-clang"
build armeabi-v7a arm   "armv7a-linux-androideabi$API-clang" GOARM=7
build x86_64      amd64 "x86_64-linux-android$API-clang"

echo "built $(ls "$OUT"/*/libtincan_bridge.so | wc -l) Android libraries under android/app/src/main/jniLibs/"
