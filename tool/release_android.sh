#!/usr/bin/env bash
#
# Builds the Android release APK and publishes it to dist/, with the build
# number bumped.
#
# Why the number moves on every run: Android refuses to install an APK whose
# versionCode is not greater than the one already on the device. `flutter build
# apk --release` takes versionCode from the build number after the `+` in
# pubspec's `version:`, so a rebuild without a bump is rejected at install time —
# the phone keeps running the old build, and whatever is tested next is code
# that is not there. The number also ends up in the file name, which is the only
# way to tell two builds apart once both are sitting in dist/.
#
# `version:` in pubspec.yaml is the single source of truth, and this script is
# the only thing that should write to it. Only the build number moves; the
# version name (1.0.0) is left alone, so a change to it stays a deliberate edit
# rather than a side effect of publishing.
#
# The APK is signed with the debug key (android/app/build.gradle.kts still has
# the `flutter create` TODO), so it installs and runs but must not be handed to
# anyone as a release.
#
# This does not run the tests. Run `flutter test` first, or the artifact is a
# build of code nobody checked.
#
# Usage:  tool/release_android.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

pubspec=pubspec.yaml
current=$(sed -n 's/^version: *//p' "$pubspec" | head -n 1)

if [ -z "$current" ]; then
  echo "no 'version:' line in $pubspec" >&2
  exit 1
fi

name=${current%%+*}
build=${current#*+}
# `1.0.0` with no `+N` at all: `${current#*+}` returns the string unchanged.
if [ "$build" = "$current" ]; then
  build=0
fi
case $build in
  '' | *[!0-9]*)
    echo "build number '$build' in '$current' is not a number" >&2
    exit 1
    ;;
esac

build=$((build + 1))
next="$name+$build"
out="dist/feijian-$next-release.apk"

# The version goes into pubspec before the build, because that is where the
# build reads it. A failure after that point would otherwise leave the file
# claiming a build that does not exist, so put it back.
revert() {
  sed -i "s/^version: .*/version: $current/" "$pubspec"
  echo "build failed; version reverted to $current" >&2
}
trap revert ERR

sed -i "s/^version: .*/version: $next/" "$pubspec"
echo "version: $current -> $next"

flutter build apk --release

# Past this point the version is real and should stay.
trap - ERR

apk=build/app/outputs/flutter-apk/app-release.apk
if [ ! -f "$apk" ]; then
  echo "expected $apk after a successful build, and it is not there" >&2
  exit 1
fi

mkdir -p dist
cp "$apk" "$out"
echo "$out  ($(wc -c < "$out") bytes)  [debug-signed]"
