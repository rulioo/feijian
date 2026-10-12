#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "single_instance.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Before COM, before the engine, and before anything binds the discovery
  // port: a second launch is a request to see the window that is already up,
  // not a request for a second copy of the program. See `single_instance.h`.
  //
  // The handle is held until this function returns, which is what keeps the
  // mutex alive for as long as the process is: releasing it earlier would let
  // the next launch start a second instance.
  HANDLE instance_mutex = nullptr;
  switch (single_instance::Claim(&instance_mutex)) {
    case single_instance::ClaimResult::kAlreadyRunning:
      // Nothing found means nothing to show -- the instance that holds the lock
      // is shutting down, or is elevated and will not hear from us. Either way
      // this process has nothing left to do.
      single_instance::ActivateRunningInstance();
      return EXIT_SUCCESS;
    case single_instance::ClaimResult::kUnavailable:
      // Whether anything else is running is unknown, so the only options are to
      // start and risk a duplicate or to refuse to start at all. A program that
      // will not start when asked is a worse failure than the one this guards
      // against, so it starts -- and `instance_mutex` stays null, which the
      // CloseHandle at the end of this function accounts for.
      break;
    case single_instance::ClaimResult::kFirstInstance:
      break;
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // What the taskbar and the title bar show. The binary stays `feijian.exe`
  // (windows/CMakeLists.txt `BINARY_NAME`), which is a filename; this is the
  // product name, and the product is called Feijian.
  if (!window.Create(L"Feijian", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
