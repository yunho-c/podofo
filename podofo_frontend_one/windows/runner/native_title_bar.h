#ifndef RUNNER_NATIVE_TITLE_BAR_H_
#define RUNNER_NATIVE_TITLE_BAR_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>

// Keeps the system caption buttons in the non-client frame while Flutter draws
// the rest of the title bar. The Flutter child is clipped around that area so
// DWM receives real non-client input and owns painting, animation and tooltips.
class NativeTitleBar {
 public:
  NativeTitleBar(HWND window, HWND flutter_view,
                 flutter::BinaryMessenger* messenger);
  ~NativeTitleBar();

  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);
  void UpdateLayout();

 private:
  flutter::EncodableMap Metrics() const;
  void ExtendFrame();
  void UpdateAppearance();
  void UpdateHoverPreview(WPARAM hit);
  void HideHoverPreview();
  static LRESULT CALLBACK ViewSubclassProc(HWND window, UINT message,
                                          WPARAM wparam, LPARAM lparam,
                                          UINT_PTR id, DWORD_PTR data);

  HWND window_;
  HWND flutter_view_;
  bool enabled_ = false;
  bool updating_ = false;
  bool dark_ = false;
  // Temporary color experiment; the native buttons still receive all input.
  bool hover_preview_allowed_ = false;
  HWND hover_preview_ = nullptr;
  double height_ = 32;
  double buttons_width_ = 138;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_NATIVE_TITLE_BAR_H_
