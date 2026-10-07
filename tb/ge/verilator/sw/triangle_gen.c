#include "ge_test.h"

#include <string.h>

const char *const test_names[] = {
    "identity",
    "cw",
    "ccw",
    "zero_area",
    "viewport",
    "inside",
    "clip_left",
    "clip_right",
    "clip_top",
    "clip_bottom",
    "clip_far",
    "clip_near",
    "multi_plane",
    "outside",
    "on_plane",
    "near_plane",
    "coincident",
    "collinear",
    "near_zero",
    "matrix",
    "culling",
    "random",
    "winding",
    "attributes",
    "consecutive",
    "backpressure",
    "reset",
    "plane_states",
    "output_counts",
};

const unsigned test_count = sizeof(test_names) / sizeof(test_names[0]);

uint32_t ge_random(uint32_t *state) {
    /* Defined for every seed, including zero; independent of libc rand(). */
    *state = *state * 1664525u + 1013904223u;
    return *state;
}

unsigned generate_triangle(unsigned test, unsigned index, uint32_t *seed, triangle *input,
                           geometry_config *geometry) {
    static const double xy[3][2] = {{-0.5, -0.5}, {0.5, -0.5}, {0.5, 0.5}};

    memset(geometry, 0, sizeof(*geometry));
    for (unsigned i = 0; i < 4; ++i) {
        geometry->matrix[5 * i] = 1;
    }

    geometry->width = 640;
    geometry->height = 480;

    for (unsigned i = 0; i < 3; ++i) {
        vertex v = {{
            xy[i][0], xy[i][1], 0.5, 1,       /* Position */
            i * 0.25, (2 - i) * 0.25,        /* UV */
            2 + i * 4, 12 - i * 3, 3 + i, 15 /* RGBA */
        }};
        input->v[i] = v;
    }

    unsigned count = 1;

    /* Winding pairs preserve positions and attributes, changing only vertex order. */
    if (test == TEST_CW || test == TEST_WINDING) {
        if (test == TEST_CW || index % 2) {
            vertex v = input->v[0];
            input->v[0] = input->v[1];
            input->v[1] = v;
        }
        count = test == TEST_WINDING ? 2 : 1;
    }

    if (test == TEST_ZERO_AREA || test == TEST_COLLINEAR) {
        for (unsigned i = 0; i < 3; ++i) {
            input->v[i].f[1] = input->v[i].f[0];
        }
    }

    if (test == TEST_VIEWPORT) {
        geometry->width = 801;
        geometry->height = 603;
    }

    if (test >= TEST_CLIP_LEFT && test <= TEST_CLIP_NEAR) {
        unsigned plane = test - TEST_CLIP_LEFT;
        unsigned axis = plane / 2;
        double outside = (plane == 0 || plane == 3 || plane == 5) ? -1.5 : 1.5;

        input->v[index % 3].f[axis] = outside;
        if (index >= 3) {
            input->v[(index + 1) % 3].f[axis] = outside;
        }
        count = 6;
    }

    if (test == TEST_MULTI_PLANE) {
        input->v[0].f[0] = -2;
        input->v[1].f[1] = -2;
        input->v[2].f[2] = 2;
    }

    if (test == TEST_OUTSIDE) {
        for (unsigned i = 0; i < 3; ++i) {
            input->v[i].f[0] = -2;
        }
    }

    if (test == TEST_ON_PLANE || test == TEST_NEAR_PLANE) {
        unsigned plane = index % 6;
        unsigned axis = plane / 2;
        double bound = 1;
        if (plane == 5) {
            bound = 0;
        } else if (plane == 0 || plane == 3) {
            bound = -1;
        }

        double offset = 0;
        if (test == TEST_NEAR_PLANE) {
            offset = ((int)(index / 6) - 2) / 65536.0;
        }

        input->v[0].f[axis] = bound + offset;
        count = test == TEST_ON_PLANE ? 6 : 30;
    }

    if (test == TEST_COINCIDENT) {
        input->v[1] = input->v[0];
    }

    if (test == TEST_NEAR_ZERO) {
        input->v[2] = input->v[1];
        input->v[2].f[1] += 1.0 / 65536;
    }

    if (test == TEST_MATRIX) {
        geometry->matrix[0] = 0.5;
        geometry->matrix[3] = 0.125;
        geometry->matrix[5] = 0.25;
        geometry->matrix[15] = 2;
    }

    if (test == TEST_CULLING) {
        geometry->cull = index % 3;
        geometry->front = (index / 3) % 2;
        if (index / 6 == 1) {
            vertex v = input->v[0];
            input->v[0] = input->v[1];
            input->v[1] = v;
        } else if (index / 6 == 2) {
            for (unsigned v = 0; v < 3; ++v) {
                input->v[v].f[1] = input->v[v].f[0];
            }
        }
        count = 18;
    }

    if (test == TEST_PLANE_STATES) {
        unsigned plane = index / 27;
        unsigned signature = index % 27;
        unsigned axis = plane / 2;
        double bound = plane == 5 ? 0 : (plane == 0 || plane == 3 ? -1 : 1);
        double direction = plane == 0 || plane == 3 || plane == 5 ? -1 : 1;
        for (unsigned v = 0; v < 3; ++v) {
            unsigned state = signature % 3;
            signature /= 3;
            if (state == 1) {
                input->v[v].f[axis] = bound + direction * (0.25 + v * 0.125);
            } else if (state == 2) {
                input->v[v].f[axis] = bound;
            }
        }
        count = 6 * 27;
    }

    if (test == TEST_OUTPUT_COUNTS) {
        /* Fixed Q16.16 inputs found with the independent reference model.
         * Row n must produce exactly n triangles after multi-plane clipping. */
        static const double positions[8][3][3] = {
            {{3.625, -1.3125, 1.0625}, {3.125, -1.75, 0.875}, {0.5, 2.75, 4.1875}},
            {{2, 0.5625, 0.125}, {-0.625, 1, -2.9375}, {-1, 2.75, 4.125}},
            {{1, 1.125, 0.4375}, {1.125, 0.1875, 3.4375}, {-0.375, -3.5625, 3.375}},
            {{0.8125, -1.375, -2.75}, {-1, 1.25, 3.125}, {3.375, -1.25, -2.375}},
            {{-1, -3.25, -2.6875}, {1.6875, 1.0625, 1.125}, {-0.4375, -0.875, 0.5625}},
            {{-0.5625, 1.375, -3.375}, {-1.5625, 1.3125, -0.0625}, {2.25, -1.1875, 3.9375}},
            {{1.6875, 3.9375, -0.625}, {-3.8125, -3.625, 0.6875}, {0.9375, 0.1875, 0.75}},
            {{-3.6875, -0.375, -1.5625}, {0.6875, -1.0625, 0.4375}, {2.375, 2.25, 2.9375}},
        };
        for (unsigned v = 0; v < 3; ++v) {
            for (unsigned axis = 0; axis < 3; ++axis) {
                input->v[v].f[axis] = positions[index][v][axis];
            }
        }
        count = 8;
    }

    if (test == TEST_RANDOM) {
        for (unsigned i = 0; i < 3; ++i) {
            for (unsigned j = 0; j < 3; ++j) {
                input->v[i].f[j] = ((int)(ge_random(seed) % 196609) - 65536) / 65536.0;
            }
            input->v[i].f[4] = (ge_random(seed) % 65536) / 65536.0;
            input->v[i].f[5] = (ge_random(seed) % 65536) / 65536.0;
        }

        geometry->cull = index % 3;
        geometry->front = (index / 3) % 2;
        geometry->width = 320 + ge_random(seed) % 481;
        geometry->height = 240 + ge_random(seed) % 361;
        geometry->matrix[0] = (index % 3 + 1) * 0.5;
        geometry->matrix[5] = 0.5 + (index % 2) * 0.5;
        geometry->matrix[3] = (index % 2) * 0.125;
        geometry->matrix[15] = 1 + index % 2;
    }

    if (test == TEST_ATTRIBUTES) {
        count = 2;
        if (index) {
            for (unsigned i = 0; i < 3; ++i) {
                for (unsigned j = 4; j < 10; ++j) {
                    input->v[i].f[j] *= 0.5;
                }
            }
        }
    }

    if (test == TEST_RESET) {
        input->v[0].f[0] = -2;
        count = 7;
    }

    if (test == TEST_CONSECUTIVE) {
        count = 8;
    }

    return count;
}
