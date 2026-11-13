#include "Vprisma_tb_top.h"
#include "Vprisma_tb_top__Dpi.h"
#include "framebuffer.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#include "svdpi.h"
#include "riscv/abstract_device.h"
#include "riscv/cfg.h"
#include "riscv/sim.h"
#include "riscv/processor.h"
#include "fesvr/elfloader.h"

#include <array>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <zlib.h>

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
static constexpr uint64_t RAM_BASE = 0x10000000, GPU_REG = 0x40000000;
static constexpr uint64_t GPU_RAM = 0x50000000, HOST = 0x60000000;
static constexpr unsigned GPU_BYTES = 8*1024*1024, COUNTERS = 46;

struct Options {
    std::string firmware, out = "out/default";
    uint32_t frames = 3, triangles = 32, seed = 1, timing_seed = 2, latency = 3, gap = 1;
    uint32_t scene = 0, duration_ms = 10000;
    uint32_t width = 320, scale = 2, quantum = 64, autopilot = 1;
    uint64_t max_cycles = 1000000000, max_instructions = 1000000000, gpu_hz = 100000000;
    bool live = false, wave = false, trace = false;
};

//====================================================================================
//      RTL CLOCK, FRAME CAPTURE, AND PERFORMANCE REPORTS
//====================================================================================

class Simulation {
public:
    Options options;
    Vprisma_tb_top dut;
    std::unique_ptr<VerilatedFstC> wave;
    Framebuffer video;
    std::ofstream logfile, csv;
    uint64_t cycles = 0, frames = 0, instructions = 0;
    int result = -1;
    uint32_t score = 0, lives = 3, phase = 0;
    uint64_t previous_capture_cycles = 0, previous_capture_instructions = 0;
    bool quit = false;
    double model_fps = 0, host_fps = 0;
    svScope memory_scope = nullptr, perf_scope = nullptr, top_scope = nullptr;
    Clock::time_point started = Clock::now();
    Clock::time_point previous_frame = Clock::now(), last_status = Clock::now();

    explicit Simulation(Options options) : options(std::move(options)), video(this->options.live, this->options.scale) {
        fs::create_directories(this->options.out);
        logfile.open(this->options.out + "/run.log");
        csv.open(this->options.out + "/frames.csv");
        if (!logfile || !csv) throw std::runtime_error("Cannot create output logs");
        dut.latency_i = this->options.latency;
        dut.gap_i = this->options.gap;
        dut.seed_i = this->options.timing_seed;
        dut.clk_i = 0;
        dut.rst_n_i = 0;
        dut.reg_write_i = 0;
        dut.reg_read_i = 0;
        dut.frame_begin_i = 0;
        dut.eval();
        top_scope = svGetScopeFromName("TOP.prisma_tb_top");
        memory_scope = svGetScopeFromName("TOP.prisma_tb_top.memory_model");
        perf_scope = svGetScopeFromName("TOP.prisma_tb_top.counters");
        if (!memory_scope || !perf_scope) throw std::runtime_error("Missing DPI memory/performance scope");
        if (this->options.wave) {
            wave = std::make_unique<VerilatedFstC>();
            dut.trace(wave.get(), 3);
            wave->open((this->options.out + "/gpu.fst").c_str());
        }
        for (int i = 0; i < 4; i++) tick();
        dut.rst_n_i = 1;
        log("[GPU] Spike RV64 + PrismaGPU | " + std::to_string(this->options.gpu_hz) + " Hz model clock");
        log("[GPU] seed=" + std::to_string(this->options.seed) + " timing_seed=" + std::to_string(this->options.timing_seed) +
            " latency=" + std::to_string(this->options.latency) + " gap=" + std::to_string(this->options.gap) +
            " cpu_quantum=" + std::to_string(this->options.quantum));
        log(video.live() ? "[VIDEO] Live X11 display; arrows/WASD, space, Q/Escape" :
                          "[VIDEO] Headless capture: " + this->options.out + "/latest.png");
        csv << "frame,width,height,crc32,model_fps,host_fps,phase,full_cycles,cpu_instructions";
        svSetScope(perf_scope);
        for (unsigned i = 0; i < COUNTERS; i++) csv << ',' << gpu_perf_name(i);
        csv << '\n';
    }
    ~Simulation() { if (wave) wave->close(); dut.final(); }
    void log(const std::string& line) {
        std::cout << line << std::endl;
        logfile << line << '\n'; logfile.flush();
    }
    void edge(bool high) {
        dut.clk_i = high; dut.eval();
        if (wave) wave->dump(Verilated::time());
        Verilated::timeInc(5);
    }
    void tick() {
        dut.eval(); edge(true); edge(false); ++cycles;
        if (dut.rst_n_i && dut.frame_complete_o) capture();
        if (options.max_cycles && cycles > options.max_cycles) throw std::runtime_error("GPU cycle limit reached");
        if (Verilated::gotFinish()) throw std::runtime_error("Unexpected RTL finish");
        if ((cycles & 4095) == 0) {
            quit = !video.poll();
            const auto now = Clock::now();
            if (std::chrono::duration<double>(now-last_status).count() >= 1.0) {
                std::ostringstream line;
                line << "[LIVE] frames=" << frames << " cycles=" << cycles << " busy=" << unsigned(dut.busy_o)
                     << " model_FPS=" << model_fps << " host_FPS=" << host_fps;
                log(line.str());
                svSetScope(top_scope); log(std::string("[STATE] ") + gpu_debug_state());
                last_status = now;
            }
        }
    }
    uint32_t memory_read(uint32_t address) {
        svSetScope(memory_scope); return gpu_mem_read(address);
    }
    void memory_write(uint32_t address, uint32_t data, uint32_t strobe) {
        svSetScope(memory_scope); gpu_mem_write(address, data, strobe);
    }
    std::array<uint64_t, COUNTERS> counters(bool snapshot) {
        std::array<uint64_t, COUNTERS> values{};
        svSetScope(perf_scope);
        for (unsigned i = 0; i < COUNTERS; i++) values[i] = gpu_perf_read(i, snapshot);
        return values;
    }
    void capture() {
        const unsigned width = dut.viewport_small_o ? 320 : 640, height = width*3/4;
        const uint32_t base = dut.framebuffer_base_o;
        const unsigned bytes = width*height*3/2;
        if (base > GPU_BYTES-bytes) throw std::runtime_error("Framebuffer outside GPU RAM");
        std::vector<uint8_t> packed(bytes), rgb(width*height*3);
        for (unsigned i = 0; i < bytes; i += 4) {
            const uint32_t word = memory_read(base+i);
            for (unsigned b = 0; b < 4 && i+b < bytes; b++) packed[i+b] = uint8_t(word >> (8*b));
        }
        for (unsigned p = 0; p < width*height; p++) {
            const unsigned byte = p*3/2, shift = (p & 1)*4;
            const uint32_t pixel = (uint32_t(packed[byte]) | (uint32_t(packed[byte+1]) << 8)) >> shift;
            rgb[3*p] = ((pixel >> 8) & 15)*17;
            rgb[3*p+1] = ((pixel >> 4) & 15)*17;
            rgb[3*p+2] = (pixel & 15)*17;
        }
        ++frames;
        const auto stats = counters(true);
        const auto now = Clock::now();
        model_fps = stats[0] ? double(options.gpu_hz)/stats[0] : 0;
        host_fps = 1.0/std::chrono::duration<double>(now-previous_frame).count();
        previous_frame = now;
        const uint32_t hash = crc32(0, rgb.data(), rgb.size());
        std::ostringstream path;
        path << options.out << "/frame_" << std::setfill('0') << std::setw(6) << frames << ".png";
        Framebuffer::save_png(path.str(), rgb, width, height);
        Framebuffer::save_png(options.out + "/latest.png", rgb, width, height);
        std::ostringstream title;
        title << "PrismaGPU | frame " << frames << " | model " << std::fixed << std::setprecision(2)
              << model_fps << " FPS | host " << host_fps << " FPS | score " << score << " lives " << lives;
        video.present(rgb, width, height, title.str());
        std::ostringstream line;
        line << "[FRAME] " << title.str() << " | cycles=" << stats[0] << " triangles=" << stats[14]
             << " full_model_FPS=" << (cycles>previous_capture_cycles?double(options.gpu_hz)/(cycles-previous_capture_cycles):0)
             << " phase=" << phase << " pixels=" << stats[17] << " z_reject=" << stats[18] << " crc32=" << std::hex << hash;
        log(line.str());
        csv << frames << ',' << width << ',' << height << ',' << hash << ',' << model_fps << ',' << host_fps;
        csv << ',' << phase << ',' << cycles-previous_capture_cycles << ',' << instructions-previous_capture_instructions;
        previous_capture_cycles=cycles; previous_capture_instructions=instructions;
        for (auto value : stats) csv << ',' << value;
        csv << '\n'; csv.flush();
    }
    void report() {
        const auto stats = counters(false);
        std::ofstream json(options.out + "/summary.json");
        json << "{\n  \"frames\": " << frames << ",\n  \"instructions\": " << instructions
             << ",\n  \"result\": " << result << ",\n  \"closed_by_user\": " << (quit ? "true" : "false")
             << ",\n  \"seed\": " << options.seed << ",\n  \"timing_seed\": " << options.timing_seed
             << ",\n  \"gpu_hz\": " << options.gpu_hz << ",\n  \"latency\": " << options.latency
             << ",\n  \"gap\": " << options.gap << ",\n  \"cpu_quantum\": " << options.quantum
             << ",\n  \"wall_seconds\": " << std::chrono::duration<double>(Clock::now()-started).count()
             << ",\n  \"counters\": {\n";
        log("================ PRISMAGPU PERFORMANCE ================");
        svSetScope(perf_scope);
        for (unsigned i = 0; i < COUNTERS; i++) {
            const std::string name = gpu_perf_name(i);
            log("[PERF] " + name + "=" + std::to_string(stats[i]));
            json << "    \"" << name << "\": " << stats[i] << (i+1 == COUNTERS ? "\n" : ",\n");
        }
        json << "  }\n}\n";
        unsigned worst = 19;
        for (unsigned i : {20u,21u,24u,27u,28u,29u,30u}) if (stats[i] > stats[worst]) worst = i;
        log("[PERF] largest_wait=" + std::string(gpu_perf_name(worst)) + " (overlapping categories)");
        log("[RESULT] " + std::string(quit ? "window closed" : result == 0 ? "PASS" : "FAIL") +
            " frames=" + std::to_string(frames) + " artifacts=" + options.out);
    }
};

//====================================================================================
//      SPIKE MMIO DEVICES
//====================================================================================

class Bridge : public abstract_device_t {
    Simulation& sim;
    unsigned kind;
    std::string console_line;
public:
    Bridge(Simulation& sim, unsigned kind) : sim(sim), kind(kind) {}
    reg_t size() override { return kind == 1 ? GPU_BYTES : 4096; }
    bool load(reg_t address, size_t length, uint8_t* bytes) override {
        uint64_t value = 0;
        if (length == 0 || length > 8 || address > size()-length) return false;
        if (kind == 1) {
            for (unsigned b = 0; b < length;) {
                const uint32_t word = sim.memory_read((address+b) & ~3u);
                do {
                    bytes[b] = word >> (8*((address+b)&3));
                    ++b;
                } while (b < length && ((address+b)&3));
            }
            sim.tick(); return true;
        }
        if (kind == 0) {
            if (length != 4 || address % 4 || address >= 512) return false;
            sim.dut.reg_read_i = 1;
            sim.dut.reg_read_address_i = address/4;
            sim.tick();
            sim.dut.reg_read_i = 0;
            const bool error = sim.dut.reg_read_error_o;
            value = sim.dut.reg_read_data_o;
            if (sim.options.trace) {
                std::ostringstream line;
                line << "[MMIO] cycle=" << sim.cycles << " read +0x" << std::hex << address << " =0x" << value;
                sim.log(line.str());
            }
            if (error) throw std::runtime_error("GPU register read rejected at " + std::to_string(address));
        } else {
            if (address % length) return false;
            switch (address) {
                case 0: value = sim.options.frames; break;
                case 4: value = sim.options.triangles; break;
                case 8: value = sim.options.seed; break;
                case 12: value = sim.options.autopilot; break;
                case 16: value = sim.options.width; break;
                case 0x18: value = sim.options.scene; break;
                case 0x1c: value = sim.options.duration_ms; break;
                case 0x128: value = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now()-sim.started).count(); break;
                case 0x10c: value = sim.frames; break;
                case 0x110: sim.quit = !sim.video.poll(); value = sim.video.keys(); break;
                case 0x118: value = sim.cycles; break;
                default:
                    if (address >= 0x200 && address < 0x200+8*COUNTERS && length == 8 && address%8 == 0) {
                        svSetScope(sim.perf_scope); value = gpu_perf_read((address-0x200)/8, true);
                    } else return false;
            }
            sim.tick();
        }
        for (unsigned b = 0; b < length; b++) bytes[b] = uint8_t(value >> (8*b));
        return true;
    }
    bool store(reg_t address, size_t length, const uint8_t* bytes) override {
        if (length == 0 || length > 8 || address > size()-length) return false;
        uint64_t value = 0;
        for (unsigned b = 0; b < length; b++) value |= uint64_t(bytes[b]) << (8*b);
        if (kind == 1) {
            /* Coalesce host byte lanes into DPI words. A CPU access still costs
             * exactly one GPU clock, independent of the number of byte lanes. */
            for (unsigned b = 0; b < length;) {
                const uint32_t word_address = (address+b)&~3u;
                uint32_t data = 0, strobe = 0;
                do {
                    const unsigned lane = (address+b)&3;
                    data |= uint32_t(bytes[b]) << (8*lane);
                    strobe |= 1u << lane;
                    ++b;
                } while (b < length && ((address+b)&3));
                sim.memory_write(word_address, data, strobe);
            }
            sim.tick(); return true;
        }
        if (kind == 0) {
            if (length != 4 || address%4 || address >= 512) return false;
            sim.dut.reg_write_i = 1;
            sim.dut.reg_write_address_i = address/4;
            sim.dut.reg_write_data_i = value;
            sim.dut.reg_write_strobe_i = 15;
            sim.tick();
            sim.dut.reg_write_i = 0;
            const bool error = sim.dut.reg_write_error_o;
            if (sim.options.trace) {
                std::ostringstream line;
                line << "[MMIO] cycle=" << sim.cycles << " write +0x" << std::hex << address << " =0x" << value;
                sim.log(line.str());
            }
            if (error) throw std::runtime_error("GPU register write rejected at " + std::to_string(address));
            return true;
        }
        if (address == 0x100 && length == 1) {
            if (*bytes == '\n') { sim.log("[APP] " + console_line); console_line.clear(); }
            else console_line += char(*bytes);
        } else if (address == 0x104 && length == 4) {
            sim.result = int32_t(value);
        } else if (address == 0x108 && length == 4) {
            sim.dut.frame_begin_i = 1; sim.tick(); sim.dut.frame_begin_i = 0; return true;
        } else if (address == 0x120 && length == 4) sim.score = value;
        else if (address == 0x124 && length == 4) sim.lives = value;
        else if (address == 0x130 && length == 4) sim.phase = value;
        else if (address == 0x128 && length == 8) {
            const auto target=sim.started+std::chrono::milliseconds(value);
            while (Clock::now()<target && !sim.quit) {
                sim.quit=!sim.video.poll();
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        }
        else return false;
        sim.tick(); return true;
    }
};

static void run_spike(Simulation& sim) {
    cfg_t cfg;
    cfg.isa = "rv64imafdc_zicsr";
    cfg.priv = "m";
    auto ram = std::make_unique<mem_t>(16*1024*1024);
    std::vector<std::pair<reg_t, abstract_mem_t*>> mems = {{RAM_BASE, ram.get()}};
    std::vector<std::pair<const device_factory_t*, std::vector<std::string>>> factories;
    debug_module_config_t debug_config{};
    sim_t spike(&cfg, false, mems, factories, false, {sim.options.firmware}, debug_config,
                nullptr, false, nullptr, false, nullptr, std::nullopt);
    Bridge regs(sim, 0), gpu(sim, 1), host(sim, 2);
    auto& bus = const_cast<bus_t&>(spike.get_bus());
    bus.add_device(GPU_REG, &regs); bus.add_device(GPU_RAM, &gpu); bus.add_device(HOST, &host);
    reg_t entry = 0;
    load_elf(sim.options.firmware.c_str(), &spike.memif(), &entry, 0, 64);
    spike.get_core(0)->get_state()->pc = entry;
    while (sim.result < 0 && !sim.quit) {
        if (sim.options.max_instructions && sim.instructions >= sim.options.max_instructions) throw std::runtime_error("Spike instruction limit reached");
        spike.get_core(0)->step(sim.options.quantum);
        sim.instructions += sim.options.quantum;
        auto* state = spike.get_core(0)->get_state();
        if (state->pc == 0) {
            std::ostringstream fault;
            fault << "Spike trap: mcause=" << state->mcause->read() << " mepc=0x" << std::hex
                  << state->mepc->read() << " mtval=0x" << state->mtval->read();
            throw std::runtime_error(fault.str());
        }
        sim.tick();
    }
}

int main(int argc, char** argv) {
    std::unique_ptr<Simulation> sim;
    try {
        Options o;
        for (int i = 1; i < argc; i++) {
            const std::string arg = argv[i];
            const auto equal = arg.find('=');
            const std::string key = arg.substr(0, equal), value = equal == std::string::npos ? "" : arg.substr(equal+1);
            if (key == "+live") o.live = true;
            else if (key == "+wave") o.wave = true;
            else if (key == "+trace") o.trace = true;
            else if (key == "+firmware") o.firmware = value;
            else if (key == "+out") o.out = value;
            else if (key == "+frames") o.frames = std::stoul(value);
            else if (key == "+triangles") o.triangles = std::stoul(value);
            else if (key == "+seed") o.seed = std::stoul(value);
            else if (key == "+timing_seed") o.timing_seed = std::stoul(value);
            else if (key == "+latency") o.latency = std::stoul(value);
            else if (key == "+gap") o.gap = std::stoul(value);
            else if (key == "+scene") o.scene = std::stoul(value);
            else if (key == "+duration_ms") o.duration_ms = std::stoul(value);
            else if (key == "+width") o.width = std::stoul(value);
            else if (key == "+scale") o.scale = std::stoul(value);
            else if (key == "+cpu_quantum") o.quantum = std::stoul(value);
            else if (key == "+autopilot") o.autopilot = std::stoul(value);
            else if (key == "+max_cycles") o.max_cycles = std::stoull(value);
            else if (key == "+max_instructions") o.max_instructions = std::stoull(value);
            else if (key == "+gpu_hz") o.gpu_hz = std::stoull(value);
            else throw std::runtime_error("Unknown option: " + arg);
        }
        if (o.firmware.empty() || !fs::exists(o.firmware)) throw std::runtime_error("Pass +firmware=app.elf");
        if ((o.width != 320 && o.width != 640) || !o.quantum || o.quantum > 10000 || !o.gpu_hz ||
            o.scene > 5 || !o.duration_ms || o.duration_ms > 600000 || o.triangles > 4096 || o.latency > 100000 || o.gap > 100000)
            throw std::runtime_error("Invalid viewport, quantum, triangle count, or memory timing");
        Verilated::commandArgs(argc, argv);
        Verilated::traceEverOn(o.wave);
        sim = std::make_unique<Simulation>(o);
        run_spike(*sim);
        sim->report();
        return sim->quit || sim->result == 0 ? 0 : 1;
    } catch (const std::exception& error) {
        if (sim) { sim->result = 1; sim->log(std::string("[ERROR] ") + error.what()); sim->report(); }
        else std::cerr << "[ERROR] " << error.what() << '\n';
        return 1;
    }
}
