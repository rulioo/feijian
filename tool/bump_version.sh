#!/usr/bin/env bash
#
# Moves the version forward by one build. Sourced by the release scripts, not
# run on its own — they need the old value to put back if the build fails.
#
#   . tool/bump_version.sh
#   trap bump_restore ERR
#   bump_version pubspec.yaml lib/core/constants.dart
#   ...build...
#   trap - ERR
#
# The rule, as asked for: 每次编译生成新的版本，版本号最后一位自动加一 ——
# a build of 1.0.0 publishes 1.0.1. The build number after the `+` also moves,
# for its own reason: Android refuses to install an APK whose versionCode is not
# greater than the one already on the device, so a rebuild that left it alone
# would be rejected at install time and the phone would keep running the old
# code. Every build therefore ends up with a name of its own, which is what
# makes two of them tellable apart in dist/ and in Settings.
#
# `version:` in pubspec.yaml is the single source of truth. The constant the
# Settings page shows is written from it in the same breath, so the number a
# tester reads off the screen is the number they were handed.
#
# Both writes are `sed -i` on the first line that matches, which is why the
# files passed in have to have exactly one such line each: pubspec's `version:`
# at the top level, and the `kAppVersion` constant.
#
set -euo pipefail

# The files bump_version wrote, so bump_restore can put them all back.
BUMP_FILES=()
BUMP_PUBSPEC=
BUMP_OLD=
BUMP_OLD_NAME=
BUMP_NEW=

# Moves the version in $1 (a pubspec) to the next one, and writes the new name
# into the rest, which are Dart files holding `const String kAppVersion`.
bump_version() {
  local pubspec=$1
  shift
  BUMP_FILES=("$pubspec" "$@")
  BUMP_PUBSPEC=$pubspec
  # Cleared first: a bump that goes on to refuse the file it was handed must not
  # leave a later bump_restore putting some *earlier* version back over it.
  BUMP_OLD=
  BUMP_OLD_NAME=
  BUMP_NEW=

  local current
  current=$(sed -n 's/^version: *//p' "$pubspec" | head -n 1)
  if [ -z "$current" ]; then
    echo "no 'version:' line in $pubspec" >&2
    return 1
  fi

  local name=${current%%+*}
  local build=${current#*+}
  # `1.0.0` with no `+N` at all: `${current#*+}` returns the string unchanged.
  if [ "$build" = "$current" ]; then
    build=0
  fi
  case $build in
    '' | *[!0-9]*)
      echo "build number '$build' in '$current' is not a number" >&2
      return 1
      ;;
  esac

  local last=${name##*.}
  case $last in
    '' | *[!0-9]*)
      echo "version name '$name' does not end in a number" >&2
      return 1
      ;;
  esac

  BUMP_OLD=$current
  BUMP_OLD_NAME=$name
  BUMP_NEW="${name%$last}$((last + 1))+$((build + 1))"

  sed -i "s/^version: .*/version: $BUMP_NEW/" "$pubspec"
  local new_name=${BUMP_NEW%%+*}
  local file
  for file in "$@"; do
    sed -i "s/^const String kAppVersion = '.*';/const String kAppVersion = '$new_name';/" "$file"
  done

  echo "version: $BUMP_OLD -> $BUMP_NEW"
}

# Puts every file bump_version touched back the way it was, for the failure path
# of a release script: a build that died must not leave pubspec claiming a
# version that was never published.
#
# Nothing is restored unless the bump got as far as working out the new version
# — a bump that refused the file it was given has not written anything, and
# writing `version: ` over the line it refused to read would be worse than
# leaving it alone.
bump_restore() {
  if [ -z "${BUMP_NEW:-}" ]; then
    return 0
  fi
  local file
  for file in "${BUMP_FILES[@]}"; do
    if [ "$file" = "$BUMP_PUBSPEC" ]; then
      sed -i "s/^version: .*/version: $BUMP_OLD/" "$file"
    else
      sed -i "s/^const String kAppVersion = '.*';/const String kAppVersion = '$BUMP_OLD_NAME';/" "$file"
    fi
  done
  echo "build failed; version reverted to $BUMP_OLD" >&2
}
