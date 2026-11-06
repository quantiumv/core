// SPDX-License-Identifier: MIT
//
// Milestone 10b (EBREAK/JTAG staged plan, full-stack OpenOCD integration):
// a Verilator C++ top-level exposing verification/openocd/sim_soc_top.sv
// (a thin wrapper around the real, unmodified design/soc.sv) as an
// OpenOCD `remote_bitbang` TCP server. This is the first hand-written
// Verilator --cc --exe harness in this project (verification/taxi/ is
// 100% --binary mode); a minimal precursor of this file (2000 half-cycles,
// no server logic) was used to smoke-test the Verilator build itself
// before this real protocol implementation was written, per the plan's
// own risk-mitigation ordering.
//
// Protocol (OpenOCD 0.12.0 docs, version-matched to the installed
// toolchain): OpenOCD connects as a TCP client and sends single ASCII
// bytes -- 'B'/'b' blink (no-op here), 'R' read (respond '0'/'1' = tdo),
// 'Q' quit, '0'-'7' write {tck,tms,tdi} as a 3-bit pattern (bit2=tck,
// bit1=tms, bit0=tdi), 'r'/'s'/'t'/'u' reset {trst,srst} as a 2-bit
// pattern (bit1=trst, bit0=srst). `clk` (this design's own system clock,
// wholly independent of TCK) free-runs at a fixed rate interleaved with
// every TCK-domain event -- this design's CDC bridge (design/dm_dmi.sv)
// is already proven robust to any relative TCK/clk rate (see
// testbench/jtag_dmi_e2e_tb.sv's own header), so there is no specific
// ratio to get right, only "enough clk edges happen between TCK events
// for forward progress," which a generous fixed tick count guarantees.

#include "Vsim_soc_top.h"
#include "verilated.h"

#include <arpa/inet.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

static VerilatedContext* contextp;
static Vsim_soc_top* top;

// Ticks of `clk` (half-cycles) interleaved with each single TCK-domain
// event below. Generous, not tuned for speed -- this is a bounded,
// one-shot smoke test, not a performance benchmark.
static const int CLK_TICKS_PER_EVENT = 10;

// Every eval() is preceded by a real contextp->timeInc(1) -- load-
// bearing, not decoration: this build uses --timing (needed for
// verification/openocd/sim_soc_top.sv's own `#1` firmware-override
// delay, the same convention every *_toolchain_tb.sv in this project
// already relies on). Without an explicit, monotonically advancing
// simulation time, that `#1`-delayed initial block's coroutine never
// resumes at all -- discovered empirically: an earlier version of this
// harness (bare Verilated::commandArgs() + eval()-in-a-loop, no
// timeInc()) silently left the override permanently pending, so
// design/wb4_sram.sv's own unconditional firmware/crt0.hex load was
// the ONLY image that ever actually ran, no matter what hex file this
// harness intended to substitute -- confirmed by tracing core0.pc
// directly and recognizing hello.c's own real character-output loop,
// not the intended debug-test program's address range.
static void tick_clk(int half_cycles) {
    for (int i = 0; i < half_cycles; i++) {
        contextp->timeInc(1);
        top->clk = !top->clk;
        top->eval();
    }
}

int main(int argc, char** argv) {
    contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    top = new Vsim_soc_top{contextp};

    int port = 9824;
    if (argc > 1) port = atoi(argv[1]);

    top->rst = 1;
    top->jtag_tck = 0;
    top->jtag_tms = 1;
    top->jtag_tdi = 0;
    top->jtag_trst_n = 0;
    top->clk = 0;

    // Bring the design out of its own system reset before OpenOCD ever
    // connects -- design/soc.sv's `rst` has no JTAG-side control at all
    // (only jtag_trst_n does, via the 'r'/'s'/'t'/'u' commands below),
    // mirroring a real board whose reset button is already released
    // before a debugger attaches.
    tick_clk(40);
    top->rst = 0;
    tick_clk(10);
    top->jtag_trst_n = 1;
    tick_clk(10);

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        perror("socket");
        return 1;
    }
    int one = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (bind(listen_fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }
    if (listen(listen_fd, 1) < 0) {
        perror("listen");
        return 1;
    }

    // Orchestration-script sentinel: printed exactly once, right before
    // the blocking accept() below, so run_m10_smoke_test.sh can poll for
    // this line instead of racing OpenOCD's own connection attempt
    // against this process's own startup time.
    printf("REMOTE_BITBANG_LISTENING port=%d\n", port);
    fflush(stdout);

    int conn_fd = accept(listen_fd, nullptr, nullptr);
    if (conn_fd < 0) {
        perror("accept");
        return 1;
    }
    // Load-bearing, not an optimization: Nagle+delayed-ACK interaction
    // with OpenOCD's own small, frequent single-byte writes is a
    // well-known 20x+ slowdown for exactly this kind of bit-bang bridge
    // if left at the OS default.
    setsockopt(conn_fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    bool quit = false;
    while (!quit) {
        char cmd;
        ssize_t n = read(conn_fd, &cmd, 1);
        if (n <= 0) break;  // peer closed the connection

        switch (cmd) {
            case 'B':
            case 'b':
                break;  // blink -- no physical LED to drive, no-op
            case 'R': {
                char resp = top->jtag_tdo ? '1' : '0';
                if (write(conn_fd, &resp, 1) != 1) quit = true;
                break;
            }
            case 'Q':
                quit = true;
                break;
            case '0': case '1': case '2': case '3':
            case '4': case '5': case '6': case '7': {
                int bits = cmd - '0';
                top->jtag_tck = (bits >> 2) & 1;
                top->jtag_tms = (bits >> 1) & 1;
                top->jtag_tdi = bits & 1;
                tick_clk(CLK_TICKS_PER_EVENT);
                break;
            }
            case 'r': case 's': case 't': case 'u': {
                int bits = cmd - 'r';
                bool trst = (bits >> 1) & 1;
                // srst (bit 0) has no wired system-reset pin on this
                // core's JTAG interface -- accepted, not functionally
                // honored. jtag_trst_n is active-LOW (this core's own
                // convention, matching every existing testbench), so
                // OpenOCD's trst=1 (asserted) drives it to 0.
                top->jtag_trst_n = trst ? 0 : 1;
                tick_clk(CLK_TICKS_PER_EVENT);
                break;
            }
            default:
                break;
        }
    }

    close(conn_fd);
    close(listen_fd);
    delete top;
    return 0;
}
