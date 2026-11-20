// screen_capture_x11.cc
//
// X11 sessions ke liye direct XGetImage-based capture (fast, simple, no
// consent dialog exists at the X11 protocol level — is wajah se yeh sirf
// tab use hona chahiye jab app khud already user-authorized context mein
// chal rahi ho, jaisa poore architecture doc mein assume kiya gaya hai).
// Wayland ke liye alag file — screen_capture_wayland_portal.cc — kyunki
// Wayland compositors security ki wajah se arbitrary XGetImage-jaisi
// direct access allow nahi karte.

#include "screen_capture_x11.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <turbojpeg.h>

#include <cstring>
#include <vector>

namespace {

// XImage (BGRA-ish, X11 dependent byte order) ko JPEG bytes mein encode
// karta hai libjpeg-turbo se — Android/Windows dono ke frame format se
// consistent (JPEG-over-base64).
std::vector<unsigned char> EncodeAsJpeg(XImage* image) {
  // Item 83: TJPF_BGRX sirf 32bpp little-endian TrueColor ke liye sahi hai.
  // Pehle koi check nahi tha (16/24bpp visuals par garbage ya crash).
  if (image == nullptr || image->data == nullptr ||
      image->bits_per_pixel != 32 || image->width <= 0 || image->height <= 0) {
    return {};
  }
  tjhandle compressor = tjInitCompress();
  if (compressor == nullptr) return {};  // pehle null deref ho sakta tha
  unsigned char* jpeg_buf = nullptr;
  unsigned long jpeg_size = 0;

  int rc = tjCompress2(compressor, reinterpret_cast<unsigned char*>(image->data),
                       image->width, image->bytes_per_line, image->height,
                       TJPF_BGRX, &jpeg_buf, &jpeg_size, TJSAMP_420, 60,
                       TJFLAG_FASTDCT);

  std::vector<unsigned char> result;
  if (rc == 0 && jpeg_buf != nullptr && jpeg_size > 0) {
    result.assign(jpeg_buf, jpeg_buf + jpeg_size);
  }
  if (jpeg_buf != nullptr) tjFree(jpeg_buf);
  tjDestroy(compressor);
  return result;
}

}  // namespace

bool ScreenCaptureX11::IsAvailable() {
  Display* display = XOpenDisplay(nullptr);
  if (display == nullptr) return false;
  XCloseDisplay(display);
  return true;
}

std::vector<unsigned char> ScreenCaptureX11::CaptureFrameAsJpeg() {
  Display* display = XOpenDisplay(nullptr);
  if (display == nullptr) return {};

  Window root = DefaultRootWindow(display);
  XWindowAttributes attrs;
  XGetWindowAttributes(display, root, &attrs);

  XImage* image = XGetImage(display, root, 0, 0, attrs.width, attrs.height,
                             AllPlanes, ZPixmap);
  if (image == nullptr) {
    XCloseDisplay(display);
    return {};
  }

  auto jpeg = EncodeAsJpeg(image);

  XDestroyImage(image);
  XCloseDisplay(display);
  return jpeg;
}
