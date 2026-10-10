#ifndef GE_TEST_H
#define GE_TEST_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum test_id {
    TEST_IDENTITY,
    TEST_CW,
    TEST_CCW,
    TEST_ZERO_AREA,
    TEST_VIEWPORT,
    TEST_INSIDE,
    TEST_CLIP_LEFT,
    TEST_CLIP_RIGHT,
    TEST_CLIP_TOP,
    TEST_CLIP_BOTTOM,
    TEST_CLIP_FAR,
    TEST_CLIP_NEAR,
    TEST_MULTI_PLANE,
    TEST_OUTSIDE,
    TEST_ON_PLANE,
    TEST_NEAR_PLANE,
    TEST_COINCIDENT,
    TEST_COLLINEAR,
    TEST_NEAR_ZERO,
    TEST_MATRIX,
    TEST_CULLING,
    TEST_RANDOM,
    TEST_WINDING,
    TEST_ATTRIBUTES,
    TEST_CONSECUTIVE,
    TEST_BACKPRESSURE,
    TEST_RESET,
    TEST_PLANE_STATES,
    TEST_OUTPUT_COUNTS
};

/* Four 128-bit words: 3*170 input bits plus 2 padding bits;
 * output is 3*158 vertex bits plus 38 signed area bits, without padding. */
enum {
    GE_STRIDE = 64,
    GE_MAX_OUTPUT = 7,
    GE_GPU_SIZE = 65536,
    GE_INPUT = 0x1000,
    GE_OUTPUT = 0x4000,
    GE_MMIO = 0x40000000,
    GE_GPU = 0x50000000,
    GE_HOST = 0x60000000
};

enum {
    CTRL = 0,
    STATUS = 1,
    VTX_BASE = 2,
    VTX_END = 3,
    PRIM_BASE = 4,
    PRIM_END = 5,
    IRQ_EN = 6,
    IRQ_PEND = 7,
    MTX = 12,
    WIDTH = 28,
    HEIGHT = 29,
    TRI_INPUT = 32,
    TRI_OUTPUT = 33
};

typedef struct {
    /* Field order follows the packed record: x, y, z, w, u, v, r, g, b, a. */
    double f[10];
} vertex;

typedef struct {
    vertex v[3];
} triangle;

typedef struct {
    uint32_t test;
    uint32_t seed;
    uint32_t timing_seed;
    uint32_t cases;
    uint32_t verbosity;
    uint32_t timeout;

    uint32_t latency;
    uint32_t pause;
    uint32_t output_hold;

    double xy_tol;
    double z_tol;
    double uv_tol;
    double color_tol;
    double w_tol;
} test_config;

typedef struct {
    double matrix[16];
    uint32_t width;
    uint32_t height;
    uint32_t cull;
    uint32_t front;
} geometry_config;

extern const char *const test_names[];
extern const unsigned test_count;

uint32_t ge_random(uint32_t *state);
unsigned generate_triangle(unsigned test, unsigned index, uint32_t *seed, triangle *input,
                           geometry_config *geometry);

void pack_input(const triangle *input, uint8_t bytes[GE_STRIDE]);
void unpack_input(const uint8_t bytes[GE_STRIDE], triangle *input);
void unpack_output(const uint8_t bytes[GE_STRIDE], triangle *output);
int64_t unpack_output_area(const uint8_t bytes[GE_STRIDE]);
unsigned golden_model(const triangle *input, const geometry_config *geometry,
                      triangle out[GE_MAX_OUTPUT], int fixed, unsigned plane_states[6]);
int run_test(const test_config *cfg);

/* Device operations are the only calls allowed to advance the RTL clock. */
void device_reset(unsigned stage);
void device_write(unsigned reg, uint32_t value);
uint32_t device_read(unsigned reg);
void gpu_write(uint32_t address, const uint8_t *bytes, size_t size);
void gpu_read(uint32_t address, uint8_t *bytes, size_t size);
void test_phase(const char *phase, unsigned index);
void test_log(const char *message);

#ifdef __cplusplus
}
#endif

#endif
