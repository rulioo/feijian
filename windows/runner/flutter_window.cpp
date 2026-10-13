#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "single_instance.h"
#include "utils.h"

namespace {

// The failsafe that keeps a close from becoming unclosable. Dart normally
// answers in well under a millisecond; this only fires if it cannot answer at
// all -- a hung engine, a debugger stopped on the platform thread, a Dart
// isolate that threw during startup. Generous, because it is a backstop and not
// a deadline: the cost of it firing early is a quit the user did not ask for.
//
// It must stay longer than `kShutdownGracePeriod` in `lib/core/constants.dart`
// (500ms), because a close with close-to-tray off runs the goodbye to the peers
// inside that budget before it calls `quit`. Shorten this below that and the
// failsafe fires mid-goodbye: the process dies, the `bye` never leaves the
// machine, and every peer keeps showing this device as online for a full
// minute. The two are far apart in the tree, so the pairing is written here.
constexpr UINT_PTR kCloseFailsafeTimer = 1;
constexpr UINT kCloseFailsafeMs = 1000;

// The channel name, matching `WindowsTrayHost._channel` in Dart.
constexpr char kTrayChannel[] = "com.feijian.lan/tray";

// Posted to this window to end the program. Never sent from outside: a tray
// method call that ends the program posts this instead of destroying the window
// on the spot. See the `quit` branch of `HandleTrayMethodCall` for why.
constexpr UINT kQuitMessage = WM_APP + 2;

// Reads a string out of a decoded map, or returns an empty string.
std::string StringFromMap(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return std::string();
  }
  const std::string* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string() : *value;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  tray_ = std::make_unique<TrayWindow>();
  tray_->SetOwner(GetHandle());
  tray_->SetCommandCallback([this](TrayWindow::Command command,
                                   const std::wstring& peer_id) {
    SendTrayCommand(command, peer_id);
  });

  tray_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), kTrayChannel,
      &flutter::StandardMethodCodec::GetInstance());
  tray_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleTrayMethodCall(call, std::move(result)); });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // The icon was already taken down in the `WM_DESTROY` branch, while the
  // window handle it was registered against was still valid.
  tray_.reset();
  tray_channel_.reset();

  if (flutter_controller_) {
    // Cleared before the engine is released, not in the same step as releasing
    // it. Assigning `nullptr` in one step leaves `flutter_controller_` set for
    // the whole of the teardown, and the teardown destroys the view window --
    // which sends messages to this window, into `MessageHandler`, which finds
    // the pointer set and calls into a controller that is halfway through being
    // destroyed. Moving it out first means every message delivered during the
    // teardown sees null and takes the branch that does nothing.
    std::unique_ptr<flutter::FlutterViewController> controller =
        std::move(flutter_controller_);
    controller.reset();
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kQuitMessage) {
    // The end of the program, run from the message loop rather than from
    // inside a platform-channel call. It has to be here and not there:
    // destroying the window destroys the engine, and the engine is what is
    // dispatching the call that asked for this -- unwinding through a
    // half-destroyed engine jumps through a freed vtable. See the `quit`
    // branch of `HandleTrayMethodCall`.
    ::DestroyWindow(hwnd);
    return 0;
  }

  if (std::optional<LRESULT> tray_result =
          HandleTrayMessage(hwnd, message, wparam, lparam)) {
    return *tray_result;
  }

  if (single_instance::IsActivateMessage(message)) {
    // A second launch of the program, asking this window to come forward.
    //
    // Shown here rather than left to Dart alone, because this message can
    // arrive while the engine is still starting: the window exists well before
    // the Dart side has registered its handler for the channel, and an event
    // sent to a handler that is not listening yet is dropped without a trace.
    // That would be the same "clicked the icon and nothing happened" this
    // feature exists to remove, just harder to reproduce. Showing here is safe
    // in every case, because it is exactly what Dart's own reveal does.
    ShowAndFocus();
    // And told to Dart as well, because `TrayController` keeps its own idea of
    // whether the window is hidden (`_hidden`) and would otherwise go on
    // believing that a window which is now on screen is still in the tray.
    SendTrayEvent("open");
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

std::optional<LRESULT> FlutterWindow::HandleTrayMessage(
    HWND hwnd, UINT const message, WPARAM const wparam,
    LPARAM const lparam) noexcept {
  if (tray_) {
    if (message == TrayWindow::kCallbackMessage) {
      tray_->OnCallbackMessage(wparam, lparam);
      return 0;
    }
    if (tray_->IsTaskbarCreated(message)) {
      tray_->OnTaskbarCreated();
      return 0;
    }
  }

  switch (message) {
    case WM_CLOSE:
      if (session_ending_) {
        // Windows is going down. Fall through to the default handling, which
        // destroys the window and ends the process.
        return std::nullopt;
      }
      // The user clicked X. Whether that means "hide" or "quit" is Dart's
      // call -- see `lib/platform/tray_controller.dart` -- so the window is
      // left alone until the answer arrives.
      BeginClose();
      return 0;

    case WM_TIMER:
      if (wparam == kCloseFailsafeTimer) {
        ::KillTimer(hwnd, kCloseFailsafeTimer);
        close_pending_ = false;
        ::DestroyWindow(hwnd);
        return 0;
      }
      return std::nullopt;

    case WM_DESTROY:
      // Removed here rather than in `OnDestroy`, where the window handle has
      // already been cleared -- the shell matches an icon by its owner window,
      // so deleting it needs the handle to still be the one that registered it.
      if (tray_) {
        tray_->SetVisible(false);
      }
      return std::nullopt;  // the base class still has to destroy the window

    case WM_QUERYENDSESSION:
      // Answering TRUE, and answering it immediately, is the whole of the
      // shutdown handling. Returning FALSE would have Windows cancel the
      // shutdown and tell the user that Feijian is preventing it -- for a
      // process whose only real work is holding a socket open.
      //
      // The flag is what makes the `WM_CLOSE` that follows mean "close". Set
      // here rather than in `WM_ENDSESSION` because the close can arrive first.
      session_ending_ = true;
      return TRUE;

    case WM_ENDSESSION:
      if (wparam == FALSE) {
        // Windows changed its mind and the shutdown was cancelled.
        session_ending_ = false;
        return 0;
      }
      // Ending the session for real -- and the window goes with it.
      //
      // Destroying the window rather than posting the quit message directly,
      // which is what this did and what killed the process on every logoff and
      // every restart. A bare quit ends the message loop with the window still
      // standing, so the engine is torn down later and by the wrong owner:
      // `wWinMain` returns, `~FlutterWindow` destroys the controller, and the
      // controller's teardown destroys its own view window -- which sends
      // messages to a parent window that is alive, whose handler calls into the
      // controller being destroyed. That is an access violation inside
      // `flutter_windows.dll`, measured at `flutter_windows.dll+0x1d9b0`.
      // Destroying the window takes the ordinary `WM_DESTROY` path instead,
      // where the handle is cleared first and the engine is released in order.
      //
      // `DestroyWindow` sends `WM_DESTROY` and never `WM_CLOSE`, so this keeps
      // what the direct quit was chosen for: no round trip to Dart during a
      // shutdown. No `bye` is sent either -- on a shutdown there is usually no
      // network left to send it on, which is why peers already treat a silent
      // departure as normal (see `kPeerRemoveAfter`).
      ::DestroyWindow(hwnd);
      return 0;

    default:
      return std::nullopt;
  }
}

void FlutterWindow::BeginClose() {
  if (close_pending_) {
    return;
  }
  close_pending_ = true;
  if (HWND hwnd = GetHandle()) {
    ::SetTimer(hwnd, kCloseFailsafeTimer, kCloseFailsafeMs, nullptr);
  }
  SendTrayEvent("closeRequested");
}

void FlutterWindow::CancelClose() {
  if (HWND hwnd = GetHandle()) {
    ::KillTimer(hwnd, kCloseFailsafeTimer);
  }
  close_pending_ = false;
}

void FlutterWindow::ShowAndFocus() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  // SW_SHOW to undo SW_HIDE, SW_RESTORE in case it was minimized before being
  // hidden, and the foreground call so that the window lands in front rather
  // than behind whatever else the user is reading.
  //
  // The foreground call is only permitted because the user just clicked
  // something belonging to this program -- its tray icon, or a second copy of
  // the executable, which hands its own foreground right over before asking.
  ::ShowWindow(hwnd, SW_SHOW);
  ::ShowWindow(hwnd, SW_RESTORE);
  ::SetForegroundWindow(hwnd);
}

void FlutterWindow::SendTrayEvent(const char* method,
                                  const flutter::EncodableValue* arguments) {
  if (!tray_channel_) {
    return;
  }
  if (arguments == nullptr) {
    // A null `arguments` encodes as "no arguments", which is what the three
    // argument-less events want. Sending an empty value instead would arrive in
    // Dart as an explicit null.
    tray_channel_->InvokeMethod(method, nullptr);
    return;
  }
  tray_channel_->InvokeMethod(
      method, std::make_unique<flutter::EncodableValue>(*arguments));
}

void FlutterWindow::SendTrayCommand(TrayWindow::Command command,
                                    const std::wstring& peer_id) {
  switch (command) {
    case TrayWindow::Command::kOpen:
      SendTrayEvent("open");
      return;
    case TrayWindow::Command::kQuit:
      SendTrayEvent("quit");
      return;
    case TrayWindow::Command::kPeer: {
      flutter::EncodableMap arguments;
      arguments[flutter::EncodableValue("peerId")] =
          flutter::EncodableValue(Utf8FromUtf16(peer_id.c_str()));
      const flutter::EncodableValue value(arguments);
      SendTrayEvent("peerSelected", &value);
      return;
    }
  }
}

void FlutterWindow::HandleTrayMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  HWND hwnd = GetHandle();

  if (method == "hide") {
    CancelClose();
    // The guard that keeps close-to-tray from locking anyone out. If the shell
    // is not showing the icon -- because it refused the NIM_ADD, or because
    // explorer restarted and the replacement failed -- then hiding would leave
    // a running process with a hidden window and nothing to click, and Task
    // Manager as the only way out. So a close with nowhere to hide becomes a
    // close.
    if (tray_ && tray_->has_icon() && hwnd != nullptr) {
      ::ShowWindow(hwnd, SW_HIDE);
    } else if (hwnd != nullptr) {
      // A close, because there is nowhere to hide. Posted for the same reason
      // the `quit` branch posts it.
      ::PostMessageW(hwnd, kQuitMessage, 0, 0);
    }
    result->Success();
    return;
  }

  if (method == "show") {
    CancelClose();
    ShowAndFocus();
    result->Success();
    return;
  }

  if (method == "quit") {
    CancelClose();
    // Answered before the window is destroyed, and the order is the point:
    // destroying the window runs `OnDestroy`, which destroys the engine and
    // with it the channel that owns `result`. Replying afterwards calls into
    // memory the engine has already released.
    result->Success();
    if (hwnd != nullptr) {
      // Posted, not called: this code is running inside the engine's dispatch
      // of a platform-channel call, and destroying the window here destroys the
      // engine that is doing the dispatching. The dispatch then unwinds through
      // a destroyed object and jumps through a freed vtable -- measured as a
      // guard-page violation at a garbage address in no module at all, every
      // time the tray menu's Quit was chosen. Posting moves the destruction to
      // the message loop, where the dispatch is finished and the engine has no
      // frame left on the stack.
      //
      // WM_DESTROY posts the quit message, which ends the loop in `main.cpp`
      // and takes the process with it. This relies on `SetQuitOnClose(true)`,
      // which is why that call stays.
      ::PostMessageW(hwnd, kQuitMessage, 0, 0);
    }
    return;
  }

  if (method == "setTrayVisible") {
    if (tray_) {
      bool visible = false;
      if (const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments())) {
        const auto it = arguments->find(flutter::EncodableValue("visible"));
        if (it != arguments->end()) {
          if (const bool* value = std::get_if<bool>(&it->second)) {
            visible = *value;
          }
        }
      }
      tray_->SetVisible(visible);
    }
    result->Success();
    return;
  }

  if (method == "setMenu") {
    if (tray_) {
      const auto* arguments =
          std::get_if<flutter::EncodableMap>(call.arguments());
      if (arguments != nullptr) {
        TrayWindow::Labels labels;
        labels.open = Utf16FromUtf8(StringFromMap(*arguments, "open"));
        labels.status = Utf16FromUtf8(StringFromMap(*arguments, "status"));
        labels.quit = Utf16FromUtf8(StringFromMap(*arguments, "quit"));
        labels.summary = Utf16FromUtf8(StringFromMap(*arguments, "summary"));

        std::vector<TrayWindow::Peer> peers;
        const auto it = arguments->find(flutter::EncodableValue("peers"));
        if (it != arguments->end()) {
          if (const auto* rows = std::get_if<flutter::EncodableList>(&it->second)) {
            peers.reserve(rows->size());
            for (const flutter::EncodableValue& row : *rows) {
              const auto* fields = std::get_if<flutter::EncodableMap>(&row);
              if (fields == nullptr) {
                continue;
              }
              TrayWindow::Peer peer;
              peer.id = Utf16FromUtf8(StringFromMap(*fields, "id"));
              peer.label = Utf16FromUtf8(StringFromMap(*fields, "label"));
              peers.push_back(std::move(peer));
            }
          }
        }

        // Labels first: the tooltip is rebuilt from them, and it reads the
        // summary, so setting peers the other way round would leave the
        // tooltip one list behind until the next push.
        tray_->SetLabels(std::move(labels));
        tray_->SetPeers(std::move(peers));
      }
    }
    result->Success();
    return;
  }

  if (method == "balloon") {
    if (tray_) {
      if (const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments())) {
        tray_->ShowBalloon(Utf16FromUtf8(StringFromMap(*arguments, "title")),
                           Utf16FromUtf8(StringFromMap(*arguments, "body")));
      }
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}
