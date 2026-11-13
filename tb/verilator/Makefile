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
          -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT
CXXFLAGS_SIM := -std=c++17 -O2 -I$(HERE) -I$(SPIKE_INC) -I$(SPIKE_LIB) $(VIDEO_CFLAGS)

LIBS_SIM := -L$(SPIKE_LIB) -Wl,-rpath,$(SPIKE_LIB) -lriscv -lfesvr -lpthread -ldl -lz $(VIDEO_LIBS)

RTL := $(shell rg --files $(ROOT)/hw -g '*.sv' -g '*.f')

COMMON := app/common/gpu.c app/common/runtime.c app/common/scene.c app/benchmark/workload.c

FWFLAGS := -march=rv64imafdc_zicsr -mabi=lp64d -mcmodel=medany -std=gnu11 -O2 -g \
           -Wall -Wextra -Werror -ffunction-sections -fdata-sections -Iapp/common

.PHONY: build run apps list info test test-interpolator test-depth test-control \
        test-framebuffer test-raster-buffer test-triangle-buffer test-z-address test-span-address \
        test-math test-registers test-vertex-interpolator test-matrix test-cull test-arbiter test-rasterizer \
        lint video bench clean config
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
	$(VERILATOR) --lint-only --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -F prisma_tb.f --top-module prisma_tb_top

test: build apps
	python3 script/check.py

test-interpolator:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -j $(JOBS) --top-module pixel_interpolator_tb --Mdir $(BUILD)/interpolator \
	    $(ROOT)/hw/pkg/triangle_pkg.sv $(ROOT)/hw/raster_engine/pixel_interpolator/pixel_interpolator.sv \
	    sv/pixel_interpolator_tb.sv
	$(BUILD)/interpolator/Vpixel_interpolator_tb

test-depth:
	@for depth_width in 16 17 24 32; do \
	    $(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	        -j $(JOBS) --top-module depth_tester_tb -GZ_WIDTH=$$depth_width \
	        --Mdir $(BUILD)/depth_tester_$$depth_width \
	        $(ROOT)/hw/raster_engine/z_test/depth_tester.sv sv/depth_tester_tb.sv && \
	    $(BUILD)/depth_tester_$$depth_width/Vdepth_tester_tb || exit $$?; \
	done

test-control:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -Wno-CASEINCOMPLETE -j $(JOBS) --top-module control_validation_tb --Mdir $(BUILD)/control_validation \
	    -F $(ROOT)/hw/_prismaGPU.f sv/control_validation_tb.sv
	$(BUILD)/control_validation/Vcontrol_validation_tb

test-framebuffer:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -j $(JOBS) --top-module framebuffer_access_tb --Mdir $(BUILD)/framebuffer_access \
	    $(ROOT)/hw/pkg/texturizer_pkg.sv $(ROOT)/hw/pkg/re_registers_pkg.sv $(ROOT)/hw/pkg/pixel_blender_pkg.sv \
	    $(ROOT)/hw/raster_engine/memory_unit/framebuffer_access.sv sv/framebuffer_access_tb.sv
	$(BUILD)/framebuffer_access/Vframebuffer_access_tb

test-raster-buffer:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -Wno-CASEINCOMPLETE -j $(JOBS) --top-module raster_triangle_buffer_tb --Mdir $(BUILD)/raster_buffer \
	    -F $(ROOT)/hw/geometry_engine/_geometry_engine.f sv/raster_triangle_buffer_tb.sv
	$(BUILD)/raster_buffer/Vraster_triangle_buffer_tb

test-z-address:
	@for depth_width in 16 32; do \
	    $(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	        -j $(JOBS) --top-module z_buffer_controller_tb -GZ_WIDTH=$$depth_width \
	        --Mdir $(BUILD)/z_address_$$depth_width \
	        $(ROOT)/hw/raster_engine/z_test/z_buffer_controller.sv sv/z_buffer_controller_tb.sv && \
	    $(BUILD)/z_address_$$depth_width/Vz_buffer_controller_tb || exit $$?; \
	done

test-rasterizer:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -j $(JOBS) --top-module pixel_rasterizer_tb --Mdir $(BUILD)/pixel_rasterizer \
	    $(ROOT)/hw/pkg/triangle_pkg.sv $(ROOT)/hw/raster_engine/pixel_rasterizer/pixel_rasterizer.sv \
	    sv/pixel_rasterizer_tb.sv
	$(BUILD)/pixel_rasterizer/Vpixel_rasterizer_tb

test-arbiter:
	@for write_mode in 0 1; do \
	    $(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	        -j $(JOBS) --top-module memory_arbiter_tb -GWRITE=$$write_mode \
	        -GCLIENTS=$$((write_mode == 0 ? 5 : 2)) --Mdir $(BUILD)/memory_arbiter_$$write_mode \
	        $(ROOT)/hw/common/gpu_ddr_interface.sv $(ROOT)/hw/raster_engine/memory_unit/memory_arbiter.sv \
	        sv/memory_arbiter_tb.sv && $(BUILD)/memory_arbiter_$$write_mode/Vmemory_arbiter_tb || exit $$?; \
	done

test-cull:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -j $(JOBS) --top-module cull_engine_tb --Mdir $(BUILD)/cull_engine \
	    $(ROOT)/hw/pkg/triangle_pkg.sv $(ROOT)/hw/pkg/ge_registers_pkg.sv \
	    $(ROOT)/hw/geometry_engine/culling/cull_engine.sv sv/cull_engine_tb.sv
	$(BUILD)/cull_engine/Vcull_engine_tb

test-matrix:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -j $(JOBS) --top-module matrix_engine_tb --Mdir $(BUILD)/matrix_engine \
	    -F $(ROOT)/hw/geometry_engine/_geometry_engine.f sv/matrix_engine_tb.sv
	$(BUILD)/matrix_engine/Vmatrix_engine_tb

test-vertex-interpolator:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -Wno-CASEINCOMPLETE -j $(JOBS) --top-module vertex_interpolator_tb --Mdir $(BUILD)/vertex_interpolator \
	    -F $(ROOT)/hw/geometry_engine/_geometry_engine.f sv/vertex_interpolator_tb.sv
	$(BUILD)/vertex_interpolator/Vvertex_interpolator_tb

test-registers:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT -j $(JOBS) --top-module register_read_tb --Mdir $(BUILD)/register_read \
	    -F $(ROOT)/hw/_prismaGPU.f sv/register_read_tb.sv
	$(BUILD)/register_read/Vregister_read_tb

test-triangle-buffer:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -j $(JOBS) --top-module triangle_buffer_tb --Mdir $(BUILD)/triangle_buffer \
	    $(ROOT)/hw/pkg/triangle_pkg.sv $(ROOT)/hw/geometry_engine/buffer/triangle_buffer.sv \
	    sv/triangle_buffer_tb.sv
	$(BUILD)/triangle_buffer/Vtriangle_buffer_tb

test-math:
	@for multiplier_latency in 0 3; do \
	    $(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	        -Wno-CASEINCOMPLETE -j $(JOBS) --top-module triangle_math_unit_tb \
	        -GMULTIPLIER_LATENCY=$$multiplier_latency $$(test $$multiplier_latency = 0 || echo -D_VIVADO_) \
	        --Mdir $(BUILD)/triangle_math_$$multiplier_latency \
	        -F $(ROOT)/hw/raster_engine/_raster_engine.f sv/triangle_math_unit_tb.sv && \
	    $(BUILD)/triangle_math_$$multiplier_latency/Vtriangle_math_unit_tb || exit $$?; \
	done

test-span-address:
	$(VERILATOR) --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD \
	    -Wno-CASEINCOMPLETE -j $(JOBS) --top-module span_address_tb --Mdir $(BUILD)/span_address \
	    -F $(ROOT)/hw/_prismaGPU.f sv/span_address_tb.sv
	$(BUILD)/span_address/Vspan_address_tb

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
