#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

// One Feijian per logon session -- design.md §7.2.
//
// Without this, launching the program twice gives two tray icons, two windows
// that are indistinguishable at a glance, and two processes fighting over the
// same discovery port. What the user meant by clicking the icon again is "show
// me the program", so that is what a second launch does: it wakes the window
// that is already up and gets out of the way.
namespace single_instance {

// Named in one place because two files depend on the spelling: this one creates
// the mutex, and `installer/feijian.iss` names it as `AppMutex` so that an
// installation refuses to run over a Feijian that is still open. Change it here
// and the installer stops noticing a running program.
//
// No `Local\` prefix, and the absence is deliberate. An unprefixed named object
// created by an interactive process already lives in that session's namespace,
// which is the scope wanted here: two people logged into the same machine are
// two users, each with their own Feijian, and one of them should not be able to
// block the other. `Global\` would be actively wrong -- creating an object
// there needs a privilege a standard user does not have. Spelling the prefix
// out would change nothing at runtime, but it would put a second, differently
// written form of the name in the installer, and a mismatch between the two is
// a silent failure.
inline constexpr const wchar_t kMutexName[] = L"Feijian.SingleInstance";

enum class ClaimResult {
  // This is the only instance. `*handle` is open and must stay open.
  kFirstInstance,
  // Another instance is up and owns the window the user wants to see.
  kAlreadyRunning,
  // The lock could not be created at all, so whether another instance exists is
  // unknown.
  kUnavailable,
};

// Takes the per-session mutex that says "Feijian is running".
//
// On `kFirstInstance`, `*handle` is left open and the caller must keep it until
// the process ends: the mutex lives exactly as long as some handle to it is
// open, so closing it early would let the next launch start a second instance.
// On the other two results `*handle` is set to `nullptr`.
//
// `kUnavailable` is separated from `kAlreadyRunning` because the two call for
// opposite answers, and collapsing them into one "no handle" result -- which is
// what this originally did -- makes the wrong one unavoidable. A failed lock is
// not evidence of another instance; treating it as one means the program
// refuses to start at all, and a program that will not start is a far worse
// outcome than the duplicate instance this exists to prevent. The caller is
// expected to start normally in that case.
ClaimResult Claim(HANDLE* handle);

// The message a second launch posts to the running instance.
//
// Registered rather than picked from the `WM_APP` range, so it cannot land on
// some other component's message. Compare with `IsActivateMessage`, never
// directly -- see there.
UINT ActivateMessage();

// True when `message` is the activation request.
//
// `RegisterWindowMessageW` returns zero if it fails, and `WM_NULL` is *also*
// zero, so a bare `message == ActivateMessage()` would treat every null message
// as an activation. This is the only correct way to test it.
bool IsActivateMessage(UINT message);

// Asks the instance that is already running to show itself. Best effort.
//
// Returns false if no window turned up in time or the request could not be
// posted. Neither is worth reporting to the user: they asked to open a program
// that is already open, and the only visible outcome of a failure is that
// nothing moves. Two ways it can fail, both noted because they look identical
// from the outside:
//
//   * The running instance is still starting up and has no window yet -- which
//     is why this waits for one rather than looking once.
//   * The running instance is elevated and this one is not. Windows' UIPI
//     silently drops messages sent to a process of higher integrity, so the
//     activation never arrives. Across equal privilege levels this cannot
//     happen.
bool ActivateRunningInstance();

}  // namespace single_instance

#endif  // RUNNER_SINGLE_INSTANCE_H_
