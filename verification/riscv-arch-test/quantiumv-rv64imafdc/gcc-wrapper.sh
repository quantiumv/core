#!/bin/bash
# gcc-wrapper.sh -- the F/D config's compiler for ACT4 ELF generation.
#
# 1. -mno-relax on every call, as quantiumv-rv64im/gcc-norelax-wrapper.sh explains.
# 2. GCC 13.2 / binutils 2.42 do not know the zaamo and zalrsc names that the Zaamo and Zalrsc tests ask for in their
#    -march (e.g. rv64i_zicsr_zaamo); GCC 14 does. They are the two halves of A, so they become the `a` letter:
#    rv64i_zicsr_zaamo -> rv64ia_zicsr. Every other -march passes through unchanged.
args=()
for a in "$@"; do
    if [[ "$a" == -march=* ]] && [[ "$a" =~ _za(amo|lrsc) ]]; then
        m=${a#-march=}
        m=${m//_zaamo/}
        m=${m//_zalrsc/}
        base=${m%%_*}                  # rv64i, rv64im, ...
        rest=${m#"$base"}
        if [[ "$base" != *a* ]]; then
            if [[ "$base" == *m* ]]; then base=${base/m/ma}; else base=${base/i/ia}; fi
        fi
        a="-march=${base}${rest}"
    fi
    args+=("$a")
done
exec riscv64-unknown-elf-gcc -mno-relax "${args[@]}"
