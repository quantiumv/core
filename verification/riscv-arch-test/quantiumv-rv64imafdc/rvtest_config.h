// rvtest_config.h -- QuantiumV DUT capability defines for the F/D config
// SPDX-License-Identifier: Apache-2.0
//
// F_SUPPORTED and D_SUPPORTED make the test env enable mstatus.FS and use fsd for FP
// signatures (tests/env/rvtest_setup.h, utils.h). The rest are listed for completeness; the
// env does not read them. Zca stays undefined as in quantiumv-rv64im, whose tests pass that way.
#define RVMODEL_PMP_GRAIN 0
#define RVMODEL_NUM_PMPS 16 // the PMP CSRs present (always 16 for 1-16 entries); 4 are usable, the rest read 0
#define SV39_SUPPORTED
#define F_SUPPORTED
#define D_SUPPORTED
#define ZCD_SUPPORTED
#define ZAAMO_SUPPORTED
#define ZALRSC_SUPPORTED
