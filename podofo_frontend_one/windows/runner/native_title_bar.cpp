#include "native_title_bar.h"

#include <dwmapi.h>
#include <commctrl.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>

namespace {
int ResizeBorder(HWND window) {
  const UINT dpi = GetDpiForWindow(window);
  return GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}
}  // namespace

NativeTitleBar::NativeTitleBar(HWND window, HWND flutter_view,
                             flutter::BinaryMessenger* messenger)
    : window_(window), flutter_view_(flutter_view) {
  SetWindowSubclass(flutter_view_, ViewSubclassProc, 1,
                    reinterpret_cast<DWORD_PTR>(this));
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "podofo/windows_title_bar",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "initialize") {
          enabled_ = true;
          SetWindowLongPtr(window_, GWL_STYLE,
                           GetWindowLongPtr(window_, GWL_STYLE) | WS_CLIPCHILDREN);
          ExtendFrame();
          SetWindowPos(window_, nullptr, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                           SWP_NOACTIVATE | SWP_FRAMECHANGED);
          UpdateLayout();
          result->Success(flutter::EncodableValue(Metrics()));
        } else if (call.method_name() == "setBrightness") {
          const auto* dark = call.arguments()
              ? std::get_if<bool>(call.arguments()) : nullptr;
          if (!dark) {
            result->Error("invalid_argument", "Expected a dark-mode boolean.");
            return;
          }
          dark_ = *dark;
          UpdateAppearance();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

NativeTitleBar::~NativeTitleBar() {
  channel_->SetMethodCallHandler(nullptr);
  if (IsWindow(flutter_view_)) {
    RemoveWindowSubclass(flutter_view_, ViewSubclassProc, 1);
  }
}

LRESULT CALLBACK NativeTitleBar::ViewSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR /*id*/, DWORD_PTR data) {
  auto* self = reinterpret_cast<NativeTitleBar*>(data);
  if (self->enabled_ && message == WM_NCHITTEST && !IsZoomed(self->window_)) {
    POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ScreenToClient(self->window_, &point);
    // Let the parent resize from the top edge without cutting Flutter's pixels
    // out of that strip. The caption button region is already excluded by HRGN.
    if (point.y >= 0 && point.y < ResizeBorder(self->window_)) {
      return HTTRANSPARENT;
    }
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

flutter::EncodableMap NativeTitleBar::Metrics() const {
  return {{flutter::EncodableValue("height"), flutter::EncodableValue(height_)},
          {flutter::EncodableValue("buttonsWidth"),
           flutter::EncodableValue(buttons_width_)}};
}

void NativeTitleBar::ExtendFrame() {
  const double scale = GetDpiForWindow(window_) / 96.0;
  const MARGINS margins = {0, 0, static_cast<int>(std::ceil(height_ * scale)), 0};
  DwmExtendFrameIntoClientArea(window_, &margins);
}

void NativeTitleBar::UpdateAppearance() {
  HIGHCONTRAST contrast{sizeof(contrast)};
  const bool high_contrast =
      SystemParametersInfo(SPI_GETHIGHCONTRAST, sizeof(contrast), &contrast, 0) &&
      (contrast.dwFlags & HCF_HIGHCONTRASTON);
  const BOOL dark = dark_ && !high_contrast;
  // Use numeric attributes so builds with older Windows SDKs remain supported.
  // Older Windows versions ignore unsupported DWM attributes. Keep text colors,
  // inactive visuals, hover/pressed effects and animations under system control.
  DwmSetWindowAttribute(window_, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */,
                        &dark, sizeof(dark));
  const COLORREF color = high_contrast ? 0xffffffff /* DWMWA_COLOR_DEFAULT */
                                      : (dark_ ? RGB(0, 0, 0) : RGB(255, 255, 255));
  DwmSetWindowAttribute(window_, 35 /* DWMWA_CAPTION_COLOR */,
                        &color, sizeof(color));
  RedrawWindow(window_, nullptr, nullptr, RDW_INVALIDATE | RDW_FRAME);
}

void NativeTitleBar::UpdateLayout() {
  if (!enabled_ || updating_ || IsIconic(window_)) return;
  updating_ = true;

  RECT client{};
  GetClientRect(window_, &client);
  RECT window{};
  GetWindowRect(window_, &window);
  POINT origin{};
  ClientToScreen(window_, &origin);
  const double scale = GetDpiForWindow(window_) / 96.0;
  RECT buttons{};
  const HRESULT hr = DwmGetWindowAttribute(
      window_, DWMWA_CAPTION_BUTTON_BOUNDS, &buttons, sizeof(buttons));
  // DWM reports window-relative physical pixels, not Flutter logical pixels.
  if (SUCCEEDED(hr) && buttons.right > buttons.left) {
    OffsetRect(&buttons, window.left - origin.x, window.top - origin.y);
  } else {
    // Bounds are undefined before a window is visible. Reserve a conservative
    // initial area; WM_WINDOWPOSCHANGED refreshes it as soon as DWM has bounds.
    buttons = {client.right - static_cast<LONG>(std::ceil(138 * scale)), 0,
               client.right, static_cast<LONG>(std::ceil(32 * scale))};
  }
  const int height = std::max(static_cast<int>(std::ceil(32 * scale)),
                              static_cast<int>(buttons.bottom));
  const int left = std::clamp(static_cast<int>(buttons.left), 0,
                             static_cast<int>(client.right));
  HRGN content = CreateRectRgn(0, 0, client.right, client.bottom);
  HRGN caption = CreateRectRgn(left, 0, client.right, height);
  CombineRgn(content, content, caption, RGN_DIFF);
  DeleteObject(caption);
  // On success Windows owns content and frees the preceding window region.
  if (!SetWindowRgn(flutter_view_, content, TRUE)) DeleteObject(content);

  const double new_height = height / scale;
  const double new_width = (client.right - left) / scale;
  const bool changed = height_ != new_height || buttons_width_ != new_width;
  height_ = new_height;
  buttons_width_ = new_width;
  ExtendFrame();
  if (changed) {
    channel_->InvokeMethod("metricsChanged",
                          std::make_unique<flutter::EncodableValue>(Metrics()));
  }
  updating_ = false;
}

std::optional<LRESULT> NativeTitleBar::HandleMessage(UINT message, WPARAM wparam,
                                                    LPARAM lparam) {
  if (!enabled_) return std::nullopt;
  if (message == WM_THEMECHANGED || message == WM_SYSCOLORCHANGE ||
      message == WM_SETTINGCHANGE || message == WM_DWMCOLORIZATIONCOLORCHANGED) {
    UpdateAppearance();
    // The base Flutter runner would replace the app's preference with the
    // system dark-mode preference for this message.
    if (message == WM_DWMCOLORIZATIONCOLORCHANGED) return 0;
  }
  if (message == WM_ACTIVATE || message == WM_DWMCOMPOSITIONCHANGED) {
    ExtendFrame();
  }
  if (message == WM_PAINT) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(window_, &paint);
    FillRect(dc, &paint.rcPaint, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
    EndPaint(window_, &paint);
    return 0;
  }
  if (message == WM_NCCALCSIZE && wparam) {
    auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    const LONG top = params->rgrc[0].top;
    // Retain the native left/right/bottom sizing frame. Only extend the client
    // over the caption. A maximized window's offscreen sizing border is excluded.
    DefWindowProc(window_, message, wparam, lparam);
    params->rgrc[0].top = top + (IsZoomed(window_) ? ResizeBorder(window_) : 0);
    return 0;
  }
  // Leave client-area messages (especially WM_SIZE and WM_WINDOWPOSCHANGED)
  // with the Flutter host. It must resize its child before updating the cutout.
  const bool non_client = message == WM_NCHITTEST || message == WM_NCPAINT ||
      message == WM_NCACTIVATE || message == WM_NCMOUSEHOVER ||
      message == WM_NCMOUSELEAVE ||
      (message >= WM_NCMOUSEMOVE && message <= WM_NCXBUTTONDBLCLK);
  LRESULT result = 0;
  const bool handled = non_client &&
      DwmDefWindowProc(window_, message, wparam, lparam, &result);
  if (handled && (message != WM_NCHITTEST || result != HTCLIENT)) return result;

  if (message == WM_NCHITTEST) {
    // DWM can return HTCLIENT for a maximized extended frame. Ask the system
    // for each actual caption rectangle instead of approximating button widths.
    // Returning HTMAXBUTTON here also preserves Windows 11 Snap Layouts.
    TITLEBARINFOEX info{};
    info.cbSize = sizeof(info);
    DefWindowProc(window_, WM_GETTITLEBARINFOEX, 0,
                  reinterpret_cast<LPARAM>(&info));
    const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    const int children[] = {2, 3, 5};
    const LRESULT hits[] = {HTMINBUTTON, HTMAXBUTTON, HTCLOSE};
    for (int i = 0; i < 3; ++i) {
      if (PtInRect(&info.rgrect[children[i]], point)) return hits[i];
    }
  }

  if (message == WM_NCHITTEST && !IsZoomed(window_)) {
    POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    ScreenToClient(window_, &point);
    const int border = ResizeBorder(window_);
    if (point.y >= 0 && point.y < border) {
      RECT client{};
      GetClientRect(window_, &client);
      if (point.x < border) return HTTOPLEFT;
      if (point.x >= client.right - border) return HTTOPRIGHT;
      return HTTOP;
    }
  }
  return handled ? std::optional<LRESULT>(result) : std::nullopt;
}
