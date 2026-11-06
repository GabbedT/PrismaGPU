.DEFAULT_GOAL := run
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

# ======================================================================
# PrismaGPU + Spike. Sources and generated output stay in this directory.
# ======================================================================
ROOT := $(abspath ../..)
HERE := $(CURDIR)
VERILATOR ?= verilator
RISCV_CC ?= riscv64-unknown-elf-gcc
SPIKE_INC ?= $(HOME)/riscv-isa-sim
SPIKE_LIB ?= $(SPIKE_INC)/build
JOBS ?= 2
APP ?= features
APPS := features model game benchmark/micro benchmark/fill benchmark/depth benchmark/clip benchmark/textured benchmark/scene benchmark/buffered
BUILD := build
OUT ?= out/$(APP)
FIRMWARE ?= $(BUILD)/app/$(APP).elf

FRAMES ?= $(if $(filter features,$(APP)),0,$(if $(filter model,$(APP)),120,3))
TRIANGLES ?= 1024
SCENE ?= 0
DURATION_MS ?= 10000
SEED ?= 1
TIMING_SEED ?= 2
LATENCY ?= 3
GAP ?= 1
WIDTH ?= 320
VIDEO ?= 0
SCALE ?= 2
AUTOPILOT ?= $(if $(filter 1,$(VIDEO)),0,1)
WAVE ?= 0
TRACE ?= 0
CPU_QUANTUM ?= 64
GPU_HZ ?= 100000000
MAX_CYCLES ?= 1000000000
MAX_INSTRUCTIONS ?= 1000000000

X11_FOUND := $(shell pkg-config --exists x11 2>/dev/null && echo 1)

ifeq ($(X11_FOUND),1)
VIDEO_CFLAGS := -DPGPU_HAVE_X11 $(shell pkg-config --cflags x11)
VIDEO_LIBS := $(shell pkg-config --libs x11)
endif

VFLAGS := --cc --exe --build --assert --trace-fst --timescale 1ns/1ns -j $(JOBS) --top-module prisma_tb_top \
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE
CXXFLAGS_SIM := -std=c++17 -O2 -I$(HERE) -I$(SPIKE_INC) -I$(SPIKE_LIB) $(VIDEO_CFLAGS)

LIBS_SIM := -L$(SPIKE_LIB) -Wl,-rpath,$(SPIKE_LIB) -lriscv -lfesvr -lpthread -ldl -lz $(VIDEO_LIBS)

RTL := $(shell rg --files $(ROOT)/hw -g '*.sv' -g '*.f')

COMMON := app/common/gpu.c app/common/runtime.c app/common/scene.c app/benchmark/workload.c

FWFLAGS := -march=rv64imafdc_zicsr -mabi=lp64d -mcmodel=medany -std=gnu11 -O2 -g \
           -Wall -Wextra -Werror -ffunction-sections -fdata-sections -Iapp/common

.PHONY: build run apps list info test lint video bench clean config
build: $(BUILD)/obj/Vprisma_tb_top $(FIRMWARE)
apps: $(addprefix $(BUILD)/app/,$(addsuffix .elf,$(APPS)))

config:
	@mkdir -p $(BUILD)
	@printf '%s\n' '$(VERILATOR) $(CXXFLAGS_SIM) $(LIBS_SIM)' > $(BUILD)/config.tmp
	@cmp -s $(BUILD)/config.tmp $(BUILD)/config || cp $(BUILD)/config.tmp $(BUILD)/config
$(BUILD)/config: config

$(BUILD)/obj/Vprisma_tb_top: Makefile prisma_tb.f sim_main.cpp framebuffer.cpp framebuffer.h sv/*.sv $(RTL) $(BUILD)/config
	@mkdir -p logs $(BUILD)
	$(VERILATOR) $(VFLAGS) -F prisma_tb.f $(HERE)/sim_main.cpp $(HERE)/framebuffer.cpp \
	    --Mdir $(BUILD)/obj -CFLAGS '$(CXXFLAGS_SIM)' -LDFLAGS '$(LIBS_SIM)' 2>&1 | tee logs/build.log

$(BUILD)/app/%.elf: app/%/main.c $(COMMON) app/common/gpu.h app/common/scene.h app/common/start.S app/common/link.ld Makefile
	@mkdir -p $(@D)
	$(RISCV_CC) $(FWFLAGS) -nostartfiles -Wl,--gc-sections -T app/common/link.ld \
	    app/common/start.S $(COMMON) $< -lm -o $@

run: build
	@mkdir -p $(OUT)
	$(BUILD)/obj/Vprisma_tb_top +firmware=$(FIRMWARE) +out=$(OUT) \
	    +scene=$(SCENE) +duration_ms=$(DURATION_MS) +frames=$(FRAMES) +triangles=$(TRIANGLES) +seed=$(SEED) +timing_seed=$(TIMING_SEED) \
	    +latency=$(LATENCY) +gap=$(GAP) +width=$(WIDTH) +scale=$(SCALE) +autopilot=$(AUTOPILOT) \
	    +cpu_quantum=$(CPU_QUANTUM) +gpu_hz=$(GPU_HZ) +max_cycles=$(MAX_CYCLES) +max_instructions=$(MAX_INSTRUCTIONS) \
	    $(if $(filter 1,$(VIDEO)),+live) $(if $(filter 1,$(WAVE)),+wave) $(if $(filter 1,$(TRACE)),+trace) 2>&1 | tee $(OUT)/console.log

lint:
	$(VERILATOR) --lint-only --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -F prisma_tb.f --top-module prisma_tb_top

test: build apps
	python3 script/check.py

bench: build apps
	python3 script/benchmark.py --triangles $(TRIANGLES) --frames $(if $(filter 0,$(FRAMES)),2,$(FRAMES)) --width $(WIDTH) --seed $(SEED) --timing-seed $(TIMING_SEED)

video:
	python3 script/video.py $(OUT) --fps 30 $(if $(filter features,$(APP)),--scene-ms $(DURATION_MS))

list:
	@printf '%s\n' $(APPS)

info:
	@printf '%s\n' 'APP=$(APP) FIRMWARE=$(FIRMWARE)' 'SPIKE_INC=$(SPIKE_INC)' 'SPIKE_LIB=$(SPIKE_LIB)' \
	    'VIDEO=$(VIDEO) X11=$(X11_FOUND) WIDTH=$(WIDTH)' 'SEED=$(SEED) TIMING_SEED=$(TIMING_SEED)' \
	    'LATENCY=$(LATENCY) GAP=$(GAP) GPU_HZ=$(GPU_HZ) CPU_QUANTUM=$(CPU_QUANTUM)'

clean:
	rm -rf build out logs
