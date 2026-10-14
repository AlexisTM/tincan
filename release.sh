#!/usr/bin/env bash
# Usage: ./release.sh <version>      e.g. ./release.sh 0.1.0
#        DRY_RUN=1 ./release.sh <version>   builds + prints notes, no commit/tag/push
#
# Builds Linux x64 and Android (split APKs + Play bundle), then bumps
# pubspec, prepends CHANGELOG.md, tags, pushes and publishes a GitHub
# release. Builds run first so a broken build never leaves a pushed tag.
set -euo pipefail
cd "$(dirname "$0")"

version="${1:?usage: ./release.sh <version>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z" >&2; exit 1; }
dry="${DRY_RUN:-}"

die() { echo "release: $*" >&2; exit 1; }

[[ "$(git branch --show-current)" == main ]] || die "not on main"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "working tree has uncommitted changes"
git rev-parse -q --verify "refs/tags/$version" >/dev/null && die "tag $version already exists"
[[ -f android/key.properties ]] || die "android/key.properties missing; Gradle would sign with the debug key"
command -v gh >/dev/null || die "gh not installed"

build_number=$(( $(sed -n 's/^version: .*+\([0-9]*\)$/\1/p' pubspec.yaml) + 1 ))

prev=$(git describe --tags --abbrev=0 2>/dev/null || true)
notes=$(git log --no-merges --pretty='- %s (%h)' ${prev:+"$prev"..HEAD} | grep -v '^- Release [0-9]' || true)
[[ -n "$notes" ]] || notes="- No changes since $prev"

# This machine exports a deprecated ANDROID_SDK_HOME that AGP rejects.
unset ANDROID_SDK_HOME
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$HOME/.android-user}"

flags=(--release --build-name="$version" --build-number="$build_number")
gobridge/build.sh
gobridge/build-android.sh
flutter build linux "${flags[@]}"
flutter build apk --split-per-abi "${flags[@]}"
flutter build appbundle "${flags[@]}"

out="build/release/$version"
rm -rf "$out" && mkdir -p "$out"
tar -C build/linux/x64/release -czf "$out/tincan-$version-linux-x64.tar.gz" \
	--transform "s,^bundle,tincan-$version," bundle
for abi in arm64-v8a armeabi-v7a x86_64; do
	cp "build/app/outputs/flutter-apk/app-$abi-release.apk" "$out/tincan-$version-android-$abi.apk"
done
cp build/app/outputs/bundle/release/app-release.aab "$out/tincan-$version-android.aab"
(cd "$out" && sha256sum -- * > SHA256SUMS)

section="## $version — $(date +%Y-%m-%d)"$'\n\n'"$notes"
if [[ -n "$dry" ]]; then
	printf '%s\n\nArtifacts in %s:\n' "$section" "$out"; ls -l "$out"
	exit 0
fi

sed -i "s/^version: .*/version: $version+$build_number/" pubspec.yaml
{
	echo "# Changelog"; echo; echo "$section"; echo
	[[ -f CHANGELOG.md ]] && tail -n +3 CHANGELOG.md
} > CHANGELOG.md.new && mv CHANGELOG.md.new CHANGELOG.md

git add pubspec.yaml CHANGELOG.md
git commit -m "Release $version"
git tag -a "$version" -m "Release $version"
git push origin main "$version"
gh release create "$version" --title "v$version" --notes "$notes" "$out"/*
