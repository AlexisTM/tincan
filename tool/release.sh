#!/usr/bin/env bash
# Usage: tool/release.sh <version>             e.g. tool/release.sh 1.0.0
#        DRY_RUN=1 tool/release.sh <version>   builds and prints notes, no commit/tag/push
#        PLAY_KEY=<key.json>  takes the version code after Play's highest
#        BUILD_NUMBER=<n>     forces the version code
#
# Builds the Tincan Play bundle, then bumps pubspec, prepends CHANGELOG.md,
# tags v<version>, pushes and publishes a GitHub release with the bundle.
# Builds run first so a broken build never leaves a pushed tag.
set -euo pipefail
cd "$(dirname "$0")/.."

app=tincan
version="${1:?usage: tool/release.sh <version>}"
dry="${DRY_RUN:-}"
die() { echo "release: $*" >&2; exit 1; }

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z"
tag="v$version"

[[ "$(git branch --show-current)" == main ]] || die "not on main"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "working tree has uncommitted changes"
if [[ -z "$dry" ]]; then
	git fetch -q --tags origin main
	[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main is not in sync with origin/main"
	[[ -z "$(git ls-remote --tags origin "refs/tags/$tag")" ]] || die "tag $tag already exists on origin"
	command -v gh >/dev/null || die "gh not installed"
fi
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag $tag already exists"
[[ -f android/key.properties ]] || die "android/key.properties missing (make keystore); Play rejects the debug key"

# Play keeps every version code ever uploaded, including ones pubspec never saw.
build_number=$(( $(sed -n 's/^version: .*+\([0-9]*\)$/\1/p' pubspec.yaml) + 1 ))
if [[ -n "${PLAY_KEY:-}" ]]; then
	played=$(tool/play_version_code.sh "$PLAY_KEY") || die "could not read version codes from Play"
	(( played < build_number )) || build_number=$(( played + 1 ))
fi
build_number="${BUILD_NUMBER:-$build_number}"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || die "BUILD_NUMBER must be a positive integer"

# Only v-tags count; the bare 0.0.x tags predate this script.
prev=$(git describe --tags --abbrev=0 --match "v[0-9]*.[0-9]*.[0-9]*" 2>/dev/null || true)
if [[ -n "$prev" ]]; then
	notes=$(git log --no-merges --pretty='- %s (%h)' "$prev"..HEAD | grep -v '^- Release ' || true)
	[[ -n "$notes" ]] || notes="- No changes since $prev"
else
	notes="- First release"
fi

# This machine exports a deprecated ANDROID_SDK_HOME that AGP rejects.
unset ANDROID_SDK_HOME
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$HOME/.android-user}"

flags=(--release --build-name="$version" --build-number="$build_number")
flutter analyze
flutter test
gobridge/build-android.sh
flutter build appbundle "${flags[@]}"

out="build/release/$tag"
rm -rf "$out" && mkdir -p "$out"
cp build/app/outputs/bundle/release/app-release.aab "$out/$app-$version-android.aab"
(cd "$out" && sha256sum -- * > SHA256SUMS)

section="## $version ($(date +%Y-%m-%d))"$'\n\n'"$notes"
if [[ -n "$dry" ]]; then
	printf '%s\n\nVersion code %s. Artifacts in %s:\n' "$section" "$build_number" "$out"; ls -l "$out"
	exit 0
fi

changelog=CHANGELOG.md
{
	echo "# Changelog"; echo; echo "$section"; echo
	if [[ -f "$changelog" ]]; then tail -n +3 "$changelog"; fi
} > "$changelog.new"
mv "$changelog.new" "$changelog"
sed -i "s/^version: .*/version: $version+$build_number/" pubspec.yaml

name="${app^}"
git add pubspec.yaml "$changelog"
git commit -m "Release $name $version"
git tag -a "$tag" -m "$name $version"
if ! git push --atomic origin main "$tag"; then
	git tag -d "$tag"
	git reset -q --keep HEAD~1
	die "push failed; release commit and tag rolled back"
fi
notes_file="build/release/$tag-notes.md"
printf '%s\n' "$notes" > "$notes_file"
gh release create "$tag" --title "$name $version" --notes-file "$notes_file" "$out"/* ||
	die "tag $tag is pushed but the GitHub release failed; retry with:
  gh release create $tag --title '$name $version' --notes-file $notes_file $out/*"
echo "Upload $out/$app-$version-android.aab to Play Console (version code $build_number), or: make publish"
