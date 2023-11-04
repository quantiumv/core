

all: soc

soc: soc.sv core.sv i_cache.sv fetch_stage.sv wb_test_master.sv ram.sv
	iverilog soc.sv core.sv i_cache.sv fetch_stage.sv wb_test_master.sv ram.sv -g2012

fetch_stage_tb: fetch_stage.sv fetch_stage_tb.sv ram.sv i_cache.sv
	iverilog fetch_stage.sv fetch_stage_tb.sv ram.sv i_cache.sv -g2012

wb_test: wb_test_master.sv
	iverilog wb_test_master.sv -g2012