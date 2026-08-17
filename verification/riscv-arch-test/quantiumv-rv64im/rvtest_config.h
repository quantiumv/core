// rvtest_config.h -- QuantiumV DUT capability defines
// SPDX-License-Identifier: Apache-2.0
//
// Deliberately near-empty: QuantiumV implements only RV64IM+Zicsr+U/S/M.
// None of D/Q/F/ZFA/ZFH/ZBB/ZBA/ZBS/ZAAMO/ZALRSC/ZIHPM/ZCA/ZCB/ZCD/SV39/
// SV48/SV57/PMP apply -- leaving each of those undefined is what tells the
// shared test env (tests/env/utils.h and friends) they aren't present.
