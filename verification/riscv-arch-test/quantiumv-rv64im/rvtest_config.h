// rvtest_config.h -- QuantiumV DUT capability defines
// SPDX-License-Identifier: Apache-2.0
//
// This config declares RV64IM+Zca+Zicsr+U/S/M, PMP (4 entries, G=0) and Sv39. The FP, Zb*,
// Zaamo/Zalrsc, Zihpm, Zcb/Zcd and Sv48/Sv57 defines stay undefined, which is what tells the
// shared test env (tests/env/utils.h and friends) they aren't present here.
#define RVMODEL_PMP_GRAIN 0
#define RVMODEL_NUM_PMPS 16 // the PMP CSRs present (always 16 for 1-16 entries); 4 are usable, the rest read 0
#define SV39_SUPPORTED
#define S_SUPPORTED          // ZicntrU then opens scounteren, so U's enabled reads run too
#define TIME_CSR_IMPLEMENTED 1 // Zicntr: Zicntr-csrrs/csrrc wait for time to move (#if, so a value)
