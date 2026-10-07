.DEFAULT_GOAL := test

ROOT := $(abspath ../../..)
HERE := $(CURDIR)

# Test selection and execution limits.
MODE ?= standalone
TEST ?= identity
SEED ?= 1
TIMING_SEED ?= 2
CASES ?= 100
VERBOSE ?= 1
TIMEOUT ?= 200000
WALL_TIMEOUT ?= 300

# Memory-agent timing.
LATENCY ?= 3
PAUSE ?= 25
OUTPUT_HOLD ?= 0

# Absolute tolerances in decoded field units.
XY_TOL ?= 0.25
Z_TOL ?= 0.001
UV_TOL ?= 0.001
COLOR_TOL ?= 3
W_TOL ?= 0.001

WAVE ?= 0
OUT ?= out
JOBS ?= 2

# Build tools and Spike installation.
VERILATOR ?= verilator
RISCV_CC ?= riscv64-unknown-elf-gcc
SPIKE_DIR ?= /usr/local

# Installed Spike prefix, or source tree with a build directory.
SPIKE_INCLUDE ?= $(SPIKE_DIR)/include
SPIKE_LIB ?= $(SPIKE_DIR)/lib

export MODE TEST SEED TIMING_SEED CASES VERBOSE TIMEOUT WALL_TIMEOUT LATENCY PAUSE OUTPUT_HOLD
export XY_TOL Z_TOL UV_TOL COLOR_TOL W_TOL WAVE OUT SPIKE_DIR SPIKE_INCLUDE SPIKE_LIB
export RISCV_CC VERILATOR

BUILD := build/$(MODE)
SW := sw/test.c sw/golden_model.c sw/triangle_gen.c
OBJECTS := $(addprefix $(BUILD)/,$(notdir $(SW:.c=.o)))

SPIKE_FLAGS :=
SPIKE_LINK :=

ifeq ($(MODE),spike)
SPIKE_FLAGS := -DWITH_SPIKE -I$(SPIKE_INCLUDE) -I$(SPIKE_DIR)/build
SPIKE_LINK := -L$(SPIKE_LIB) -Wl,-rpath,$(SPIKE_LIB) -lriscv -lfesvr -lpthread -ldl
FIRMWARE := $(BUILD)/firmware.elf
else ifneq ($(MODE),standalone)
$(error MODE must be standalone or spike)
endif

.PHONY: test regression standalone spike waveform list build clean config

# The runner builds once, then continues through failures and returns nonzero.
test regression list:
	@python3 run.py $@

standalone:
	@$(MAKE) test MODE=standalone

spike:
	@$(MAKE) test MODE=spike

waveform:
	@$(MAKE) test WAVE=1

build: $(BUILD)/obj/Vtb_top $(FIRMWARE)

$(BUILD)/%.o: sw/%.c sw/ge_test.h
	@mkdir -p $(BUILD)
	$(CC) -std=c11 -O2 -Wall -Wextra -Werror -Isw -c $< -o $@

# Record tool settings so changing a Spike prefix invalidates the executable.
config:
	@mkdir -p $(BUILD)
	@printf '%s\n' '$(VERILATOR) $(SPIKE_FLAGS) $(SPIKE_LINK)' > $(BUILD)/config.tmp
	@cmp -s $(BUILD)/config.tmp $(BUILD)/config || cp $(BUILD)/config.tmp $(BUILD)/config

$(BUILD)/config: config

RTL := $(shell find $(ROOT)/hw -name '*.sv' -o -name '*.f')

$(BUILD)/obj/Vtb_top: Makefile testbench.cpp sv/tb_top.sv sv/memory.sv \
                    sw/ge_test.h $(OBJECTS) $(RTL) $(BUILD)/config
	@# Verilator's link rule does not track the external C objects.
	rm -f $@
	$(VERILATOR) --cc --exe --build -j $(JOBS) --assert --trace-fst --top-module tb_top -Wno-fatal \
	    -F $(ROOT)/hw/_prismaGPU.f sv/memory.sv sv/tb_top.sv $(HERE)/testbench.cpp $(addprefix $(HERE)/,$(OBJECTS)) \
	    --Mdir $(BUILD)/obj -CFLAGS '-std=c++17 -O2 -I$(HERE) $(SPIKE_FLAGS)' \
	    -LDFLAGS '-lm $(SPIKE_LINK)'

$(BUILD)/firmware.elf: Makefile $(SW) sw/firmware.c sw/start.S sw/link.ld sw/ge_test.h
	@mkdir -p $(BUILD)
	$(RISCV_CC) -march=rv64imafdc_zicsr -mabi=lp64d -mcmodel=medany -std=gnu11 -O2 -Wall -Wextra \
	    -nostartfiles -T sw/link.ld sw/start.S $(SW) sw/firmware.c -lm -o $@

clean:
	rm -rf build out
