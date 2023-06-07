# QuantiumV
RISCV SoC Collab work.


# General SoC Architecture idea
                    +-------+
                    |  CPI  |
            +-------+-------+
            |      CPU      |
            +-------+-------+
            |  L1D  |  L1I  |
            +-------+-------+
                /\     /\
                ||     ||
                \/     \/
    +------------------------------------------------------------------+
    |                           MATRIX INTERCONNECT                    |
    +------------------------------------------------------------------+
                /\                     /\                     /\
                ||                     ||                     ||
                \/                     \/                     \/
            +---------+            +---------+            +---------+
            |  Cache  |            |  Device |            |  Cache  |
            +---------+            +---------+            +---------+
                /\
                ||
                \/
      +----------------------+
      |  Memory Controlller  |
      +----------------------+
                /\
                ||
                \/
            +---------+
            |   RAM   |
            +---------+
            

# CPI - CoProcessor Interface
Basic idea of the coprocessor interface. This can later of extended.
This will allow custom instructions to be executed and registers passed to the coprocessor.

The ready and ack signals are a handshake in order to stall the processor's pipeline.
Signals
```verilog
wire rdy
wire ack
wire clk
wire [31:0] rd;
wire [31:0] rs1;
wire [31:0] rs2;
```

# Processor Components
 - [ ] MMU
 - [ ] MPU
 - [ ] M Mode CSRs
 - [ ] S Mode CSRs
 - [ ] U Mode CSRs
 - [ ] Memory Access Unit for instructions stream.
 - [ ] Memory Access Unit for datga stream.
 - [ ] Pipeline design.
 - [ ] D Cache
 - [ ] I Cache
 - [ ] WB4 to AXI Bridge
 - [ ] AXI to WB4 Bridge

# Coding Style
All extra components that are not part of the main SoC should have their own directory under src/
Core components should be a file per module.

# Tools and Software
These are some open source alternatives to Quartus and Vivado. 
iverilog
iverilator
gtkwave
