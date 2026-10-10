VIVADO ?= vivado
SYNTH_GE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

.PHONY: synth-ge
synth-ge:
	cd "$(SYNTH_GE_DIR)" && "$(VIVADO)" -mode batch -source synth_geometry_engine.tcl
