


#############

DESIGN = ../design
TESTBENCH = ../testbench
RTL_FILES = $(DESIGN)/wb4_sram.sv $(DESIGN)/core.sv

SOC_TEST_BENCH = $(RTL_FILES) $(TESTBENCH)/tb.sv

all: $(SOC_TEST_BENCH)
	iverilog $(SOC_TEST_BENCH) -g2012

clean:
	rm -rf *.out *.vcd *.log;