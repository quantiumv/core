// rvtest_config.h -- QuantiumV DUT capability defines for the F/D config
// SPDX-License-Identifier: Apache-2.0
//
// F_SUPPORTED and D_SUPPORTED make the test env enable mstatus.FS and use fsd for FP
// signatures (tests/env/rvtest_setup.h, utils.h). The rest are listed for completeness; the
// env does not read them. Zca stays undefined as in quantiumv-rv64im, whose tests pass that way.
#define F_SUPPORTED
#define D_SUPPORTED
#define ZCD_SUPPORTED
#define ZAAMO_SUPPORTED
#define ZALRSC_SUPPORTED
