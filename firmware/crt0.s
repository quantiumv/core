    .section .text
    .globl _start

_start:
    addi x1, x0, 5      # x1 = 5
    addi x2, x0, 3      # x2 = 3
    add  x3, x1, x2     # x3 = 8
    sd   x3, 0(x0)      # mem[0] = 8
    li   x4, 4          # x4 = 4
loop:
    addi x4, x4, -1     # x4--
    bnez x4, loop       # branch until x4 == 0
    ebreak              # done