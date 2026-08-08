#!/bin/bash
# Thin wrapper forcing -mno-relax onto every riscv64-unknown-elf-gcc invocation
# ACT4 runs during ELF generation. Root cause (empirically confirmed, see
# verification notes): the framework's own compiler_cmd construction
# (framework/src/act/build_plan.py, _compiler_cmd) never passes -mno-relax,
# and test_config.yaml's compiler_exe field has no room for extra flags. Without
# it, our GCC 13.2/Binutils 2.42 toolchain's default linker relaxation corrupts
# the LA() macro's alignment padding in rvmodel_boot (tests/env/utils.h) --
# NOP-fill (0x00000013) becomes zero-fill (illegal c.illegal), which traps and
# infinite-loops in Sail (no mtvec configured yet at that point in boot) the
# instant a test's boot path is ever taken. -mno-relax alone fixes it (verified
# directly: same test, --mno-relax added, rvmodel_boot padding becomes real
# NOPs). This mirrors the project's existing firmware/Makefile precedent of
# always building with -mno-relax for the same class of reason.
exec riscv64-unknown-elf-gcc -mno-relax "$@"
