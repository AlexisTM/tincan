#!/usr/bin/env bash
# Play Store images in tool/store/build/listing/. Needs Chromium and Pillow.
set -euo pipefail
cd "$(dirname "$0")/../.."
flutter test tool/store/screens_test.dart
python3 tool/store/make_listing.py
