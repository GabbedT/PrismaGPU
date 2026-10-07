#include "Vtb_top.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include "sw/ge_test.h"

#include <array>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>

#ifdef WITH_SPIKE
#include "riscv/abstract_device.h"
#include "riscv/cfg.h"
#include "riscv/sim.h"
#include "riscv/processor.h"
#include "fesvr/elfloader.h"
#include <optional>
#endif

static test_config config;
static std::string phase = "setup";
static unsigned triangle_index;

static uint64_t cycles;
static uint64_t start_cycle;

/* One output response may be pending between the FIFO read and memory write. */
static uint32_t timing_state;
static uint32_t source;
static uint32_t destination;
static uint32_t reads;
static uint32_t writes;
static uint32_t pending_delay;
static bool active;
static bool pending_write;
static std::array<uint32_t, 4> pending_data;

static std::unique_ptr<Vtb_top> dut;
static std::unique_ptr<VerilatedFstC> trace;

static uint64_t stage_count[7];
static uint64_t pause_count;
static uint64_t input_stalls;
static uint64_t output_stalls;

static FILE *output_file;
static std::string coverage_file;

static void save_coverage() {
#if VM_COVERAGE
    if (dut && !coverage_file.empty() && coverage_file != "-") {
        // A killed process must leave its previous complete checkpoint intact.
        std::string temporary = coverage_file + ".tmp";
        VerilatedCov::write(temporary.c_str());
        if (std::rename(temporary.c_str(), coverage_file.c_str()) != 0) {
            throw std::runtime_error("cannot save coverage checkpoint");
        }
    }
#endif
}
static const char *const stages[] = {
    "unpack",
    "matrix",
    "clip_assemble",
    "perspective",
    "viewport",
    "cull",
    "pack",
};

static void fail(const char *field, uint64_t expected, uint64_t got) {
    char message[512];

    snprintf(message, sizeof(message),
             "phase=%s seed=%u timing_seed=%u triangle=%u field=%s expected=%llu got=%llu "
             "tolerance=0 cycle=%llu",
             phase.c_str(), config.seed, config.timing_seed, triangle_index, field,
             (unsigned long long)expected, (unsigned long long)got, (unsigned long long)cycles);
    if (dut && active) {
        uint8_t packed[GE_STRIDE];

        auto saved_address = dut->sw_address_i;
        for (unsigned word = 0; word < 5; ++word) {
            dut->sw_address_i = dut->vertex_buffer_base_o + word * 16;
            dut->eval();
            for (unsigned b = 0; b < 16; ++b) {
                packed[word * 16 + b] = dut->sw_data_o[b / 4] >> ((b % 4) * 8);
            }
        }

        dut->sw_address_i = saved_address;

        triangle input;
        unpack_input(packed, &input);
        for (unsigned v = 0; v < 3; ++v) {
            printf("[wrapper] input v%u xyzw=(%g,%g,%g,%g) uv=(%g,%g) rgba=(%g,%g,%g,%g)\n", v,
                   input.v[v].f[0], input.v[v].f[1], input.v[v].f[2], input.v[v].f[3],
                   input.v[v].f[4], input.v[v].f[5], input.v[v].f[6], input.v[v].f[7],
                   input.v[v].f[8], input.v[v].f[9]);
        }
    }

    throw std::runtime_error(message);
}

static void edge(bool high) {
    dut->clk_i = high;
    dut->eval();
    if (trace) {
        trace->dump(Verilated::time());
    }

    Verilated::timeInc(5);
}

static void tick() {
    dut->write_i = 0;
    dut->read_i = 0;
    dut->agent_write_i = 0;

    unsigned output_hold = config.output_hold;
    if (config.test == TEST_BACKPRESSURE) {
        output_hold = std::max(1000u, output_hold);
    }

    if (active) {
        if (cycles - start_cycle >= config.timeout) {
            fail("completion_timeout", config.timeout, cycles - start_cycle);
        }

        if (pending_write) {
            if (pending_delay) {
                --pending_delay;
            } else {
                if (destination + 16 > dut->primitive_buffer_end_o) {
                    fail("output_address_limit", dut->primitive_buffer_end_o, destination + 16);
                }

                dut->agent_address_i = destination;
                std::copy(pending_data.begin(), pending_data.end(), &dut->agent_data_i[0]);
                dut->agent_write_i = 1;
            }
        } else if (ge_random(&timing_state) % 100 < config.pause) {
            ++pause_count;
        } else if (dut->output_word_count_o && cycles - start_cycle >= output_hold) {
            dut->read_i = 1;
        } else if (source < dut->vertex_buffer_end_o && dut->input_word_count_o < 16) {
            if (pending_delay) {
                --pending_delay;
            } else {
                dut->agent_address_i = source;
                dut->eval();
                std::copy(&dut->agent_data_o[0], &dut->agent_data_o[4], &dut->write_data_i[0]);
                dut->write_i = 1;
            }
        }
    }

    dut->eval();
    if (dut->rst_n_i && dut->error_o) {
        fail("pipeline_error", 0, dut->error_o);
    }

    if (dut->rst_n_i) {
        input_stalls += dut->input_blocked_o;
        output_stalls += dut->output_blocked_o;
    }

    unsigned transfers = dut->rst_n_i ? dut->stage_valid_o : 0;
    for (unsigned s = 0; s < 7; ++s) {
        if (transfers & (1u << s)) {
            ++stage_count[s];
            if (config.verbosity >= 2) {
                static const unsigned widths[] = {208, 208, 208, 208, 183, 549, 128};
                printf("[RTL] cycle=%llu stage=%s transfer=%llu data=", (unsigned long long)cycles,
                       stages[s], (unsigned long long)stage_count[s]);
                for (int bit = ((widths[s] + 3) / 4) * 4 - 4; bit >= 0; bit -= 4) {
                    unsigned nibble = 0;
                    for (unsigned b = 0; b < 4 && bit + b < widths[s]; ++b) {
                        unsigned index = s * 624 + bit + b;
                        nibble |= ((dut->stage_data_o[index / 32] >> (index % 32)) & 1u) << b;
                    }
                    printf("%x", nibble);
                }
                puts("");
            }
        }
    }

    bool pushed = dut->write_i;
    bool pulled = dut->read_i;
    bool stored = dut->agent_write_i;

    edge(true);
    if (pushed) {
        if (config.verbosity >= 2) {
            printf("[agent] read addr=%08x word=%u\n", source, reads);
        }
        source += 16;
        ++reads;
        pending_delay = config.latency ? ge_random(&timing_state) % (config.latency + 1) : 0;
    }

    if (pulled) {
        // Output is a registered FIFO response, valid only after this edge.
        std::copy(&dut->read_data_o[0], &dut->read_data_o[4], pending_data.begin());
        pending_write = true;
        pending_delay = config.latency ? ge_random(&timing_state) % (config.latency + 1) : 0;
    }

    if (stored) {
        // Canonicalize padding before saving output for exact timing comparisons.
        auto record = pending_data;
        if (writes % 5 == 4) {
            record[1] &= 31;
            record[2] = record[3] = 0;
        }

        if (fwrite(record.data(), sizeof(uint32_t), 4, output_file) != 4) {
            throw std::runtime_error("cannot save output artifact");
        }

        if (config.verbosity >= 2) {
            printf("[agent] write addr=%08x word=%u\n", destination, writes);
        }
        destination += 16;
        ++writes;
        pending_write = false;
    }

    edge(false);
    ++cycles;

    if (active && source == dut->vertex_buffer_end_o && !pending_write && dut->idle_o) {
        if (reads != (dut->vertex_buffer_end_o - dut->vertex_buffer_base_o) / 16) {
            fail("input_words", 5, reads);
        }

        if (writes % 5) {
            fail("output_stride", 0, writes % 5);
        }

        if (destination != dut->primitive_buffer_end_o) {
            fail("output_words", (dut->primitive_buffer_end_o - dut->primitive_buffer_base_o) / 16,
                 writes);
        }
        active = false;
        dut->done_i = 1;
        dut->eval();
        if (config.verbosity) {
            printf("[agent] complete read_words=%u write_words=%u cycles=%llu\n", reads, writes,
                   (unsigned long long)(cycles - start_cycle));
        }
    }
}

extern "C" void test_log(const char *message) {
    fputs(message, stdout);
    fflush(stdout);
}

extern "C" void test_phase(const char *name, unsigned index) {
    phase = name;
    triangle_index = index;
    if (phase == "coverage_checkpoint") {
        save_coverage();
    }
}

extern "C" void device_reset(unsigned stage) {
    if (stage >= 7) {
        fail("reset_stage", 6, stage);
    }

    uint64_t deadline = cycles + config.timeout;
    while (!(dut->stage_valid_o & (1u << stage))) {
        if (cycles >= deadline) {
            fail("reset_stage_timeout", stage, dut->stage_valid_o);
        }

        tick();
    }

    if (config.verbosity) {
        printf("[wrapper] reset at stage=%s cycle=%llu\n", stages[stage],
               (unsigned long long)cycles);
    }

    active = pending_write = false;
    dut->done_i = 0;
    dut->rst_n_i = 0;
    for (unsigned i = 0; i < 5; ++i) {
        tick();
    }

    dut->rst_n_i = 1;
    tick();
    if (!dut->idle_o) {
        fail("reset_idle", 1, 0);
    }
}

extern "C" void device_write(unsigned reg, uint32_t value) {
    if (reg == CTRL && (value & 2)) {
        if (active) {
            fail("start_while_active", 0, 1);
        }

        source = dut->vertex_buffer_base_o;
        destination = dut->primitive_buffer_base_o;
        if ((source | destination | dut->vertex_buffer_end_o | dut->primitive_buffer_end_o) & 15) {
            fail("buffer_alignment", 0, 1);
        }

        if (source >= dut->vertex_buffer_end_o || dut->vertex_buffer_end_o > GE_GPU_SIZE ||
            destination > dut->primitive_buffer_end_o ||
            dut->primitive_buffer_end_o > GE_GPU_SIZE) {
            fail("buffer_range", GE_GPU_SIZE, dut->primitive_buffer_end_o);
        }

        reads = writes = pending_delay = 0;
        pending_write = false;
        dut->done_i = 0;
        active = true;
        start_cycle = cycles;
    }

    if (config.verbosity >= 2) {
        printf("[MMIO] write offset=%02x value=%08x\n", reg * 4, value);
    }

    dut->register_write_address_i = reg;
    dut->register_write_data_i = value;
    dut->register_write_strobe_i = 15;
    dut->register_write_i = 1;
    dut->eval();
    if (dut->register_write_error_o) {
        fail("mmio_write", 0, reg * 4);
    }

    tick();
    dut->register_write_i = 0;
    tick();
}

extern "C" uint32_t device_read(unsigned reg) {
    dut->register_read_address_i = reg;
    dut->register_read_i = 1;
    dut->eval();
    if (dut->register_read_error_o) {
        fail("mmio_read", 0, reg * 4);
    }

    tick();
    uint32_t value = dut->register_read_data_o;
    dut->register_read_i = 0;
    dut->eval();
    // STATUS polling is deliberately silent, even at debug verbosity.
    if (config.verbosity >= 2 && reg != STATUS) {
        printf("[MMIO] read offset=%02x value=%08x\n", reg * 4, value);
    }

    return value;
}

static void memory_access(uint32_t address, uint8_t *bytes, size_t size, bool write) {
    if (address >= GE_GPU_SIZE || size > GE_GPU_SIZE - address) {
        fail("gpu_address", GE_GPU_SIZE, address + size);
    }

    if (config.verbosity >= 2) {
        printf("[GPU] %s addr=%08x bytes=%zu\n", write ? "write" : "read", address, size);
    }

    while (size) {
        unsigned offset = address % 16;
        unsigned length = std::min<size_t>(16 - offset, size);

        dut->sw_address_i = address;
        dut->sw_strobe_i = 0;
        dut->sw_write_i = write;

        std::fill(&dut->sw_data_i[0], &dut->sw_data_i[4], 0);
        for (unsigned b = 0; b < length; ++b) {
            if (write) {
                dut->sw_data_i[(offset + b) / 4] |= uint32_t(bytes[b]) << (((offset + b) % 4) * 8);
                dut->sw_strobe_i |= 1u << (offset + b);
            }
        }

        dut->eval();
        tick();
        if (!write) {
            for (unsigned b = 0; b < length; ++b) {
                bytes[b] = dut->sw_data_o[(offset + b) / 4] >> (((offset + b) % 4) * 8);
            }
        }

        dut->sw_write_i = 0;
        address += length;
        bytes += length;
        size -= length;
    }
}

extern "C" void gpu_write(uint32_t address, const uint8_t *bytes, size_t size) {
    memory_access(address, const_cast<uint8_t *>(bytes), size, true);
}

extern "C" void gpu_read(uint32_t address, uint8_t *bytes, size_t size) {
    memory_access(address, bytes, size, false);
}

#ifdef WITH_SPIKE
/* This address space belongs to the testbench, not to the SoC MMIO map.
 * GE register offsets are unchanged. Software RAM never advances RTL time. */
class bridge_device : public abstract_device_t {
  public:
    enum class space { registers, gpu, host };

  private:
    space kind;

  public:
    int result = -1;

    explicit bridge_device(space kind) : kind(kind) {}

    reg_t size() override {
        return kind == space::gpu ? GE_GPU_SIZE : 4096;
    }

    bool load(reg_t addr, size_t len, uint8_t *bytes) override {
        if (kind == space::gpu) {
            gpu_read(addr, bytes, len);
            return true;
        }

        if (kind == space::host && addr + len <= sizeof(config)) {
            memcpy(bytes, reinterpret_cast<uint8_t *>(&config) + addr, len);
            return true;
        }

        if (kind != space::registers || len != 4 || addr % 4 || addr >= 256) {
            return false;
        }

        uint32_t value = device_read(addr / 4);
        memcpy(bytes, &value, 4);
        return true;
    }

    bool store(reg_t addr, size_t len, const uint8_t *bytes) override {
        if (kind == space::gpu) {
            gpu_write(addr, bytes, len);
            return true;
        }

        if (kind == space::host) {
            if (addr == 0x110 && len == 4) {
                uint32_t stage;
                memcpy(&stage, bytes, 4);
                device_reset(stage);
                return true;
            }

            if (addr == 0x100 && len == 1) {
                putchar(*bytes);
                return true;
            }

            if (addr == 0x104 && len == 4) {
                uint32_t v;
                memcpy(&v, bytes, 4);
                result = v;
                return true;
            }

            if (addr == 0x108 && len == 4) {
                uint32_t v;
                memcpy(&v, bytes, 4);
                triangle_index = v;
                return true;
            }

            if (addr == 0x10c && len == 1) {
                static std::string next_phase;
                if (*bytes) {
                    next_phase += char(*bytes);
                } else {
                    test_phase(next_phase.c_str(), triangle_index);
                    next_phase.clear();
                }

                return true;
            }

            return false;
        }

        if (len != 4 || addr % 4 || addr >= 256) {
            return false;
        }

        uint32_t value;
        memcpy(&value, bytes, 4);
        device_write(addr / 4, value);
        return true;
    }
};

static int run_spike(const std::string &firmware) {
    cfg_t cfg;
    cfg.isa = "rv64imafdc_zicsr";
    cfg.priv = "m";

    std::unique_ptr<mem_t> ram(new mem_t(16 * 1024 * 1024));
    std::vector<std::pair<reg_t, abstract_mem_t *>> mems = {{0x10000000, ram.get()}};
    std::vector<std::pair<const device_factory_t *, std::vector<std::string>>> factories;
    debug_module_config_t debug_config;
    sim_t spike(&cfg, false, mems, factories, false, {firmware}, debug_config, nullptr, false,
                nullptr, false, nullptr, std::nullopt);

    bridge_device regs(bridge_device::space::registers);
    bridge_device gpu(bridge_device::space::gpu);
    bridge_device host(bridge_device::space::host);

    auto &bus = const_cast<bus_t &>(spike.get_bus());
    bus.add_device(GE_MMIO, &regs);
    bus.add_device(GE_GPU, &gpu);
    bus.add_device(GE_HOST, &host);

    reg_t entry = 0;
    load_elf(firmware.c_str(), &spike.memif(), &entry, 0, 64);
    spike.get_core(0)->get_state()->pc = entry;

    // Step the processor directly: no HTIF run loop and no implicit RTL ticks.
    for (uint64_t instructions = 0; host.result < 0; instructions += 1000) {
        if (instructions >= 1000000000ull) {
            fail("spike_instruction_timeout", 1000000000ull, instructions);
        }
        spike.get_core(0)->step(1000);
        if (spike.get_core(0)->get_state()->pc == 0) {
            auto *state = spike.get_core(0)->get_state();
            fprintf(stderr, "[Spike] trap mcause=%llu mepc=%llx mtval=%llx\n",
                    (unsigned long long)state->mcause->read(),
                    (unsigned long long)state->mepc->read(),
                    (unsigned long long)state->mtval->read());
            fail("spike_trap", 0, state->mcause->read());
        }
    }

    return host.result;
}
#endif

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    std::string waveform;
    std::string firmware;
    const char *mode = "standalone";
    int result = 1;

    try {
        if (argc != 20) {
            throw std::runtime_error(
                "usage: simulator MODE TEST SEED TIMING_SEED CASES VERBOSITY TIMEOUT LATENCY "
                "PAUSE HOLD XY Z UV COLOR W WAVEFORM FIRMWARE OUTPUT COVERAGE");
        }
        mode = argv[1];
        config.test = test_count;
        for (unsigned i = 0; i < test_count; ++i) {
            if (strcmp(argv[2], test_names[i]) == 0) {
                config.test = i;
            }
        }

        if (config.test == test_count) {
            throw std::runtime_error("unknown test name");
        }

        config.seed = std::stoul(argv[3]);
        config.timing_seed = std::stoul(argv[4]);
        config.cases = std::stoul(argv[5]);
        config.verbosity = std::stoul(argv[6]);
        config.timeout = std::stoul(argv[7]);
        config.latency = std::stoul(argv[8]);
        config.pause = std::stoul(argv[9]);
        config.output_hold = std::stoul(argv[10]);
        config.xy_tol = std::stod(argv[11]);
        config.z_tol = std::stod(argv[12]);
        config.uv_tol = std::stod(argv[13]);
        config.color_tol = std::stod(argv[14]);
        config.w_tol = std::stod(argv[15]);

        waveform = argv[16];
        firmware = argv[17];
        coverage_file = argv[19];
#if !VM_COVERAGE
        if (coverage_file != "-") {
            throw std::runtime_error("coverage requested without an instrumented build");
        }
#endif
        output_file = fopen(argv[18], "wb");
        if (!output_file) {
            throw std::runtime_error("cannot open output artifact");
        }

        Verilated::commandArgs(argc, argv);
        Verilated::traceEverOn(waveform != "-");
        dut.reset(new Vtb_top);
        if (waveform != "-") {
            trace.reset(new VerilatedFstC);
            dut->trace(trace.get(), 99);
            trace->open(waveform.c_str());
        }

        printf("[wrapper] test=%s mode=%s seed=%u timing_seed=%u verbosity=%u latency=%u pause=%u "
               "hold=%u waveform=%s\n",
               test_names[config.test], mode, config.seed, config.timing_seed, config.verbosity,
               config.latency, config.pause, config.output_hold, waveform.c_str());

        timing_state = config.timing_seed;
        dut->rst_n_i = 0;
        for (int i = 0; i < 5; ++i) {
            tick();
        }

        dut->rst_n_i = 1;
        tick();
#if VM_COVERAGE
        // Discard initial reset activity; resets exercised by tests still count.
        VerilatedCov::zero();
#endif
        if (strcmp(mode, "standalone") == 0) {
            result = run_test(&config);
        } else if (strcmp(mode, "spike") == 0) {
#ifdef WITH_SPIKE
            result = run_spike(firmware);
#else
            throw std::runtime_error(
                "Spike support not compiled; build with MODE=spike SPIKE_DIR=<prefix>");
#endif
        } else {
            throw std::runtime_error("unknown execution mode");
        }
    } catch (const std::exception &e) {
        fprintf(stderr, "[wrapper] FAIL %s\n", e.what());
    }

    if (!result && config.test == TEST_BACKPRESSURE && (!input_stalls || !output_stalls)) {
        fprintf(stderr, "FAIL phase=coverage test=backpressure missing FIFO stall\n");
        result = 1;
    }

    if (dut) {
        dut->final();
#if VM_COVERAGE
        try {
            save_coverage();
        } catch (const std::exception &error) {
            fprintf(stderr, "[wrapper] FAIL %s\n", error.what());
            result = 1;
        }
#endif
    }

    if (trace) {
        trace->close();
    }

    printf("[wrapper] %s cycles=%llu pauses=%llu", result ? "FAIL" : "PASS",
           (unsigned long long)cycles, (unsigned long long)pause_count);
    for (unsigned s = 0; s < 7; ++s) {
        printf(" %s=%llu", stages[s], (unsigned long long)stage_count[s]);
    }
    printf(" input_stalls=%llu output_stalls=%llu\n", (unsigned long long)input_stalls,
           (unsigned long long)output_stalls);
    if (output_file && fclose(output_file) != 0) {
        fprintf(stderr, "[wrapper] FAIL cannot flush output artifact\n");
        result = 1;
    }

    trace.reset();
    dut.reset();
    return result;
}
