#ifndef RUNNER_TRAY_WINDOW_H_
#define RUNNER_TRAY_WINDOW_H_

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

// The notification-area icon, its context menu and its balloon -- design.md
// §7.2.
//
// Not a window despite the name: it owns no HWND of its own and no message
// loop. It borrows the Flutter window as the shell's callback target and is
// driven by `FlutterWindow::MessageHandler`, which forwards the two messages
// that belong to it. Keeping it separate is what lets the message plumbing stay
// in the one file that already has to think about message ordering.
//
// It holds no policy. Whether a click on the window's X should hide or quit is
// decided in Dart (see `lib/platform/tray_controller.dart`) and arrives here as
// an instruction; this class only knows how to carry instructions out.
class TrayWindow {
 public:
  // One device row in the Status submenu.
  struct Peer {
    std::wstring id;
    std::wstring label;
  };

  // The menu's captions. Supplied by Dart rather than written here, so that
  // adding a language is a translation file and not a rebuild of this file.
  struct Labels {
    std::wstring open;
    std::wstring status;
    std::wstring quit;
    // The disabled first line of the Status submenu: "2 devices online".
    std::wstring summary;
  };

  // What the user asked for by clicking the menu.
  enum class Command { kOpen, kQuit, kPeer };

  using CommandCallback =
      std::function<void(Command command, const std::wstring& peer_id)>;

  TrayWindow();
  ~TrayWindow();

  TrayWindow(const TrayWindow&) = delete;
  TrayWindow& operator=(const TrayWindow&) = delete;

  // The window that receives the shell's callback message. Must be set before
  // the icon is added.
  void SetOwner(HWND owner) { owner_ = owner; }
  HWND owner() const { return owner_; }

  void SetCommandCallback(CommandCallback callback) {
    on_command_ = std::move(callback);
  }

  // Shows or removes the icon. Tracked separately from whether the shell
  // actually has it, because the shell can forget it -- see
  // `OnTaskbarCreated`.
  void SetVisible(bool visible);
  bool visible() const { return visible_; }

  // Whether the shell is believed to be showing the icon right now.
  //
  // This is the guard that keeps close-to-tray from becoming a lockout: if it
  // is false when a close arrives, hiding would leave a running process with
  // nothing to click, and the caller closes the window instead.
  bool has_icon() const { return added_; }

  // Replaces the snapshot the menu is built from. The menu itself is created at
  // pop-up time from this, which is what keeps it current without a timer.
  void SetLabels(Labels labels);
  void SetPeers(std::vector<Peer> peers);

  // Pops up the menu at the cursor. Calls the command callback if an item is
  // chosen, and does nothing if the menu is dismissed.
  void ShowMenu();

  // A balloon. Best effort: Windows 10 and 11 may route it through Focus Assist
  // and drop it, and the shell is free to ignore it. Never the only way to
  // reach the app.
  void ShowBalloon(const std::wstring& title, const std::wstring& body);

  // The shell restarted and every icon it was showing is gone. Re-adds this one
  // if it is supposed to be visible.
  void OnTaskbarCreated();

  // The message the shell sends to this icon. `FlutterWindow` routes it here.
  static constexpr UINT kCallbackMessage = WM_APP + 1;

  // True when `message` is the shell's "your icon is gone" broadcast, which is
  // how a tray application learns that its icon was lost. The id is registered
  // once, in the constructor, and must not collide with `kCallbackMessage`.
  //
  // A predicate rather than exposing the id, because comparing against a raw
  // `RegisterWindowMessage` result is wrong when registration fails and returns
  // zero: every top-level window gets `WM_NULL` (also zero), including the one
  // `ShowMenu` posts to dismiss an open menu. Callers cannot get that wrong here.
  bool IsTaskbarCreated(UINT message) const {
    return taskbar_created_ != 0 && message == taskbar_created_;
  }

  // Handles `kCallbackMessage`. `lparam` carries the mouse message, which is
  // the layout for `NOTIFYICON_VERSION` 0 -- the default, and the one this code
  // relies on by never calling `NIM_SETVERSION`.
  void OnCallbackMessage(WPARAM wparam, LPARAM lparam);

 private:
  bool AddIcon();
  void RemoveIcon();
  void UpdateTooltip();

  // Releases the icon handle, if one is held. Separate from `RemoveIcon`
  // because the two are not always wanted together: a shell restart takes the
  // icon away without going through `NIM_DELETE`, but the handle is still ours
  // to free.
  void FreeIconHandle();

  HWND owner_ = nullptr;
  bool visible_ = false;
  bool added_ = false;
  UINT taskbar_created_ = 0;

  // The icon currently registered with the shell, held so it can be destroyed.
  // `LoadImage` hands back a fresh icon each call, unlike `LoadIcon`, which
  // shares one it owns -- the price of being able to ask for a specific size.
  HICON icon_ = nullptr;

  Labels labels_;
  std::vector<Peer> peers_;
  CommandCallback on_command_;
};

#endif  // RUNNER_TRAY_WINDOW_H_
