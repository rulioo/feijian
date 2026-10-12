#include "single_instance.h"

#include "win32_window.h"

namespace {

// The running instance creates its window only after the Flutter engine has
// started, so a launch that arrives a moment early finds the mutex held and no
// window to talk to. Waiting is the difference between "launching twice always
// brings the window up" and "it works unless you were quick".
constexpr int kFindWindowAttempts = 40;
constexpr DWORD kFindWindowGapMs = 50;

}  // namespace

namespace single_instance {

ClaimResult Claim(HANDLE* handle) {
  *handle = nullptr;

  // `bInitialOwner` is false on purpose: nothing here needs to *own* the
  // mutex, only to keep it in existence. Owning it would additionally mean
  // handling the abandoned state if the owning thread ever exited first, which
  // is bookkeeping with nothing to buy.
  HANDLE created = ::CreateMutexW(nullptr, FALSE, kMutexName);
  if (created == nullptr) {
    // Not the same thing as another instance running, and must not be treated
    // as it -- see the header.
    return ClaimResult::kUnavailable;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(created);
    return ClaimResult::kAlreadyRunning;
  }

  *handle = created;
  return ClaimResult::kFirstInstance;
}

UINT ActivateMessage() {
  // Registered once, on first use. Both processes need the same value, and
  // `RegisterWindowMessage` is what gives them that without an agreed-upon
  // number to keep in sync.
  static const UINT message =
      ::RegisterWindowMessageW(L"Feijian.ActivateWindow");
  return message;
}

bool IsActivateMessage(UINT message) {
  const UINT activate = ActivateMessage();
  return activate != 0 && message == activate;
}

bool ActivateRunningInstance() {
  HWND window = nullptr;
  for (int attempt = 0; attempt < kFindWindowAttempts; ++attempt) {
    window = ::FindWindowW(kWindowClassName, nullptr);
    if (window != nullptr) {
      break;
    }
    ::Sleep(kFindWindowGapMs);
  }
  if (window == nullptr) {
    return false;
  }

  // The running instance has to be allowed to raise itself, and it is not the
  // process the user just clicked on -- this one is. Handing over the right is
  // what makes its `SetForegroundWindow` actually take effect instead of just
  // flashing the taskbar button. It is a permission, not a command: if it is
  // refused the window still comes up, possibly behind whatever was in front.
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id != 0) {
    ::AllowSetForegroundWindow(process_id);
  }

  // Posted rather than sent: `SendMessage` would block this process until the
  // other one finished handling it, and there is nothing here worth waiting
  // for. The window may also be busy starting up, which posting tolerates.
  return ::PostMessageW(window, ActivateMessage(), 0, 0) != FALSE;
}

}  // namespace single_instance
