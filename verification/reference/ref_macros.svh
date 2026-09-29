// SPDX-License-Identifier: MIT
//
// REF_-prefixed duplicates of design/decoder.sv's IS_INSTR/INSTR_CODE
// function-like macros, for ref_core.sv/ref_decoder.sv's own use.
//
// Both design/core.sv+design/decoder.sv and this directory's ref_core.sv+
// ref_decoder.sv are compiled together in ONE compilation unit (P3's own
// lockstep/regression harnesses build both the fsm and ref cores side by
// side) -- and `define is NOT module-scoped, it's compilation-unit-global.
// Reusing the SAME macro names for the reference copy would either
// silently redefine the FSM's own IS_INSTR/INSTR_CODE (if this header
// loads after decoder.sv) or vice versa, and most toolchains at minimum
// warn on any `define redefinition regardless of whether the bodies
// happen to match. Renaming this copy's macros removes the ambiguity
// entirely instead of relying on include order to avoid a clash.
//
// The underlying bit-pattern constants these expand through
// (`INSTR_CODE_ADD, `INSTR_MASK_ADD, `INSTR_ADD, etc., all from
// design/defaults/instruction_codes.sv and
// design/defaults/instructions_and_masks.sv) do NOT need REF_-prefixed
// duplicates: design/defaults/ is shared, `` `include ``d by reference
// (not copied) by both ref_decoder.sv and design/decoder.sv, so those
// constants are defined exactly once regardless -- see design/defaults/'s
// own append-only rule (checked by check_defaults.sh) for why that
// sharing is safe long-term.
`ifndef QV_REF_MACROS_SVH
`define QV_REF_MACROS_SVH

/* Check if instruction `instr` is `name`. Example: REF_IS_INSTR(i_instr, ADD). */
`define REF_IS_INSTR(instr, name) ((instr & `INSTR_MASK_``name) == `INSTR_``name)

/* Instruction code from name. Example: REF_INSTR_CODE(ADD) => 'b010100. */
`define REF_INSTR_CODE(name) 'b`INSTR_CODE_``name

`endif // QV_REF_MACROS_SVH
