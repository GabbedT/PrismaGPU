#include "ge_test.h"

#include <math.h>
#include <string.h>
#include <assert.h>

static uint32_t bits_get(const uint8_t *p, unsigned offset, unsigned width) {
    uint32_t v = 0;
    for (unsigned i = 0; i < width; ++i) {
        v |= (uint32_t)((p[(offset + i) / 8] >> ((offset + i) % 8)) & 1) << i;
    }

    return v;
}

static void bits_put(uint8_t *p, unsigned offset, unsigned width, uint32_t value) {
    for (unsigned i = 0; i < width; ++i) {
        unsigned bit = offset + i;
        p[bit / 8] = (p[bit / 8] & ~(1u << (bit % 8))) | (((value >> i) & 1) << (bit % 8));
    }
}

static int32_t signed_bits(uint32_t v, unsigned width) {
    return (int32_t)(v << (32 - width)) >> (32 - width);
}

void pack_input(const triangle *input, uint8_t bytes[GE_STRIDE]) {
    memset(bytes, 0xa5, GE_STRIDE); /* Deliberately nonzero padding. */
    for (unsigned v = 0; v < 3; ++v) {
        for (unsigned f = 0; f < 6; ++f) {
            bits_put(bytes, v * 208 + 16 + (5 - f) * 32, 32,
                     (uint32_t)(int32_t)llround(input->v[v].f[f] * 65536));
        }

        for (unsigned f = 6; f < 10; ++f) {
            bits_put(bytes, v * 208 + (9 - f) * 4, 4, (uint32_t)input->v[v].f[f]);
        }
    }
}

void unpack_input(const uint8_t bytes[GE_STRIDE], triangle *input) {
    for (unsigned v = 0; v < 3; ++v) {
        for (unsigned f = 0; f < 6; ++f) {
            input->v[v].f[f] = (int32_t)bits_get(bytes, v * 208 + 16 + (5 - f) * 32, 32) / 65536.0;
        }

        for (unsigned f = 6; f < 10; ++f) {
            input->v[v].f[f] = bits_get(bytes, v * 208 + (9 - f) * 4, 4);
        }
    }
}

void unpack_output(const uint8_t bytes[GE_STRIDE], triangle *output) {
    for (unsigned v = 0; v < 3; ++v) {
        unsigned base = v * 183;

        for (unsigned f = 0; f < 3; ++f) {
            output->v[v].f[f] = signed_bits(bits_get(bytes, base + 111 + (2 - f) * 24, 24), 24) /
                                (f == 2 ? 65536.0 : 256.0);
        }

        double mantissa = bits_get(bytes, base + 86, 25) / 16777216.0;
        int exponent = signed_bits(bits_get(bytes, base + 80, 6), 6);
        output->v[v].f[3] = ldexp(mantissa, exponent);

        for (unsigned f = 4; f < 6; ++f) {
            output->v[v].f[f] = (int32_t)bits_get(bytes, base + 16 + (5 - f) * 32, 32) / 65536.0;
        }

        for (unsigned f = 6; f < 10; ++f) {
            output->v[v].f[f] = bits_get(bytes, base + (9 - f) * 4, 4);
        }
    }
}

int64_t unpack_output_area(const uint8_t bytes[GE_STRIDE]) {
    int64_t area = bits_get(bytes, 549, 32) | ((int64_t)bits_get(bytes, 581, 19) << 32);
    if (area & (INT64_C(1) << 50)) {
        area -= INT64_C(1) << 51;
    }
    return area;
}

static double distance(const vertex *v, unsigned plane) {
    const double *p = v->f;
    switch (plane) {
    case 0:
        return p[3] + p[0];
    case 1:
        return p[3] - p[0];
    case 2:
        return p[3] - p[1];
    case 3:
        return p[3] + p[1];
    case 4:
        return p[3] - p[2];
    default:
        return p[2];
    }
}

static vertex intersect(vertex a, vertex b, unsigned plane, int fixed) {
    double da = distance(&a, plane);
    double db = distance(&b, plane);
    double t = da / (da - db);
    if (fixed) {
        t = (da < 0 ? ceil(t * 65536) : floor(t * 65536)) / 65536;
    }

    vertex v;
    for (unsigned f = 0; f < 10; ++f) {
        v.f[f] = a.f[f] + t * (b.f[f] - a.f[f]);
        if (fixed) {
            if (f < 4) {
                v.f[f] = nearbyint(v.f[f] * 65536) / 65536;
            } else if (f < 6) {
                v.f[f] = floor(v.f[f] * 65536) / 65536;
            } else {
                v.f[f] = floor(v.f[f]);
            }
        }
    }

    /* Snap the intersection to the plane after quantizing the interpolated fields. */
    unsigned axis = plane / 2;
    if (plane == 5) {
        v.f[axis] = 0;
    } else if (plane == 0 || plane == 3) {
        v.f[axis] = -v.f[3];
    } else {
        v.f[axis] = v.f[3];
    }

    return v;
}

unsigned golden_model(const triangle *input, const geometry_config *geometry,
                      triangle out[GE_MAX_OUTPUT], int fixed, unsigned plane_states[6]) {
    vertex polygon[12];
    vertex next[12];
    unsigned vertex_count = 3;
    unsigned all_out = 63;
    unsigned any_out = 0;

    if (plane_states) {
        memset(plane_states, 0, 6 * sizeof(unsigned));
    }

    for (unsigned v = 0; v < 3; ++v) {
        polygon[v] = input->v[v];
        for (unsigned r = 0; r < 4; ++r) {
            double sum = 0;
            for (unsigned c = 0; c < 4; ++c) {
                sum += geometry->matrix[r * 4 + c] * input->v[v].f[c];
            }
            polygon[v].f[r] = fixed ? floor(sum * 65536) / 65536 : sum;
        }

        unsigned code = 0;
        for (unsigned p = 0; p < 6; ++p) {
            double d = distance(&polygon[v], p);
            if (d < 0) {
                code |= 1u << p;
            }

            if (plane_states) {
                /* Base-three signature: inside / outside / on-plane per vertex. */
                unsigned weight = v == 0 ? 1 : v == 1 ? 3 : 9;
                plane_states[p] += (d < 0 ? 1 : d == 0 ? 2 : 0) * weight;
            }
        }

        all_out &= code;
        any_out |= code;
    }

    if (all_out) {
        return 0;
    }

    /* The RTL emits the next endpoint, rotating even on non-crossed planes.
     * Trivial acceptance bypasses all six passes. Fan ordering is observable. */
    if (any_out) {
        for (unsigned p = 0; p < 6 && vertex_count >= 3; ++p) {
            unsigned next_count = 0;
            for (unsigned i = 0; i < vertex_count; ++i) {
                vertex a = polygon[i];
                vertex b = polygon[(i + 1) % vertex_count];
                double da = distance(&a, p);
                double db = distance(&b, p);

                if ((da < 0) != (db < 0) && da != 0 && db != 0) {
                    next[next_count++] = intersect(a, b, p, fixed);
                }

                if (db >= 0) {
                    next[next_count++] = b;
                }

                assert(next_count <= 9);
            }

            memcpy(polygon, next, next_count * sizeof(vertex));
            vertex_count = next_count;
        }
    }

    if (vertex_count < 3) {
        return 0;
    }

    /* Perspective division precedes the viewport mapping and screen-space culling. */
    for (unsigned i = 0; i < vertex_count; ++i) {
        double *p = polygon[i].f;
        double w = p[3];
        double reciprocal = 1 / w;
        if (fixed) {
            int exponent;
            double mantissa = frexp(w, &exponent) * 2;
            unsigned index = (unsigned)((mantissa - 1) * 1024);

            /* Midpoint LUT, Q1.24, then exponent scaling as in the numeric contract. */
            double midpoint = 1 + (index + 0.5) / 1024;
            double reciprocal_mantissa = round(16777216.0 / midpoint) / 16777216;
            reciprocal = ldexp(reciprocal_mantissa, 1 - exponent);
        }

        for (unsigned f = 0; f < 6; ++f) {
            if (f != 3) {
                p[f] *= reciprocal;
                if (fixed) {
                    p[f] = floor(p[f] * 65536) / 65536;
                }
            }
        }

        p[0] = (1 + p[0]) * geometry->width / 2;
        p[1] = (1 - p[1]) * geometry->height / 2;
        p[3] = reciprocal;
        if (fixed) {
            for (unsigned f = 0; f < 2; ++f) {
                p[f] = floor(p[f] * 256 + 0.5) / 256;
            }
        }
    }

    unsigned count = 0;
    for (unsigned i = 1; i + 1 < vertex_count; ++i) {
        triangle tri = {{polygon[0], polygon[i], polygon[i + 1]}};
        double *a = tri.v[0].f;
        double *b = tri.v[1].f;
        double *c = tri.v[2].f;
        double area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
        int front = geometry->front ? area < 0 : area > 0;
        if (area == 0 || (geometry->cull == 1 && front) || (geometry->cull == 2 && !front)) {
            continue;
        }

        assert(count < GE_MAX_OUTPUT);
        out[count++] = tri;
    }

    return count;
}
