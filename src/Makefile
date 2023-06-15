

all: soc

soc: soc.sv core.sv i_cache.sv fetch_stage.sv wb_test_master.sv ram.sv
	iverilog soc.sv core.sv i_cache.sv fetch_stage.sv wb_test_master.sv ram.sv -g2012

wb_test: wb_test_master.sv
	iverilog wb_test_master.sv -g2012