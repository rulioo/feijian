#!/usr/bin/env bash
#
# Builds the Android release APK and publishes it to dist/, with the version
# moved forward by one.
#
# The rule (tool/bump_version.sh says it in full, and both release scripts go
# through it): every build is a new version — 1.0.0 publishes 1.0.1 — and the
# versionCode after the `+` moves with it, because Android refuses to install an
# APK whose versionCode is not greater than the one already on the device. The
# number ends up in the file name, which is the only way to tell two builds
# apart once both are sitting in dist/.
#
# `version:` in pubspec.yaml is the single source of truth, and these scripts
# are the only thing that should write to it. The constant the Settings page
# shows is written from it at the same time, so the number a tester reads off
# the screen is the number they were handed.
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
. tool/bump_version.sh

# The version goes into the sources before the build, because that is where the
# build reads it. A failure after that point would otherwise leave the files
# claiming a build that does not exist, so put them back.
trap bump_restore ERR

bump_version pubspec.yaml lib/core/constants.dart

flutter build apk --release

# Past this point the version is real and should stay.
trap - ERR

out="dist/feijian-$BUMP_NEW-release.apk"
apk=build/app/outputs/flutter-apk/app-release.apk
if [ ! -f "$apk" ]; then
  echo "expected $apk after a successful build, and it is not there" >&2
  exit 1
fi

mkdir -p dist
cp "$apk" "$out"
echo "$out  ($(wc -c < "$out") bytes)  [debug-signed]"
