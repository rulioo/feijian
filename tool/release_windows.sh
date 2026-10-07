#!/usr/bin/env bash
#
# Builds the Windows release bundle and publishes it to dist/ as a zip, with the
# version moved forward by one — the rule and its reasons are in
# tool/bump_version.sh, which this shares with the Android script.
#
# Each build is its own version, so a zip and an APK built from one working tree
# carry different numbers (1.0.1 and 1.0.2, say). That is deliberate: the two are
# built at different moments from a tree that is not frozen, and a tester who
# reports a problem names one of them. The number each app was built with is the
# one its Settings page shows.
#
# A zip rather than the build folder, because the zip is what gets handed over:
# one file to copy to whichever machine is being tested on. It holds a single
# top-level `feijian/` directory, so unpacking it cannot scatter
# `flutter_windows.dll` and `data/` across whatever folder it lands in.
#
# The build is unsigned, so Windows SmartScreen warns the first time it runs.
# That is expected for a test build and is not the same warning as a broken
# download.
#
# This does not run the tests. Run `flutter test` first, or the artifact is a
# build of code nobody checked.
#
# Usage:  tool/release_windows.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."
. tool/bump_version.sh

trap bump_restore ERR

bump_version pubspec.yaml lib/core/constants.dart

flutter build windows --release

# Past this point the version is real and should stay.
trap - ERR

built=build/windows/x64/runner/Release
if [ ! -f "$built/feijian.exe" ]; then
  echo "expected $built/feijian.exe after a successful build, and it is not there" >&2
  exit 1
fi

out="dist/feijian-$BUMP_NEW-windows-x64.zip"

# Staged rather than zipped in place, so the archive's one top-level directory
# is named after the product instead of after Flutter's build layout (`Release`
# means nothing to whoever unpacks it). Under build/, which is already ignored,
# and as a fixed name, so a script killed mid-run leaves one directory behind
# rather than a new temporary one on every attempt.
stage=build/feijian-stage
rm -rf "$stage"
mkdir -p "$stage"
cp -r "$built" "$stage/feijian"
trap 'rm -rf "$stage"' EXIT

mkdir -p dist
rm -f "$out"
# `python -m zipfile` because this is the one thing in the toolchain the machine
# has no command for: Git Bash ships no `zip`, and GNU tar cannot write one. It
# recurses the directory it is given and keeps the relative path, which is why
# the zip is made from inside the staging directory.
(cd "$stage" && python -m zipfile -c "../../$out" feijian)

echo "$out  ($(wc -c < "$out") bytes)  [unsigned]"
