#ifndef PRISMA_FRAMEBUFFER_H
#define PRISMA_FRAMEBUFFER_H

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

class Framebuffer {
public:
    Framebuffer(bool live, unsigned scale);
    ~Framebuffer();
    bool poll();
    uint32_t keys() const { return keys_; }
    bool live() const;
    void present(const std::vector<uint8_t>& rgb, unsigned width, unsigned height,
                 const std::string& title);
    static void save_png(const std::string& path, const std::vector<uint8_t>& rgb,
                         unsigned width, unsigned height);
private:
    struct Viewer;
    std::unique_ptr<Viewer> viewer_;
    uint32_t keys_ = 0;
    std::vector<uint8_t> last_rgb_;
    unsigned width_ = 0, height_ = 0;
};
#endif
