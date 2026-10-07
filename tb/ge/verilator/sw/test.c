#include "ge_test.h"

#include <stdio.h>
#include <string.h>
#include <math.h>
#include <stdarg.h>

static const test_config *config;
static unsigned case_index;
static const char *phase;

static void log_message(unsigned level, const char *format, ...) {
    if (level > config->verbosity) {
        return;
    }

    char text[768];
    va_list args;
    va_start(args, format);
    vsnprintf(text, sizeof(text), format, args);
    va_end(args);
    test_log(text);
}

static void enter(const char *name) {
    phase = name;
    test_phase(name, case_index);
    log_message(1, "[SW] test=%s case=%u phase=%s\n", test_names[config->test], case_index, name);
}

static int mismatch(const char *field, unsigned result, unsigned v, double expected, double actual,
                    double tolerance) {
    if (isfinite(actual) && fabs(expected - actual) <= tolerance) {
        return 0;
    }

    log_message(0,
                "FAIL phase=%s test=%s seed=%u timing_seed=%u triangle=%u result=%u vertex=%u "
                "field=%s expected=%.12g "
                "got=%.12g tolerance=%.12g\n",
                phase, test_names[config->test], config->seed, config->timing_seed, case_index,
                result, v, field, expected, actual, tolerance);
    return 1;
}

/* Machine-readable counters use test_log so the same report works under Spike. */
static void coverage_counts(const char *group, const unsigned *counts, unsigned size) {
    /* Existing runners can ignore added cross bins during an ongoing run. */
    const char *prefix = strcmp(group, "culling_winding") == 0 ?
                         "[triangle_coverage_cross]" : "[triangle_coverage]";
    log_message(0, "%s {\"group\":\"%s\",\"counts\":[", prefix, group);
    for (unsigned i = 0; i < size; ++i) {
        log_message(0, "%s%u", i ? "," : "", counts[i]);
    }
    log_message(0, "]}\n");
}

typedef struct {
    unsigned verified;
    unsigned planes[6][27];
    unsigned outputs[GE_MAX_OUTPUT + 1];
    unsigned culling[6];
    unsigned culling_winding[18];
    unsigned winding[3];
    unsigned matrix[2];
    unsigned viewport[2];
} triangle_coverage;

static void coverage_snapshot(const triangle_coverage *coverage) {
    static const char *const planes[] = {
        "plane_left", "plane_right", "plane_top", "plane_bottom", "plane_far", "plane_near"
    };
    coverage_counts("verified_triangles", &coverage->verified, 1);
    for (unsigned p = 0; p < 6; ++p) {
        coverage_counts(planes[p], coverage->planes[p], 27);
    }
    coverage_counts("output_triangles", coverage->outputs, GE_MAX_OUTPUT + 1);
    coverage_counts("culling", coverage->culling, 6);
    coverage_counts("culling_winding", coverage->culling_winding, 18);
    coverage_counts("input_winding", coverage->winding, 3);
    coverage_counts("matrix", coverage->matrix, 2);
    coverage_counts("viewport_parity", coverage->viewport, 2);
    test_phase("coverage_checkpoint", case_index);
}

int run_test(const test_config *cfg) {
    config = cfg;
    uint32_t seed = cfg->seed;
    unsigned count = cfg->test == TEST_RANDOM ? cfg->cases : 1;
    unsigned failures = 0;

    uint32_t previous_input = 0;
    uint32_t previous_output = 0;
    triangle property_result = {0};

    unsigned plane_coverage[6] = {0};
    unsigned output_coverage = 0;
    unsigned cull_coverage = 0;
    triangle_coverage coverage = {0};

    const double tolerances[] = {
        cfg->xy_tol, cfg->xy_tol,                 /* Screen X, Y */
        cfg->z_tol, cfg->w_tol,                   /* Depth, reciprocal W */
        cfg->uv_tol, cfg->uv_tol,                 /* UV / W */
        cfg->color_tol, cfg->color_tol,
        cfg->color_tol, cfg->color_tol,           /* RGBA */
    };
    unsigned batch = cfg->test == TEST_BACKPRESSURE ? 12 : 1;

    log_message(1, "[SW] begin test=%s seed=%u timing_seed=%u random_cases=%u\n",
                test_names[cfg->test], cfg->seed, cfg->timing_seed, cfg->cases);
    log_message(2, "[SW] tolerances xy=%g z=%g uv=%g color=%g inv_w=%g timeout=%u\n", cfg->xy_tol,
                cfg->z_tol, cfg->uv_tol, cfg->color_tol, cfg->w_tol, cfg->timeout);
    coverage_snapshot(&coverage);

    for (case_index = 0; case_index < count; ++case_index) {
        triangle input;
        triangle decoded;
        triangle expected[GE_MAX_OUTPUT];
        triangle decisions[GE_MAX_OUTPUT];
        geometry_config geometry;
        uint8_t packed[GE_STRIDE];
        uint8_t observed[GE_STRIDE];
        uint8_t guard[16];

        enter("generation");
        unsigned directed_count =
            generate_triangle(cfg->test, case_index, &seed, &input, &geometry);
        if (cfg->test != TEST_RANDOM) {
            count = directed_count;
        }

        pack_input(&input, packed);
        unpack_input(packed, &decoded);

        unsigned plane_states[6];
        unsigned fixed_count = golden_model(&decoded, &geometry, decisions, 1, plane_states);
        unsigned floating_count = golden_model(&decoded, &geometry, expected, 0, NULL);
        unsigned outputs = fixed_count * batch;
        if (cfg->test == TEST_OUTPUT_COUNTS) {
            failures += mismatch("stimulus_output_count", 0, 0, case_index, fixed_count, 0);
        }

        for (unsigned p = 0; p < 6; ++p) {
            plane_coverage[p] |= 1u << plane_states[p];
        }

        output_coverage |= 1u << fixed_count;
        cull_coverage |= 1u << (geometry.front * 3 + geometry.cull);

        /* Boundary cases use explicit Q16.16 clipping and Q16.8 area decisions.
         * Coordinate tolerances never change the expected triangle count. */
        int boundary = (cfg->test >= TEST_ON_PLANE && cfg->test <= TEST_NEAR_ZERO) ||
                       cfg->test == TEST_PLANE_STATES || cfg->test == TEST_OUTPUT_COUNTS ||
                       floating_count != fixed_count;
        if (boundary) {
            memcpy(expected, decisions, fixed_count * sizeof(triangle));
            log_message(2, "[SW] fixed decisions: floating_count=%u fixed_count=%u\n",
                        floating_count, fixed_count);
        }

        for (unsigned v = 0; v < 3; ++v) {
            log_message(2, "[SW] input v%u xyzw=(%g,%g,%g,%g) uv=(%g,%g) rgba=(%g,%g,%g,%g)\n", v,
                        decoded.v[v].f[0], decoded.v[v].f[1], decoded.v[v].f[2], decoded.v[v].f[3],
                        decoded.v[v].f[4], decoded.v[v].f[5], decoded.v[v].f[6], decoded.v[v].f[7],
                        decoded.v[v].f[8], decoded.v[v].f[9]);
        }

        enter("input_transfer");
        memset(guard, 0xd3, sizeof(guard));
        gpu_write(GE_INPUT - 16, guard, 16);
        for (unsigned i = 0; i < batch; ++i) {
            gpu_write(GE_INPUT + i * GE_STRIDE, packed, GE_STRIDE);
        }
        gpu_write(GE_INPUT + batch * GE_STRIDE, guard, 16);
        gpu_write(GE_OUTPUT - 16, guard, 16);
        /* Exact output capacity plus one guard detects extra writes immediately. */
        gpu_write(GE_OUTPUT + outputs * GE_STRIDE, guard, 16);

        unsigned attempts = cfg->test == TEST_RESET ? 2 : 1;
        for (unsigned attempt = 0; attempt < attempts; ++attempt) {
            enter("mmio_configuration");
            device_write(VTX_BASE, GE_INPUT);
            device_write(VTX_END, GE_INPUT + batch * GE_STRIDE);
            device_write(PRIM_BASE, GE_OUTPUT);
            device_write(PRIM_END, GE_OUTPUT + outputs * GE_STRIDE);

            for (unsigned i = 0; i < 16; ++i) {
                device_write(MTX + i, (uint32_t)(int32_t)llround(geometry.matrix[i] * 65536));
            }

            device_write(WIDTH, geometry.width);
            device_write(HEIGHT, geometry.height);
            device_write(IRQ_EN, 2);
            device_write(IRQ_PEND, 31);

            failures += mismatch("vtx_base", 0, 0, GE_INPUT, device_read(VTX_BASE), 0);
            failures += mismatch("prim_end", 0, 0, GE_OUTPUT + outputs * GE_STRIDE,
                                 device_read(PRIM_END), 0);
            log_message(2,
                        "[SW] viewport=%ux%u cull=%u front=%u expected_triangles=%u reference=%s\n",
                        geometry.width, geometry.height, geometry.cull, geometry.front, fixed_count,
                        boundary ? "fixed boundary" : "floating");

            enter("start");
            device_write(CTRL, 0x103 | geometry.cull << 5 | geometry.front << 4);

            if (attempt + 1 < attempts) {
                enter("reset");
                device_reset(case_index);
                previous_input = previous_output = 0;
                failures += mismatch("reset_status", 0, 0, 0, device_read(STATUS), 0);
                failures += mismatch("reset_input_count", 0, 0, 0, device_read(TRI_INPUT), 0);
                failures += mismatch("reset_output_count", 0, 0, 0, device_read(TRI_OUTPUT), 0);
            }
        }

        enter("completion_wait");
        uint32_t status = 0;
        uint32_t polls;
        for (polls = 0; polls < cfg->timeout; ++polls) {
            status = device_read(STATUS);
            if (status & 0x1a) {
                break;
            }
        }

        failures += mismatch("status_done", 0, 0, 2, status & 0x1b, 0);
        if (polls == cfg->timeout || (status & 0x18)) {
            failures++;
            break;
        }
        failures +=
            mismatch("input_count", 0, 0, previous_input + batch, device_read(TRI_INPUT), 0);
        failures +=
            mismatch("output_count", 0, 0, previous_output + outputs, device_read(TRI_OUTPUT), 0);
        failures += mismatch("done_irq", 0, 0, 2, device_read(IRQ_PEND) & 2, 0);
        previous_input += batch;
        previous_output += outputs;

        enter("result_read_compare");
        for (unsigned r = 0; r < outputs; ++r) {
            triangle actual;
            gpu_read(GE_OUTPUT + r * GE_STRIDE, observed, GE_STRIDE);
            unpack_output(observed, &actual);
            static const char *const fields[] = {
                "x", "y", "z", "inv_w", "u", "v", "r", "g", "b", "a"
            };

            for (unsigned v = 0; v < 3; ++v) {
                for (unsigned f = 0; f < 10; ++f) {
                    failures += mismatch(fields[f], r, v, expected[r % fixed_count].v[v].f[f],
                                         actual.v[v].f[f], tolerances[f]);
                }
            }

            if ((cfg->test == TEST_WINDING || cfg->test == TEST_ATTRIBUTES) && r == 0) {
                if (!case_index) {
                    property_result = actual;
                } else {
                    for (unsigned v = 0; v < 3; ++v) {
                        for (unsigned f = 0; f < 4; ++f) {
                            unsigned source = cfg->test == TEST_WINDING && v < 2 ? 1 - v : v;
                            failures +=
                                mismatch("property_geometry", r, v, property_result.v[source].f[f],
                                         actual.v[v].f[f], 0);
                        }
                    }
                }
            }
        }

        uint32_t addresses[] = {
            GE_INPUT - 16,
            GE_INPUT + batch * GE_STRIDE,
            GE_OUTPUT - 16,
            GE_OUTPUT + outputs * GE_STRIDE,
        };
        for (unsigned i = 0; i < 4; ++i) {
            gpu_read(addresses[i], observed, 16);
            for (unsigned b = 0; b < 16; ++b) {
                failures += mismatch("guard", i, b, guard[b], observed[b], 0);
            }
        }

        for (unsigned i = 0; i < batch; ++i) {
            gpu_read(GE_INPUT + i * GE_STRIDE, observed, GE_STRIDE);
            for (unsigned b = 0; b < GE_STRIDE; ++b) {
                failures += mismatch("input_preserved", i, b, packed[b], observed[b], 0);
            }
        }

        if (failures) {
            for (unsigned v = 0; v < 3; ++v) {
                log_message(0, "[SW] failing input v%u xyzw=(%.9g,%.9g,%.9g,%.9g) uv=(%.9g,%.9g)\n",
                            v, decoded.v[v].f[0], decoded.v[v].f[1], decoded.v[v].f[2],
                            decoded.v[v].f[3], decoded.v[v].f[4], decoded.v[v].f[5]);
            }
            break;
        }

        /* Credit bins only after all RTL results and integrity checks pass.
         * Batch duplicates count as separate input triangles; aborted reset
         * attempts never contribute to verified triangle counts. */
        coverage.verified += batch;
        for (unsigned p = 0; p < 6; ++p) {
            coverage.planes[p][plane_states[p]] += batch;
        }
        coverage.outputs[fixed_count] += batch;
        coverage.culling[geometry.front * 3 + geometry.cull] += batch;
        double area = (decoded.v[1].f[0] - decoded.v[0].f[0]) *
                          (decoded.v[2].f[1] - decoded.v[0].f[1]) -
                      (decoded.v[1].f[1] - decoded.v[0].f[1]) *
                          (decoded.v[2].f[0] - decoded.v[0].f[0]);
        unsigned winding = area < 0 ? 0 : area > 0 ? 1 : 2;
        coverage.winding[winding] += batch;
        coverage.culling_winding[winding * 6 + geometry.front * 3 + geometry.cull] += batch;
        unsigned transformed = 0;
        for (unsigned i = 0; i < 16; ++i) {
            transformed |= geometry.matrix[i] != (i % 5 == 0 ? 1.0 : 0.0);
        }
        coverage.matrix[transformed] += batch;
        coverage.viewport[(geometry.width & 1) || (geometry.height & 1)] += batch;
        if ((case_index + 1) % 1000 == 0) {
            coverage_snapshot(&coverage);
        }
    }

    log_message(0, "[SW] %s test=%s cases_completed=%u failures=%u seed=%u timing_seed=%u\n",
                failures ? "FAIL" : "PASS", test_names[cfg->test], case_index, failures, cfg->seed,
                cfg->timing_seed);
    log_message(0, "[coverage] output_count_mask=%02x cull_mask=%02x", output_coverage,
                cull_coverage);
    for (unsigned p = 0; p < 6; ++p) {
        log_message(0, " plane%u=%07x", p, plane_coverage[p]);
    }

    log_message(0, "\n");
    coverage_snapshot(&coverage);
    return failures ? 1 : 0;
}
