#ifndef PRISMA_GPU_APP_H
#define PRISMA_GPU_APP_H
#include <stdint.h>
#include <stddef.h>

#define GPU_REG_BASE 0x40000000u
#define GPU_RAM_BASE 0x50000000u
#define HOST_BASE    0x60000000u
#define VERTEX_BASE  0x00010000u
#define PRIM_BASE    0x00100000u
#define PRIM_LIMIT   0x00300000u
#define COMMAND_BASE 0x00001000u
#define TEXTURE_BASE 0x00002000u
#define FB_BASE      0x00400000u
#define Z_BASE       0x00500000u
#define MAX_TRIANGLES 4096u

enum { GE_CTRL=0x00, GE_STATUS=0x04, GE_VTX_BASE=0x08, GE_VTX_END=0x0c,
       GE_PRIM_BASE=0x10, GE_PRIM_END=0x14, GE_IRQ=0x1c, GE_MATRIX=0x30,
       GE_WIDTH=0x70, GE_HEIGHT=0x74, GE_INPUT=0x80, GE_OUTPUT=0x84 };
enum { RE_CTRL=0x100, RE_STATUS=0x104, RE_CMD_BASE=0x108, RE_CMD_END=0x10c,
       RE_PRIM_BASE=0x110, RE_PRIM_END=0x114, RE_IRQ=0x11c,
       RE_Z_BASE=0x120, RE_Z_END=0x124, RE_DRAW=0x128, RE_Z_CFG=0x12c,
       RE_TEX_CFG=0x130, RE_VIEWPORT=0x134, RE_BLEND_CFG=0x138, RE_FB_BASE=0x14c, RE_FB_END=0x150,
       RE_INPUT=0x180, RE_DONE=0x184, RE_PIXELS=0x190, RE_Z_REJECT=0x194 };
enum { KEY_LEFT=1, KEY_RIGHT=2, KEY_UP=4, KEY_DOWN=8, KEY_SPACE=16 };
typedef struct { float x,y,z,w; uint16_t rgb; float u,v; } vertex_t;
typedef struct { vertex_t v[3]; } triangle_t;
typedef struct { unsigned frames, triangles, seed, autopilot, width; } app_config_t;

static inline void reg_write(unsigned offset, uint32_t value) {
    *(volatile uint32_t*)(uintptr_t)(GPU_REG_BASE+offset) = value;
}
static inline uint32_t reg_read(unsigned offset) {
    return *(volatile uint32_t*)(uintptr_t)(GPU_REG_BASE+offset);
}
static inline uint32_t host_read(unsigned offset) {
    return *(volatile uint32_t*)(uintptr_t)(HOST_BASE+offset);
}
static inline void host_write(unsigned offset, uint32_t value) {
    *(volatile uint32_t*)(uintptr_t)(HOST_BASE+offset) = value;
}
static inline uint64_t perf_read(unsigned index) {
    return *(volatile uint64_t*)(uintptr_t)(HOST_BASE+0x200+index*8);
}
void app_exit(int status) __attribute__((noreturn));
void app_check(int condition, const char* message);
app_config_t app_config(void);
void gpu_init(unsigned width, int depth);
void gpu_matrix(const float matrix[16]);
void gpu_identity(void);
void gpu_projection(float near, float far);
void gpu_clear(uint16_t rgb, int depth);
void gpu_upload(const triangle_t* triangles, unsigned count);
void gpu_render(unsigned count, int passthrough);
void gpu_style(int depth, int texture, int gouraud, unsigned alpha);
void gpu_texture(const uint16_t* texels, unsigned size);
uint64_t host_millis(void);
void host_wait_until(uint64_t milliseconds);
void host_phase(unsigned phase);
unsigned demo_scene(void);
unsigned demo_duration(void);
uint16_t gpu_pixel(unsigned x, unsigned y);
uint32_t app_random(uint32_t* state);
int benchmark_run(unsigned kind, int passthrough);
#endif
