
TOPFILE ?= $(CORE_REPO_PATH)/sim/top.sv
DSFILE ?= $(CORE_REPO_PATH)/design/core.sv
TBFILE ?= $(CORE_REPO_PATH)/testbench/tb.sv

all:
	iverilog \
	-g 2012 \
	-g relative-include \
	-c $(CORE_REPO_PATH)/sim/top.filelist \
	$(TOPFILE);
	./a.out;

core:
	iverilog \
	-g 2012 \
	-g relative-include \
	-c $(CORE_REPO_PATH)/design/core.filelist \
	$(DSFILE);
	./a.out;

tb:
	iverilog \
	-g 2012 \
	-g relative-include \
	-c $(CORE_REPO_PATH)/testbench/tb.filelist \
	$(TBFILE);
	./a.out;

clean:
	rm -rf *.out *.vcd *.log;