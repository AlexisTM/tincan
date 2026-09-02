#!/bin/sh
# Builds the bridge as a C shared library for Dart FFI. The Linux build
# copies it into the app bundle; see linux/CMakeLists.txt.
set -e
cd "$(dirname "$0")"
mkdir -p build
CGO_ENABLED=1 go build -trimpath -ldflags "-s -w" -buildmode=c-shared \
	-o build/libtincan_bridge.so ./cshared
echo "built build/libtincan_bridge.so"
