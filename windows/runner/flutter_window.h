#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <optional>
#include <string>

#include "tray_window.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Handles the messages that belong to the tray. Returns nothing for every
  // other message, which is the overwhelming majority.
  //
  // Dealt with before the Flutter engine sees them, unlike `WM_FONTCHANGE`
  // below. `WM_CLOSE` in particular has to be answered by this file: whether
  // the window hides or dies is the whole point of close-to-tray, and letting
  // it reach `DefWindowProc` would destroy the window and end the process.
  std::optional<LRESULT> HandleTrayMessage(HWND hwnd, UINT message,
                                           WPARAM wparam,
                                           LPARAM lparam) noexcept;

  // The `com.feijian.lan/tray` channel -- the Dart side is
  // `lib/platform/tray_host.dart`.
  void HandleTrayMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Tells Dart the user asked to close the window, and arms the timer that
  // gives up waiting.
  void BeginClose();
  // Called once Dart has answered, or once the wait has been abandoned.
  void CancelClose();

  void SendTrayEvent(const char* method,
                     const flutter::EncodableValue* arguments = nullptr);
  void SendTrayCommand(TrayWindow::Command command,
                       const std::wstring& peer_id);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The notification-area icon. Null until `OnCreate`.
  std::unique_ptr<TrayWindow> tray_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      tray_channel_;

  // True between `BeginClose` and Dart's answer: the user has clicked X and
  // the decision belongs to Dart. A second click while this is set is ignored
  // rather than queued, because the answer to the first one is already the
  // answer to the second.
  bool close_pending_ = false;

  // True once Windows has said it is ending the session -- shutdown, restart or
  // log off. From then on `WM_CLOSE` means "close", not "hide": staying in the
  // tray through a shutdown would have Windows wait out its timeout and then
  // kill the process, which is slower and ruder than leaving when asked.
  bool session_ending_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
