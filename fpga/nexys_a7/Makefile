.DEFAULT_GOAL := help
VIVADO ?= vivado
FPGA_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BLOCK ?= gpu
PART ?= xc7a100tcsg324-1
PERIOD ?= 10.000
IO_DELAY ?= 2.000
UNCERTAINTY ?= 0.200
MULTIPLIER_STAGES ?= 3
JOBS ?= 2
# Separate configurations, including boundary budgets, never share a project.
RUN := $(FPGA_DIR)/build/$(BLOCK)_$(PART)_p$(PERIOD)_io$(IO_DELAY)_u$(UNCERTAINTY)_m$(MULTIPLIER_STAGES)

.PHONY: help project synth route synth-ge synth-ts check clean
help:
	@echo 'make project | synth | route [BLOCK=gpu|ge|triangle_setup]'
	@echo 'Defaults: Nexys A7-100T, 100 MHz, 2 ns I/O budget, 0.2 ns setup uncertainty'
	@echo 'Options: VIVADO PART PERIOD IO_DELAY UNCERTAINTY MULTIPLIER_STAGES JOBS'
	@echo 'route runs synthesis, placement and routing; no bitstream or ZenithSoC build.'
	@echo 'make clean removes generated evaluation projects and reports (keeps legacy archive).'

project synth route:
	@mkdir -p "$(RUN)"
	cd "$(RUN)" && "$(VIVADO)" -mode batch -source "$(FPGA_DIR)/build.tcl" \
		-tclargs $@ "$(BLOCK)" "$(PART)" "$(PERIOD)" "$(IO_DELAY)" \
		"$(UNCERTAINTY)" "$(MULTIPLIER_STAGES)" "$(JOBS)"

synth-ge:
	$(MAKE) synth BLOCK=ge

synth-ts:
	$(MAKE) synth BLOCK=triangle_setup

check:
	tclsh "$(FPGA_DIR)/checks/source_lists.tcl"

clean:
	@find "$(FPGA_DIR)/build" -mindepth 1 -maxdepth 1 -type d ! -name legacy -exec rm -rf -- {} + 2>/dev/null || test ! -d "$(FPGA_DIR)/build"
