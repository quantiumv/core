

all: soc

soc: soc.sv core.sv i_cache.sv fetch_stage.sv 
	iverilog soc.sv core.sv i_cache.sv fetch_stage.sv  -g2012
