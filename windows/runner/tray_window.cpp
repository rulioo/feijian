#include "tray_window.h"

#include <shellapi.h>

#include "resource.h"

namespace {

// Identifies this icon to the shell. One icon per process, so any constant
// would do; it is named to make that obvious rather than to be configured.
constexpr UINT kIconId = 1;

// Menu item ids. `TrackPopupMenu` is called with `TPM_RETURNCMD`, so these
// never travel through `WM_COMMAND` and only have to be distinct.
constexpr UINT kMenuOpen = 1;
constexpr UINT kMenuSummary = 2;
constexpr UINT kMenuQuit = 3;
// Device rows get `kMenuPeerBase + index`.
constexpr UINT kMenuPeerBase = 100;

// The tooltip prefix. A proper noun, like the window title in `main.cpp`.
const wchar_t kAppName[] = L"Feijian";

// `NOTIFYICONDATAW` is a large struct and every call here needs most of it
// zeroed; this is the one place that does it.
NOTIFYICONDATAW MakeIconData(HWND owner) {
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = owner;
  data.uID = kIconId;
  return data;
}

}  // namespace

TrayWindow::TrayWindow() {
  // A shell restart destroys every icon registered with the old shell, and this
  // is the only notification of it. Without listening for it, an explorer crash
  // while the window is hidden would leave the user with a running process, no
  // window and no icon -- recoverable only through Task Manager.
  taskbar_created_ = ::RegisterWindowMessageW(L"TaskbarCreated");
}

TrayWindow::~TrayWindow() {
  RemoveIcon();
}

void TrayWindow::SetVisible(bool visible) {
  visible_ = visible;
  if (visible) {
    AddIcon();
  } else {
    RemoveIcon();
  }
}

bool TrayWindow::AddIcon() {
  if (owner_ == nullptr) {
    return false;
  }
  // Any handle held from before belongs to an icon the shell no longer has.
  FreeIconHandle();

  // Asked for at the notification area's own small-icon metric rather than at
  // the 32px `LoadIcon` would choose: `app_icon.ico` carries a hand-drawn 16px
  // frame precisely so the tray does not have to show a halved 32px one, and
  // `LoadImage` is the only call that will pick it. At a scaled DPI the metric
  // moves (24 at 150%), which is why the size is asked for rather than assumed.
  HICON icon = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  if (icon == nullptr) {
    return false;
  }

  NOTIFYICONDATAW data = MakeIconData(owner_);
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  data.uCallbackMessage = kCallbackMessage;
  // The same resource the title bar, the taskbar button and the executable use
  // (`Runner.rc` binds `IDI_APP_ICON` to the app icon). A tray icon that did
  // not match the taskbar icon would read as two different programs.
  data.hIcon = icon;

  std::wstring tooltip = kAppName;
  if (!labels_.summary.empty()) {
    tooltip += L" \x2014 ";  // em dash
    tooltip += labels_.summary;
  }
  ::lstrcpynW(data.szTip, tooltip.c_str(), ARRAYSIZE(data.szTip));

  added_ = ::Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  if (added_) {
    icon_ = icon;
  } else {
    ::DestroyIcon(icon);
  }
  return added_;
}

void TrayWindow::RemoveIcon() {
  if (owner_ != nullptr) {
    // Sent even when `added_` is false: the shell may have the icon while this
    // side believes it does not, and a stray NIM_DELETE for an icon that is not
    // there is harmless. The reverse -- skipping the delete -- leaves a ghost in
    // the notification area until the user hovers over it.
    NOTIFYICONDATAW data = MakeIconData(owner_);
    ::Shell_NotifyIconW(NIM_DELETE, &data);
  }
  added_ = false;
  FreeIconHandle();
}

void TrayWindow::FreeIconHandle() {
  if (icon_ != nullptr) {
    // Only after the shell has been told to let go of it, which every caller
    // does first.
    ::DestroyIcon(icon_);
    icon_ = nullptr;
  }
}

void TrayWindow::UpdateTooltip() {
  if (!added_ || owner_ == nullptr) {
    return;
  }
  NOTIFYICONDATAW data = MakeIconData(owner_);
  data.uFlags = NIF_TIP;

  std::wstring tooltip = kAppName;
  if (!labels_.summary.empty()) {
    tooltip += L" \x2014 ";
    tooltip += labels_.summary;
  }
  ::lstrcpynW(data.szTip, tooltip.c_str(), ARRAYSIZE(data.szTip));
  ::Shell_NotifyIconW(NIM_MODIFY, &data);
}

void TrayWindow::SetLabels(Labels labels) {
  labels_ = std::move(labels);
  UpdateTooltip();
}

void TrayWindow::SetPeers(std::vector<Peer> peers) {
  peers_ = std::move(peers);
}

void TrayWindow::ShowMenu() {
  if (owner_ == nullptr) {
    return;
  }

  HMENU root = ::CreatePopupMenu();
  HMENU status = ::CreatePopupMenu();
  if (root == nullptr || status == nullptr) {
    if (root != nullptr) {
      ::DestroyMenu(root);
    }
    if (status != nullptr) {
      ::DestroyMenu(status);
    }
    return;
  }

  ::AppendMenuW(root, MF_STRING, kMenuOpen, labels_.open.c_str());

  // The summary is not a command, so it is greyed rather than merely ignored:
  // an enabled row that does nothing when clicked reads as a broken menu.
  ::AppendMenuW(status, MF_STRING | MF_GRAYED, kMenuSummary,
                labels_.summary.c_str());
  if (!peers_.empty()) {
    ::AppendMenuW(status, MF_SEPARATOR, 0, nullptr);
  }
  for (size_t i = 0; i < peers_.size(); ++i) {
    ::AppendMenuW(status, MF_STRING, kMenuPeerBase + static_cast<UINT>(i),
                  peers_[i].label.c_str());
  }
  ::AppendMenuW(root, MF_POPUP, reinterpret_cast<UINT_PTR>(status),
                labels_.status.c_str());

  ::AppendMenuW(root, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(root, MF_STRING, kMenuQuit, labels_.quit.c_str());

  POINT cursor;
  if (!::GetCursorPos(&cursor)) {
    ::DestroyMenu(root);  // destroys the submenu with it
    return;
  }

  // The owner has to be foreground before the menu opens. Without this the menu
  // still appears, but clicking anywhere outside it does not close it -- the
  // user has to pick something. The WM_NULL afterwards is the documented
  // counterpart to the SetForegroundWindow, and clears a stuck menu state.
  //
  // The owner is usually *hidden* at this moment, because reaching a hidden
  // window is what the menu is for, and `SetForegroundWindow` on a hidden window
  // is not guaranteed to take. In practice the click on the tray icon has just
  // given this process the foreground right, which is the condition the call
  // actually needs, so this should hold -- but it is the least certain thing in
  // this file and it is worth watching for on a real desktop (a menu that needs
  // two clicks or will not dismiss). The remedy, if it is ever needed, is a
  // second never-shown window for the icon and menu to live on rather than the
  // Flutter one: not worth paying for on a guess.
  ::SetForegroundWindow(owner_);
  const UINT chosen = ::TrackPopupMenu(
      root, TPM_RETURNCMD | TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, owner_,
      nullptr);
  ::PostMessageW(owner_, WM_NULL, 0, 0);

  ::DestroyMenu(root);

  if (chosen == 0 || !on_command_) {
    return;  // dismissed, or a click that landed on nothing
  }
  switch (chosen) {
    case kMenuOpen:
      on_command_(Command::kOpen, std::wstring());
      return;
    case kMenuQuit:
      on_command_(Command::kQuit, std::wstring());
      return;
    default:
      break;
  }
  // `chosen` is an unsigned id, so anything below the device base wraps to an
  // enormous index and fails the bounds check rather than reading out of the
  // array. Kept as the check it reads as; the wrap is the reason it is safe with
  // no separate `chosen >= kMenuPeerBase` test in front of it.
  const size_t index = chosen - kMenuPeerBase;
  if (index < peers_.size()) {
    on_command_(Command::kPeer, peers_[index].id);
  }
}

void TrayWindow::ShowBalloon(const std::wstring& title,
                             const std::wstring& body) {
  if (!added_ || owner_ == nullptr) {
    return;
  }
  NOTIFYICONDATAW data = MakeIconData(owner_);
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO;
  ::lstrcpynW(data.szInfoTitle, title.c_str(), ARRAYSIZE(data.szInfoTitle));
  ::lstrcpynW(data.szInfo, body.c_str(), ARRAYSIZE(data.szInfo));
  ::Shell_NotifyIconW(NIM_MODIFY, &data);
}

void TrayWindow::OnTaskbarCreated() {
  // Whatever this side believed, the shell that was showing the icon is gone,
  // along with the icon itself -- so no NIM_DELETE, just give up the handle.
  // `AddIcon` frees it too; this keeps the two paths from disagreeing about
  // who owns it.
  added_ = false;
  if (visible_) {
    AddIcon();
  } else {
    FreeIconHandle();
  }
}

void TrayWindow::OnCallbackMessage(WPARAM wparam, LPARAM lparam) {
  switch (LOWORD(lparam)) {
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      // A single left click is "show me the window", which is what every tray
      // application does and therefore what nobody has to be taught.
      if (on_command_) {
        on_command_(Command::kOpen, std::wstring());
      }
      break;
    case WM_RBUTTONUP:
    case WM_CONTEXTMENU:
      ShowMenu();
      break;
    default:
      break;
  }
  (void)wparam;  // the icon id, which is a constant here
}
