#include "framebuffer.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <stdexcept>
#include <zlib.h>
#ifdef PGPU_HAVE_X11
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#endif

//====================================================================================
//      OPTIONAL LIVE DISPLAY AND KEYBOARD
//====================================================================================

struct Framebuffer::Viewer {
#ifdef PGPU_HAVE_X11
    Display* display = nullptr;
    Window window = 0;
    GC gc = nullptr;
    XImage* image = nullptr;
    Atom close_atom = 0;
    unsigned scale;
    explicit Viewer(unsigned scale) : scale(scale) {
        display = XOpenDisplay(nullptr);
        if (!display) return;
        const int screen = DefaultScreen(display);
        window = XCreateSimpleWindow(display, RootWindow(display, screen), 0, 0, 320*scale, 240*scale,
                                     0, BlackPixel(display, screen), BlackPixel(display, screen));
        gc = XCreateGC(display, window, 0, nullptr);
        XSelectInput(display, window, ExposureMask | KeyPressMask | KeyReleaseMask | FocusChangeMask);
        close_atom = XInternAtom(display, "WM_DELETE_WINDOW", False);
        XSetWMProtocols(display, window, &close_atom, 1);
        XStoreName(display, window, "PrismaGPU | waiting for completed frame");
        XMapWindow(display, window);
        XFlush(display);
    }
    ~Viewer() {
        if (image) XDestroyImage(image);
        if (display && gc) XFreeGC(display, gc);
        if (display && window) XDestroyWindow(display, window);
        if (display) XCloseDisplay(display);
    }
    bool live() const { return display != nullptr; }
    bool poll(uint32_t& keys, bool& redraw) {
        while (display && XPending(display)) {
            XEvent event;
            XNextEvent(display, &event);
            if (event.type == ClientMessage && static_cast<Atom>(event.xclient.data.l[0]) == close_atom) return false;
            if (event.type == Expose) redraw = true;
            if (event.type == FocusOut) keys = 0;
            if (event.type == KeyPress || event.type == KeyRelease) {
                const KeySym key = XLookupKeysym(&event.xkey, 0);
                if (key == XK_Escape || key == XK_q || key == XK_Q) return false;
                uint32_t bit = 0;
                if (key == XK_Left || key == XK_a || key == XK_A) bit = 1;
                if (key == XK_Right || key == XK_d || key == XK_D) bit = 2;
                if (key == XK_Up || key == XK_w || key == XK_W) bit = 4;
                if (key == XK_Down || key == XK_s || key == XK_S) bit = 8;
                if (key == XK_space) bit = 16;
                if (event.type == KeyPress) keys |= bit; else keys &= ~bit;
            }
        }
        return true;
    }
    static unsigned long channel(unsigned value, unsigned long mask) {
        if (!mask) return 0;
        unsigned shift = 0;
        while (((mask >> shift) & 1) == 0) ++shift;
        return ((value * (mask >> shift) + 127) / 255) << shift;
    }
    void render(const std::vector<uint8_t>& rgb, unsigned width, unsigned height, const std::string& title) {
        if (!display || rgb.empty()) return;
        if (!image || unsigned(image->width) != width*scale || unsigned(image->height) != height*scale) {
            if (image) XDestroyImage(image);
            const int screen = DefaultScreen(display);
            XResizeWindow(display, window, width*scale, height*scale);
            image = XCreateImage(display, DefaultVisual(display, screen), DefaultDepth(display, screen),
                                 ZPixmap, 0, nullptr, width*scale, height*scale, 32, 0);
            if (!image) throw std::runtime_error("XCreateImage failed");
            image->data = static_cast<char*>(std::calloc(image->bytes_per_line, image->height));
            if (!image->data) throw std::runtime_error("XImage allocation failed");
        }
        for (unsigned y = 0; y < height; y++) for (unsigned x = 0; x < width; x++) {
            const unsigned i = 3*(y*width+x);
            const auto pixel = channel(rgb[i], image->red_mask) | channel(rgb[i+1], image->green_mask) |
                               channel(rgb[i+2], image->blue_mask);
            for (unsigned dy = 0; dy < scale; dy++) for (unsigned dx = 0; dx < scale; dx++)
                XPutPixel(image, x*scale+dx, y*scale+dy, pixel);
        }
        if (!title.empty()) XStoreName(display, window, title.c_str());
        XPutImage(display, window, gc, image, 0, 0, 0, 0, image->width, image->height);
        XFlush(display);
    }
#else
    explicit Viewer(unsigned) {}
    bool live() const { return false; }
    bool poll(uint32_t&, bool&) { return true; }
    void render(const std::vector<uint8_t>&, unsigned, unsigned, const std::string&) {}
#endif
};

Framebuffer::Framebuffer(bool live, unsigned scale) {
    if (live) viewer_ = std::make_unique<Viewer>(std::clamp(scale, 1u, 4u));
}
Framebuffer::~Framebuffer() = default;
bool Framebuffer::live() const { return viewer_ && viewer_->live(); }
bool Framebuffer::poll() {
    bool redraw = false;
    if (viewer_ && !viewer_->poll(keys_, redraw)) return false;
    if (redraw) viewer_->render(last_rgb_, width_, height_, "");
    return true;
}
void Framebuffer::present(const std::vector<uint8_t>& rgb, unsigned width, unsigned height, const std::string& title) {
    last_rgb_ = rgb;
    width_ = width;
    height_ = height;
    if (viewer_) viewer_->render(rgb, width, height, title);
}

//====================================================================================
//      ATOMIC PNG CAPTURE (RGB888, FILTER ZERO)
//====================================================================================

static void be32(std::vector<uint8_t>& bytes, uint32_t value) {
    for (int shift = 24; shift >= 0; shift -= 8) bytes.push_back(uint8_t(value >> shift));
}
static void chunk(std::vector<uint8_t>& png, const char* tag, const std::vector<uint8_t>& bytes) {
    be32(png, bytes.size());
    const size_t start = png.size();
    png.insert(png.end(), tag, tag+4);
    png.insert(png.end(), bytes.begin(), bytes.end());
    be32(png, crc32(0, png.data()+start, png.size()-start));
}
void Framebuffer::save_png(const std::string& path, const std::vector<uint8_t>& rgb, unsigned width, unsigned height) {
    std::vector<uint8_t> raw;
    raw.reserve(height*(1+3*width));
    for (unsigned y = 0; y < height; y++) {
        raw.push_back(0);
        raw.insert(raw.end(), rgb.begin()+y*width*3, rgb.begin()+(y+1)*width*3);
    }
    uLongf length = compressBound(raw.size());
    std::vector<uint8_t> compressed(length);
    if (compress2(compressed.data(), &length, raw.data(), raw.size(), 1) != Z_OK)
        throw std::runtime_error("PNG compression failed");
    compressed.resize(length);
    std::vector<uint8_t> png = {137,80,78,71,13,10,26,10}, ihdr;
    be32(ihdr, width); be32(ihdr, height);
    ihdr.insert(ihdr.end(), {8,2,0,0,0});
    chunk(png, "IHDR", ihdr); chunk(png, "IDAT", compressed); chunk(png, "IEND", {});
    const std::string temporary = path + ".tmp";
    std::ofstream file(temporary, std::ios::binary);
    file.write(reinterpret_cast<const char*>(png.data()), png.size());
    file.close();
    if (!file || std::rename(temporary.c_str(), path.c_str()) != 0)
        throw std::runtime_error("Cannot write PNG: " + path);
}
