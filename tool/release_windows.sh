#!/usr/bin/env bash
#
# Builds the Windows release and publishes it to dist/ twice over: a portable
# zip and an Inno Setup installer, from one staging directory and one version
# bump — the rule and its reasons are in tool/bump_version.sh, which this shares
# with the Android script.
#
# The two artifacts are not redundant, and neither is a fallback for the other.
# The zip is what gets handed to a machine that will not keep the program, or
# where installing is not permitted; it also has the property of showing its
# whole shape, which is how the thing in it that people get wrong gets noticed.
# The installer is for a machine that will keep it: Program Files, a Start menu
# entry, an uninstaller, and the firewall rules from design.md §7.2 — that last
# one needs an elevated step a zip can never have.
#
# Each build is its own version, so a zip and an APK built from one working tree
# carry different numbers (1.0.1 and 1.0.2, say). That is deliberate: the two are
# built at different moments from a tree that is not frozen, and a tester who
# reports a problem names one of them. The number each app was built with is the
# one its Settings page shows. The zip and the installer from one run of this
# script are the exception: same version, same bytes, by construction.
#
# The build is unsigned, so Windows SmartScreen warns the first time either one
# runs. That is expected for a test build and is not the same warning as a broken
# download. It matters more for the installer, which also asks for elevation —
# an unsigned installer asking to be an administrator is exactly the shape of
# thing SmartScreen is warning about.
#
# A zip rather than the build folder, because the zip is what gets handed over:
# one file to copy to whichever machine is being tested on. It holds a single
# top-level `feijian/` directory, so unpacking it cannot scatter
# `flutter_windows.dll` and `data/` across whatever folder it lands in.
#
# The MSVC runtime goes in beside the exe, so the bundle runs on a machine that
# has never had Visual Studio or the VC++ redistributable on it. Without this the
# zip only works on a machine that already has the redistributable installed,
# which is most developer machines and few others — and the failure is a
# "VCRUNTIME140.dll was not found" dialog on a computer the tester borrowed,
# where nothing about it suggests the product is at fault.
#
# App-local deployment (the DLLs next to the exe) rather than a redistributable
# installer, because the point of the zip is that it is one file to copy and
# nothing to install. Windows searches the application directory before the
# system one for these, so a local copy also wins over an older system-wide one.
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

# The Dart pipeline is thrown away before every release build, and that is not
# belt-and-braces. `flutter build windows` was observed shipping a stale AOT
# snapshot: on 2026-10-08 the kernel and AOT targets were both judged up to date
# while the asset target re-ran in the same build, so `data/app.so` still carried
# the bytes from a build twelve hours and two version bumps earlier. The code in
# it happened to be current, so nothing was broken that time; the version
# constant in it was not, and nothing would have said so.
#
# `flutter_build` is pure derived state for the Dart half of the build, and
# deleting it does not touch the CMake cache or the unpacked engine, so the
# rebuild costs about half a minute rather than a full clean. The alternative is
# trusting an incremental build that has already been caught being wrong once,
# on the one artifact that leaves this machine.
rm -rf .dart_tool/flutter_build

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

# The app writes its log into the directory the exe sits in, so every run of the
# previous build leaves a `log/` inside the build output, and `cp -r` copies it
# into the zip. Runtime state is not part of a distribution: a folder that
# arrives pre-made in someone else's download is at best confusing. This shipped
# once before it was noticed.
rm -rf "$stage/feijian/log"

# The Microsoft C++ runtime, app-local. Audit of every binary in the Release
# folder with `dumpbin -dependents`, 2026-10-10:
#
#   feijian.exe                      MSVCP140, VCRUNTIME140, VCRUNTIME140_1
#   desktop_drop_plugin.dll          MSVCP140, VCRUNTIME140, VCRUNTIME140_1
#   sqlite3.dll                      VCRUNTIME140
#   sqlite3_flutter_libs_plugin.dll  VCRUNTIME140
#
# Four binaries name them, and their union is exactly the three copied below.
# (An earlier version of this comment listed three binaries and left
# sqlite3_flutter_libs_plugin.dll out — it imports VCRUNTIME140 like sqlite3.dll
# does, and was only ever correct by accident, being on the list already.)
# flutter_windows.dll imports none of them: the engine links its CRT statically.
# Re-run that audit whenever a plugin is added or removed. It is the only thing
# that says whether this list is still the right one, and nothing else in the
# build fails when it stops being.
#
# Nothing else in Microsoft.VC143.CRT is reached, not even transitively —
# checked by dumping the three below as well: they import each other, KERNEL32,
# and the api-ms-win-crt-* set, and nothing more. So msvcp140_1, msvcp140_2,
# msvcp140_atomic_wait, msvcp140_codecvt_ids and vcruntime140_threads are absent,
# and vccorlib140 is C++/CX. Their total is 4 KB of value and 1.2 MB of download.
#
# The api-ms-win-crt-* entries in every import table above are the Universal CRT.
# Deliberately not copied: it is a Windows 10+ operating system component, so a
# bundle carrying its own copy would be shipping a second one — and would break
# on the servicing updates that keep the system copy patched.
#
# From the redists the Windows build already needed, so this adds no new
# prerequisite. `set -e` on purpose: a bundle that silently loses these is the
# exact defect this block exists to prevent.
vcrt=""
for d in "C:/BuildTools/VC/Redist/MSVC/"*/x64/Microsoft.VC143.CRT; do
  [ -d "$d" ] && vcrt="$d"
done
if [ -z "$vcrt" ]; then
  echo "no x64 Microsoft.VC143.CRT redist found under C:/BuildTools/VC/Redist/MSVC" >&2
  exit 1
fi
for dll in msvcp140.dll vcruntime140.dll vcruntime140_1.dll; do
  cp "$vcrt/$dll" "$stage/feijian/$dll"
done

mkdir -p dist
rm -f "$out"
# `python -m zipfile` because this is the one thing in the toolchain the machine
# has no command for: Git Bash ships no `zip`, and GNU tar cannot write one. It
# recurses the directory it is given and keeps the relative path, which is why
# the zip is made from inside the staging directory.
(cd "$stage" && python -m zipfile -c "../../$out" feijian)

echo "$out  ($(wc -c < "$out") bytes)  [unsigned]"

# --------------------------------------------------------------- installer
#
# The same staging directory, the same version bump, the same run as the zip
# above -- and the same files, byte for byte. One script rather than two because
# a folder someone tested and an installer someone installed that carry
# different version numbers are a bug report nobody can act on.
#
# It has to be compiled here rather than left to a second command, because the
# `trap` above deletes the staging directory on the way out.

# Installed per user by default, so not in either Program Files. Looked up
# rather than required on PATH, since the installer puts nothing there.
find_iscc() {
  local candidates=()
  if [ -n "${LOCALAPPDATA:-}" ]; then
    candidates+=("$(cygpath -u "$LOCALAPPDATA")/Programs/Inno Setup 6/ISCC.exe")
  fi
  candidates+=(
    "/c/Program Files (x86)/Inno Setup 6/ISCC.exe"
    "/c/Program Files/Inno Setup 6/ISCC.exe"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

iscc=$(find_iscc) || {
  echo "no Inno Setup 6 compiler found. Looked in \${LOCALAPPDATA}/Programs/Inno Setup 6 and both Program Files directories. The zip above is complete and usable; the installer is missing." >&2
  exit 1
}

setup="dist/feijian-$BUMP_NEW-windows-x64-setup.exe"
rm -f "$setup"

# Two defines, both from the one version this run settled on: the name part
# (`1.0.12`) for what Setup calls its version and shows in Apps & features, and
# the whole thing (`1.0.12+18`) for the output filename, so it sorts and reads
# like the zip beside it.
#
# `MSYS_NO_PATHCONV=1` in front of the compiler is required, and is the one
# thing here that fails silently if it is dropped. Git Bash rewrites any
# argument that looks like a path, and `/DAppVersion=1.0.12` looks like one:
# without the prefix the compiler is handed `C:/Program Files/Git/DAppVersion=
# 1.0.12` instead, does not recognise it as a define, and falls back to the
# defaults in the .iss file. The result is an installer named 0.0.0 that
# compiles without complaint.
(
  cd installer &&
    MSYS_NO_PATHCONV=1 "$iscc" \
      "/DAppVersion=${BUMP_NEW%%+*}" \
      "/DAppFullVersion=$BUMP_NEW" \
      feijian.iss
)

if [ ! -f "$setup" ]; then
  echo "the compiler reported success and $setup is not there" >&2
  exit 1
fi

echo "$setup  ($(wc -c < "$setup") bytes)  [unsigned, installs elevated]"
