# Celeris-64 (CLS64) Instruction Encoding Contract

Document Version: 1.21
Status: **Normative** — all simulator, assembler and disassembler code MUST match this
document. If code and this document disagree, one of them is a bug.

This document was missing from the repository. The architecture specification and the
implementation roadmap both describe an assembler and a binary loader, but nothing
defined the bit layout they exchange. This is that definition.

## 1. Machine Parameters

| Parameter        | Value | Note |
|------------------|-------|------|
| Instruction size | 64 bits, fixed | No variable-length decode, ever. |
| Byte order       | Little-endian | Repo mandate, AGENTS.md §2.2. |
| Data word        | 64 bits | |
| GPRs             | 12 (`R0`–`R11`) | |
| System regs      | `ZERO`, `PC`, `SP`, `LR`, `FLAGS` | |
| Capability ptr   | 128 bits | CHERI descriptor, §6. |

Fixed 64-bit width is a deliberate constraint: it makes fetch a constant stride, makes
`PC` advance trivially, and makes the decoder a pure function of one word with no
lookahead. Sub-width behaviour comes from the operand suffix, not from instruction
length.

## 2. Word Layout

Every instruction word is decoded as:

```
 63        56 55    52 51    48 47                            0
+------------+--------+--------+-------------------------------+
|   opcode   |  rd    |  rs1   |          operand field        |
+------------+--------+--------+-------------------------------+
    8 bits     4 bits   4 bits              48 bits
```

- `opcode[63:56]` — 8-bit major opcode, §3.
- `rd[55:52]` — destination register index, §4.
- `rs1[51:48]` — first source register index, §4.
- `operand[47:0]` — meaning depends on opcode, §3. Usually carries `rs2`, a width
  suffix, an immediate, or a sub-opcode.

Every immediate in this architecture fits within the operand field; there is no
wide-immediate form that steals bits from `rs1`, and no instruction is longer than one
word. An earlier revision of this section claimed otherwise; no such encoding was ever
defined in §3.1 and neither `decoder.zig` nor the assembler implements one, so the
sentence was removed rather than left to imply a capability that does not exist.

## 3. Opcode Map

Opcodes are grouped by high nibble so the decoder can dispatch with one compare.

### 3.0 Control (high nibble `0x0`)

| Opcode | Mnemonic | Operand encoding |
|--------|----------|------------------|
| `0x00` | `nop`    | unused, must be zero |
| `0x01` | `halt`   | unused, must be zero |
| `0x02` | `jump`   | `imm48` target address |
| `0x03` | `call`   | `imm48` target address; sets `LR` to address of next instruction |
| `0x04` | `ret`    | jumps to `LR` |
| `0x05` | `branch` | `branch rs1, [MATCH], target`; §3.0.1 |

#### 3.0.1 `branch` — the only conditional control transfer (`0x05`)

**Why this exists (v1.17).** Every revision through v1.16 defined `jump`, `call` and
`ret` — all **unconditional** — and nothing else. The architecture's stated principle is
that branches are *minimised* in favour of predication, and `compare` + `select` implement
that for **values**. But `select` chooses a value, never a control-flow target, so the ISA
could not express a loop. Not inefficiently: **not at all.** The consequence was visible
in `benchmarks/bench.zig`, whose "element-by-element loop" was unrolled by the **Zig
generator at build time** because the ISA had no way to express the loop itself, and in
`docs/comparison.md` §7 (F32), where the two "shapes" were one instruction at two chunk
sizes because no second shape could be written.

This is the smallest addition that makes the ISA able to express ordinary programs while
staying inside its own design: the branch tests the **same status enum `compare` already
produces**, so no flags register is introduced and the predication story is unchanged.

```
branch rs1, [MATCH], target
```

| Field | Meaning |
|-------|---------|
| `rs1` | register holding a status enum produced by `compare` (§3.2.1) |
| `operand[47:44]` | `rs2` — the match value, one of the five enum values |
| `operand[43:40]` | reserved, must be zero |
| `operand[39:28]` | reserved, must be zero |
| `operand[27:0]` | signed 28-bit byte offset, **relative to the branch instruction itself** |

`operand[27:0]` is an **offset, not an absolute address**, and is counted from the address
of the `branch` instruction. `jump`/`call` use an absolute `imm48`; the difference is
deliberate — a relative offset is what a compiler can emit for a forward reference without
knowing the final layout, and relocating a program does not invalidate its branches.

The instruction performs the transfer when `status(rs1) == MATCH`, and otherwise falls
through. Exactly one enum value is tested per instruction; arbitrary predicates such as
`>=` are expressed by comparing against one of the five values (for example "less than or
equal" is `branch R2, [LESS], t` followed by `branch R2, [EQUAL], t`) rather than by adding
a sixth value, because the enum is normative in §3.2.1.

**On the width nibble.** An earlier draft of this section gave `operand[43:40]` a
`width` meaning "checked for validity but not used to select a sub-register". That was
wrong, and the round-trip fuzzer disproved it within one run: a branch has no operand
being narrowed, so the field carries no information, yet *validating* it while *dropping*
it means a word with a non-zero nibble decodes, loses four bits when re-emitted, and
re-assembles to a different word. That is precisely the F20–F26 defect class. The field is
therefore **reserved and rejected when set**, like every other unused field in this
document, and the two encoders now agree on it.

**Match-value validity.** `rs2` must be one of `0`–`4`. Values `5`–`15` are not defined
status enums and are rejected when the instruction is decoded (§7). Testing against an
undefined enum is more likely a mistake than an intent, and accepting it would make a
branch that never fires look like a branch that always falls through.

For `jump`, `call` and `ret`, the operand field carries `imm48`, so `rd[55:52]` and
`rs1[51:48]` are **unused and must be zero**; a non-zero value is a diagnostic error (§7).
This matches the rule already stated for `nop` and `halt`. Previously only those two were
marked "must be zero", which implied the rest of the control group was unconstrained —
it is not, those bits simply have no meaning here. (`tooling` flagged the omission and
declined to invent the rule; recorded here instead.)

### 3.1 ALU (high nibble `0x1`)

Operand field layout for ALU ops:

```
 47      44 43   40 39    28 27                            0
+----------+-------+--------+-------------------------------+
|   rs2    | width |  zero  |            imm28              |
+----------+-------+--------+-------------------------------+
```

- `width[43:40]` — operand width suffix, §5.
- `zero[39:28]` — must be zero **for ALU instructions parsed under this section**. This
  12-bit gap is deliberate headroom: it keeps `imm28` a full 28-bit signed range in the
  low bits, which is what `decoder.zig`, `assembler.zig` and every encoded word in this
  repository already implement.
- `imm28[27:0]` — signed 28-bit immediate, sign-extended to 64 bits.
- If `imm28 != 0`, the instruction is immediate-form and `rs2` is ignored.

**Reserved fields are scoped per instruction class, never globally.** The operand field is
a shared 48-bit resource whose meaning is selected by the opcode, so a "reserved" claim in
one section does not reserve those bits for every opcode. Concretely, `stream.setp` (§3.4)
defines `operand[39:0]` as a signed 40-bit stride, which *deliberately overlaps*
`zero[39:28]` here. Both are correct because no word is ever decoded under both sections.
An earlier draft of the 1.2 amendment stated the `[39:28]` reservation as a global fact;
read literally it would have rejected every legal `stream.setp`. This paragraph is the
correction — `verifier` found the collision.

**Amendment 1.2 (normative).** Earlier revisions of this diagram labelled the immediate
field `[39:0]`, i.e. 40 bits wide, while the prose called it "signed 28-bit" and the
implementations truncated to 28. The name is authoritative and the diagram was wrong:
`assembler.zig` enforces `-134217728 … 134217727`, and `decoder.zig` reads a `u28`. A
40-bit field would also have collided with `width[43:40]`. 28 bits is retained because
widening it would silently reinterpret already-encoded words. Bits `[39:28]` are
therefore reserved and must be zero **for ALU instructions parsed under this section**;
a non-zero value is a diagnostic error (§7). See the scoping paragraph above: reserved
fields are per instruction class, so this does not apply to `stream.setp` (§3.4), which
gives those same bits meaning.

| Opcode | Mnemonic | Semantics |
|--------|----------|-----------|
| `0x10` | `add`    | `rd = rs1 + src2` |
| `0x11` | `sub`    | `rd = rs1 - src2` |
| `0x12` | `mul`    | `rd = rs1 * src2` (low 64 bits) |
| `0x13` | `div`    | `rd = rs1 / src2`; divide-by-zero is a diagnostic error, not a trap (§7) |
| `0x14` | `and`    | `rd = rs1 & src2` |
| `0x15` | `or`     | `rd = rs1 \| src2` |
| `0x16` | `xor`    | `rd = rs1 ^ src2` |
| `0x17` | `shl`    | `rd = rs1 << src2` |
| `0x18` | `shr`    | `rd = rs1 >> src2`, logical |
| `0x19` | `mov`    | `rd = src2`; `rs1` ignored |

`src2` means `rs2` or the immediate, per the rule above.

#### 3.1.1 Scalar memory access (`load` / `store`)

| Opcode | Mnemonic | Semantics |
|--------|----------|-----------|
| `0x1A` | `load`  | `rd = memory[rs1 + imm]` |
| `0x1B` | `store` | `memory[rs1 + imm] = src2` |

**Why these exist (v1.17).** Through v1.16 the only memory-touching opcodes were the fused
`stream.*` engine (§3.4) and the decode-only `cap.*` (§3.5). A single-element
fetch-modify-write without the stream engine was **not expressible in this ISA at all** —
`mov R5, [R4]` is rejected by the assembler because no memory operand form exists. That
made the architecture's central claim, that `stream.*` removes loop overhead, impossible to
evidence: the comparison could not exhibit a non-`stream.*` baseline because the ISA gave no
way to write one (F32, `docs/comparison.md` §7).

`load` and `store` are the scalar counterpart to the fused engine, exactly as a scalar ALU
op is the counterpart to a vector one.

**Operand layout, inheriting §3.1's ALU layout:**

| Field | Meaning |
|-------|---------|
| `rs1` | the base address register — **not** `operand`, because it is a register per §2 |
| `operand[47:44]` | `rs2` — `store`'s source register. **Reserved-zero for `load`** |
| `operand[43:40]` | `width` — §5 element width, which **is** the access size here |
| `operand[39:28]` | reserved, must be zero |
| `operand[27:0]` | signed 28-bit byte displacement from `rs1` |

For `load` the result goes to `rd` and `rs2` is unused; for `store` the value comes from
`rs2` and `rd` is unused. Either way the unused register field **must be zero**, and a
non-zero value is rejected when decoded — the same two-layer rule as §3.3 and §3.6, because
the assembler is not the only entry point (`run-bin` loads blobs).

**Addressing is `rs1 + imm`, with no post-increment.** Auto-increment belongs to the stream
engine; a scalar access that silently moved its own base would make `load` unusable for
random access, which is what it is for.

**Access width** comes from the §5 suffix on the *destination* register for `load`
(`load R5.w, [R4+0]` reads 2 bytes) and on the *source* register for `store`
(`store R5.b, [R4+0], R6` writes 1 byte). A sub-width load **zero-extends** into `rd`,
matching §2.1's rule for every other sub-register write. A sub-width store writes exactly
that many bytes.

**Bounds.** The whole access is checked before any byte is written, and a store that does
not fit is refused with no byte modified — the same all-or-nothing rule §3.4 states for
chunks. Partial application is forbidden here for the same reason.

### 3.2 Comparison and branchless select (high nibble `0x2`)

| Opcode | Mnemonic | Semantics |
|--------|----------|-----------|
| `0x20` | `compare` | `rd = statusEnum(rs1, src2)`; §3.2.1 |
| `0x21` | `select`  | `rd = (status(rs1) == matchVal) ? trueReg : falseReg`; §3.2.2 |

#### 3.2.1 `compare`

`compare` does not write `FLAGS` and does not branch. It materialises an explicit
status enum into `rd`, per the architecture spec §3.2 and the "elimination of boolean
blindness" principle (spec §1.5). The enum values are:

| Value | Name | Meaning |
|-------|------|---------|
| `0` | `EQUAL` | `rs1 == src2` |
| `1` | `LESS` | `rs1 < src2`, signed |
| `2` | `GREATER` | `rs1 > src2`, signed |
| `3` | `UNSIGNED_LESS` | `rs1 < src2`, unsigned |
| `4` | `UNSIGNED_GREATER` | `rs1 > src2`, unsigned |

Exactly one value is produced. The enum is the *only* sanctioned result of a
comparison; producing a bare `0`/`1` boolean is a spec violation.

#### 3.2.2 `select`

```
select rd, statusReg, [MATCH], trueReg, falseReg
```

Encoded as opcode `0x21` with:

- `rs1` — the status register holding a status enum.
- `operand[47:44]` — `rs2` = match value to test against.
- `operand[43:40]` — `trueReg` index.
- `operand[39:36]` — `falseReg` index.
- `operand[35:0]` — reserved, must be zero, rejected when set (§7). Stated explicitly
  because an undocumented gap is indistinguishable from an ambiguous one; the §3.1
  immediate defect was exactly that.

`select` performs a bitwise selection with no branch. Its result must be identical
regardless of which arm would have been taken, and it must not touch `PC` other than
the normal advance.

### 3.3 Field slicing (high nibble `0x3`)

| Opcode | Mnemonic | Semantics |
|--------|----------|-----------|
| `0x30` | `field.extract` | `rd = (rs1 >> offset) & mask(width)`; §3.3.1 |
| `0x31` | `field.insert`  | `rd = rs1` with `width` bits of `src2` placed at `offset` |

Encoding for both:

- `operand[47:40]` — `offset`, 8 bits, bit position, must satisfy §3.3.1.
- `operand[39:32]` — `width`, 8 bits, must satisfy §3.3.1.
- `operand[31:28]` — `src2` register index (`field.insert` only).

**Assembly syntax (normative, v1.9).** The textual forms are:
```
field.extract R0, R1, offset=12, width=3
field.insert  R0, R1, offset=12, width=3, R2
```
`offset` and `width` are **named**; `src2` is a bare trailing register in `field.insert`,
written after them. This reads oddly against the operand order in the table above, and
`tooling` flagged it — but it is the canonical form the disassembler emits and it
round-trips byte-identically, so it is frozen rather than reordered. Changing it would
invalidate every already-written `.dis` file and every stored word's single text form.
The contract previously showed only the `extract` form and left `insert`'s order to be
inferred, which is the gap this closes.
- `operand[27:0]` — reserved, must be zero, rejected when set (§7). Earlier revisions
  specified only `[47:28]` and left this range unmentioned. An undocumented range is not
  a licence: it is indistinguishable from an oversight, and the §3.1 immediate defect was
  exactly that. It is now reserved so a future operand has defined behaviour rather than
  ambiguous bits. (`tooling` declined to implement a rejection here because no reservation
  was declared — correct restraint; the omission was in this document.)

#### 3.3.1 Field constraints

- `width` must be `1..=64`. `width == 0` is a diagnostic error.
- `offset + width` must be `<= 64`. Overflow is a diagnostic error, not a silent wrap.
  Out-of-range extraction is exactly the class of bug this primitive exists to remove.
- Widths are explicitly non-power-of-two, e.g. `U1`, `U3`, `U5`, per spec §3.3.

### 3.4 Stream engine (high nibble `0x4`)

| Opcode | Mnemonic | Semantics |
|--------|----------|-----------|
| `0x40` | `stream.add` | fused load / add / store over a chunk, auto-stepping the pointer |
| `0x41` | `stream.copy` | fused load / store over a chunk |
| `0x42` | `stream.fill` | fused store of a scalar over a chunk |
| `0x43` | `stream.setp` | set a stream pointer register to base + stride |

Encoding for `stream.add`, `stream.copy`, `stream.fill`
(syntax: `stream.add rd, [rs1]+CHUNK, rs2`):

- `rd`  — destination/source register for the element (also the scalar for `fill`).
- `rs1` — pointer register holding the current stream address.
- `operand[47:44]` — `rs2`, the offset/second operand register.
- `operand[43:24]` — `chunk`, element count, 20 bits, must be `>= 1`.
- `operand[23:20]` — element width selector, §5 (same encoding as the register suffix:
  `0` = full 64-bit, `1` = `.l`, `2` = `.w`, `3` = `.b`).

  **Element width default (v1.10).** The syntax line above shows
  `stream.add rd, [rs1]+CHUNK, rs2` with **no** suffix, so the no-suffix case is the common
  one and must be defined. **No suffix means width `0`: full 64-bit elements.** That matches
  §5's table, where `0` is "none / 64-bit", and it matches every `stream.*` word this
  repository has ever encoded — the assembler could not emit any other width before v1.10,
  so choosing differently would silently change the meaning of existing binaries.

  The suffix is written on the **element register**: `stream.add R0.w, [R1]+8, R2`. Not on
  the pointer or the offset register, because `rd` is the operand the width describes. An
  earlier revision named the field without stating the default or where the suffix attaches;
  `rtl-core2` found the assembler never parsed it at all, so `.w` was accepted and discarded
  with no diagnostic. The contract now fixes both.
- `operand[19:0]` — reserved, must be zero. A non-zero value is a diagnostic error (§7),
  matching the rule for every other reserved field in this document (§3.1 `zero[39:28]`,
  §3.6 `reserved[39:32]`). Reserved means *rejected when set*, not *ignored*.

Encoding for `stream.setp`: `operand[39:0]` is a signed 40-bit byte stride. These bits
deliberately overlap the `zero[39:28]` field reserved by §3.1 for ALU ops; reservations
are per instruction class, not global (§3.1). `setp` is the only opcode that gives
`operand[39:28]` meaning, and `decoder.zig` implements it as a `u40`.

Stream semantics, normatively:

1. The operation applies to `chunk` consecutive elements starting at the pointer.
2. After the operation the pointer register advances by `chunk * elementSize`. This
   advance is the *only* pointer arithmetic any CLS64 program performs for a batch;
   explicit index arithmetic in a loop is the pattern this engine replaces.
3. Bounds are checked **before** any element is written. If the whole chunk does not
   fit in the accessible region, **no** element is modified. Partial application is
   forbidden — it is the failure mode that makes chunked code untrustworthy.
4. Element processing order is ascending address and is deterministic.

### 3.5 Capability instructions (high nibble `0x5`)

| Opcode | Mnemonic | Semantics |
|--------|----------|-----------|
| `0x50` | `cap.load`   | load a 128-bit capability into a register pair; §6 |
| `0x51` | `cap.store`  | store a capability from a register pair |
| `0x52` | `cap.check`  | `rd = capability access status` for the descriptor in `rs1` |

**Amendment 1.11 (normative).** The table above is all this section ever said, and it
never defined an **operand layout** — unlike §3.1–§3.4 and §3.6–§3.7, which each state
their bit positions. That omission produced two divergent implementations:

- `assembler.zig` `runCapability` parses **up to three** registers (`rd`, `rs1`, `rs2`)
  and accepts `cap.load R2, R3, R4`.
- `decoder.zig`'s `Cap` struct has **only** `op`, `rd`, `rs1`. The third register is
  parsed into `Instruction.rs2`, which `Cap` cannot reach, so `assembleWord` emits
  `assembleWord(c.op, c.rd, c.rs1, 0)` and the operand is **silently discarded**.

So `cap.load R2, R3, R4` assembles today, and `R4` vanishes. This is defect F12, the same
class as F1 (`.w` on `stream.add` discarded) and F8 (`add PC` discarded): a lexical form
the encoding cannot represent, accepted without complaint.

**Operand layout, ruled:**

| Field | Meaning |
|-------|---------|
| `rd` | destination register, or the **low** register of a pair for `cap.load` |
| `rs1` | source register, or the **low** register of a pair for `cap.store` |
| `rs2` | **unused, and must be zero** |
| `operand[47:0]` | reserved, must be zero |

**Enforcement (normative).** The `operand[47:0]` reservation is **whole-field**, not just
the `rs2` bits at `[47:44]`, and a non-zero value must be rejected **in the decoder**, not
only by the assembler. The assembler never sees a hand-built or loaded image, and a binary
blob is the primary input of `run-bin`, so a rule enforced only at assembly time is
unenforced on the path that most needs it. This is the F15 defect (v1.14): the decoder
accepted `0x5023400000000000` as `cap.load R2, R3` with the operand silently dropped, while
`thread.*` (§3.7) and the accelerator range (§3.6) each rejected their own equivalent
violation. Precedent for the two-layer rule is F8 (`add PC`), where the assembler refusing
the form did not make the VM free to discard it silently.

`rd` and `rs1` are interpreted exactly as the table above already says. The third
register is removed from the textual form rather than given an encoding: **the
capability's own address comes from the register pair itself, not from a third
operand.** §6 already fixes the descriptor as two consecutive registers starting at an
*even* index, so `cap.load R2` names the pair `(R2, R3)` and no address field is needed.

**Even-index rule (normative).** For `cap.load`/`cap.store`, the low register index must
be **even**. An odd index would split a descriptor across pairs `(R1,R2)` and overlap the
neighbouring descriptor `(R2,R3)` — the same word describing two different capabilities.
An odd `rd`/`rs1` is a diagnostic error naming the register, not a silently rounded index.

**Fidelity (v1.11, normative and deliberately unresolved).** `cap.load` and `cap.store`
perform a **memory** transfer, and §6's descriptor is 128 bits, but the encoding carries
**no address field** and this amendment does not invent one. Two readings were available
and both were rejected as inventions:

- that the pair holds the address, which contradicts §6 making the pair hold the
  descriptor itself;
- that a third register supplies the address, which the encoding cannot represent.

**Ruling: `cap.load` and `cap.store` are decode-only in this revision.** They encode,
disassemble and round-trip, and the simulator must **refuse them with a diagnostic
stating that the address source is undefined** — never guess, never return zero. This is
the same honest-refusal treatment §3.6's accelerators already receive.

**Correction to Amendment 1.11 (defect F13, found by `core-vm` under task-20).** The
sentence above originally ended "`cap.check` is fully determined and **must execute**."
That was **wrong**, and it was the Lead's error. It was disproved by implementing it:

- `cap.check`'s **destination** is determined (`rd`). Nothing needed to **compute a
  value** is.
- §6's diagram gives the pair as word 0 = `base`, word 1 = `permissions` + `reserved`.
  **`length` has no bit position in the pair at all.** §6's own v1.7 note records that
  the earlier "`length` in `permissions[23:0]`" claim described a packing that "does not
  exist". So a `Capability` cannot be reconstructed from `rs1`, and `Capability.init`
  rejects a zero length — there is nowhere to read one from.
- `Capability.check(address, size, access)` needs **three** inputs. The encoding
  `(op, rd, rs1)` supplies **none** of them: no address, no size, no access kind.
- **"capability access status" is defined nowhere in this repository.** The only
  occurrence is the §3.5 table row itself. It is not `CapError` (an error set, not a
  value) and not `select.Status` (whose five members are comparison outcomes). Grep
  confirms: one hit, the table line.

So producing any value for `rd` would be exactly the invention this amendment refused
for `cap.load`/`cap.store`. **`cap.check` is decode-only in this revision too**, and the
simulator must refuse it with a diagnostic stating that the descriptor cannot be
reconstructed and the status value is undefined — applying the same standard, not a
weaker one because the instruction is named "check".

**Ruling: all three `cap.*` opcodes are decode-only.** The even-index rule is scoped to
`cap.load`/`cap.store` only: `cap.check`'s `rs1` names a descriptor to *test*, not a pair
it forms.

A future revision that defines the address source must also raise the even-index
requirement and the `rs2` reservation together, since they are one decision — and if it
defines `cap.check`'s status value, it must define the address, size and access source in
the same revision, for the same reason. Fixing half of either decision is the defect
class this amendment exists to close.

### 3.6 Accelerator space (high nibble `0x6`–`0x8`)

Dedicated to `matrix.*`, `fft.*` and `codec.*` (spec §3.4) so they never collide with
general instructions.

- `0x60`–`0x6F` — `matrix.*`; low nibble selects the operation.
- `0x70`–`0x7F` — `fft.*`.
- `0x80`–`0x8F` — `codec.*`.

**Amendment 1.1 (normative).** Earlier revisions deferred the operand layout to the
model modules. A model cannot own an encoding: the assembler, decoder, disassembler and
the Phase 4 RTL must all agree bit-for-bit before any of them can be verified against
the others. The layout is therefore fixed here, and derived from the existing model
signatures rather than invented (`matrix.Mat`, `fft.fft`, `codec.compress`).

Operand field layout for all accelerator ops:

```
 47    44 43    40 39      32 31                            0
+--------+--------+----------+-------------------------------+
|  rs2   |  rs3   | reserved |            count              |
+--------+--------+----------+-------------------------------+
   4 bits  4 bits   8 bits                32 bits
```

- `rs2[47:44]` — second source register. `0` means "unused", not `R0`.
- `rs3[43:40]` — third source register (destination-staging or modulus). `0` unused.
- `reserved[39:32]` — must be zero. A non-zero value is a diagnostic error (§7), so
  the space stays available for future operands without a flag day.
- `count[31:0]` — element or byte count, unsigned. ~~`0` means "derive the count from
  the destination register", which is the form the assembler emits when no count is
  written.~~

  > **RETRACTED IN PLACE by Amendment 1.18 (normative).** The struck sentence above was
  > normative from 1.1 through 1.17 and is **no longer in force for any operation**. It
  > is kept rather than deleted so a reader who saw it in an earlier revision can find
  > out what happened to it.
  >
  > It never said what the destination register *holds*, whether that value is a byte
  > count or an element count, or what `rd = R0` means — and `R0` is a real writable
  > register, so the hardwired-zero rule does not settle it. It also named one register
  > as both an input length and the operation's result.
  >
  > **Current rule (Amendment 1.18, Rule D):** `count` is an explicit length whose
  > **unit is stated per operation** in Rule E's table — complex elements for `fft.*`,
  > u64 elements for `fft.ntt`, bytes for `codec.*`, elements per stream for
  > `matrix.transform`. **`count = 0` means "no count", and is a diagnostic error for
  > every operation that needs a length.** `matrix.identity` is the one row where `0` is
  > a value rather than a missing length, and it takes its order from `rs1`, not from
  > `count`. See Rule D and Rule E below for the full statement.

Each operation names its operands positionally, exactly as the model signature reads:

| Opcode | Mnemonic | Operands | Model signature |
|--------|----------|----------|-----------------|
| `0x60` | `matrix.det`     | `rd, rs1`               | `matrix.determinant(m)` |
| `0x61` | `matrix.invert`  | `rd, rs1, rs2`          | `matrix.invert(m, out)` |
| `0x62` | `matrix.mul`     | `rd, rs1, rs2`          | `matrix.multiply(a, b, out)` |
| `0x63` | `matrix.transform` | `rd, rs1, count=N`    | `matrix.transformSoA(xs, ys, zs, m)`; the three streams are consecutive from `rs1`, `count` is elements **per stream** |
| `0x64` | `matrix.identity` | `rd, count=N`          | `matrix.identity(n, out)` |
| `0x65` | `matrix.mulout`   | `rd, rs1, rs2`          | `matrix.multiply(a, b, out)`, orders from the in-memory headers (Rule E.7) |
| `0x70` | `fft.forward`    | `rd, rs1, count=N`      | `fft.fft(data, false)` |
| `0x71` | `fft.inverse`    | `rd, rs1, count=N`      | `fft.fft(data, true)` |
| `0x72` | `fft.ntt`        | `rd, rs1, rs2, count=N` | `fft.ntt(data, false)`, modulus in `rs2` |
| `0x73` | `fft.ntt.inverse` | `rd, rs1, rs2, count=N` | `fft.ntt(data, true)` |
| `0x80` | `codec.compress`   | `rd, rs1, count=N`    | `codec.compress(input, out)` |
| `0x81` | `codec.decompress` | `rd, rs1, count=N`    | `codec.decompress(input, out)` |
| `0x82` | `codec.fnv1a`      | `rd, rs1`             | `codec.fnv1a(data)` |
| `0x83` | `codec.checksum16` | `rd, rs1`             | `codec.checksum16(data)` |

An opcode in `0x60`–`0x8F` that is not in this table is **reserved**: it decodes as an
accelerator instruction with an unrecognised operation, must round-trip as raw bytes,
and must not be silently reinterpreted as a neighbouring operation.

> **Amendment 1.20 — which layer refuses a reserved opcode (resolves F37).** The
> sentence above is right in substance but was ambiguous about its *layer*, and the
> ambiguity was recorded as **F37** (`docs/STATUS.md`): "must not be silently
> reinterpreted" sits beside "decodes as an accelerator instruction", so a reader could
> take the **decoder** to be what rejects a reserved byte.
>
> It is not. The **decoder accepts** every byte in the range as an accelerator
> instruction — that is what clause 1 says, and clause 2 *requires* it: the disassembler
> reaches its `.raw` fallback through the `.accelerator` arm, so a decoder that returned
> an error could not render the bytes clause 2 says must round-trip as raw.
>
> Normative, and stated explicitly so the three clauses are read as one:
> 1. A reserved opcode **decodes** as an accelerator instruction with an unrecognised
>    operation. `decoder.decode` returns success for it and **must not** be changed to
>    reject it; a test pins this, because "the decoder should refuse it" is the natural
>    and wrong reading.
> 2. It **round-trips as raw bytes** (`.raw`), keeping every bit.
> 3. The **simulator refuses it at execution** — a fault, not a decode error — with a
>    diagnostic naming the byte, and never reinterprets it as a neighbouring operation.
>
> The superseded reading, that the *decoder* rejects a reserved opcode, was never
> implemented and is retracted here rather than deleted, so a reader who expected a
> decode error can find out why there is none.

Behaviour of these operations in the simulator is a **software model** and must be
labelled as such — see §8. The RTL in `rtl/` implements the same encodings; that shared
encoding is what makes cross-checking the two meaningful.

**Amendment 1.18 (normative), part 1: operand-address arithmetic.**

Amendment 1.1 above fixes *which field holds which operand*. It does not fix what those
operands *mean* — it never says which register holds an address, where a matrix's order
comes from, where an output buffer lives, or what unit `count` is in. The result was
recorded as **F36** (`docs/STATUS.md`): the table names `matrix.determinant(m)` but the
word carries no dimension, and it names `codec.compress(input, out)` but the word carries
no output address. This part of the amendment supplies the missing arithmetic, from the
field set that already exists. **It does not widen the encoding.** No fifth field, no new
bit, no change to the word layout of 1.1.

**Rule A — every register operand is a VALUE, not an index, with exactly two exceptions.**

An operand register named as an address in the per-operation rules below must hold the
**address itself**, a full 64-bit unsigned byte offset into the flat memory model (§2.3).
It is not a register index and it is not a pointer-to-a-pointer. It must be byte-aligned
to the element width the operation reads or writes, which is stated per operation.

The two exceptions are the two matrix-header forms, which deliberately read a register as
**two 32-bit halves** rather than as one value:

```
 63                32 31                 0
+--------------------+--------------------+
|     rows (u32)    |     cols (u32)     |
+--------------------+--------------------+
```

A word-slice header register names a matrix's order without a memory fetch. The
alternative — a 4×4 size field packed into `rs3` — is **rejected**: `rs3` is four bits, so
it could express at most `n = 15`, and a 4-bit dimension is exactly the "plausible-looking
fabricated number" F36 exists to prevent.

**Rule B — matrix data is f64, and row-major.**

Every `matrix.*` operand is a sequence of IEEE-754 `f64` (8 bytes, little-endian),
**row-major** (`matrix.Mat.at` is `data[r * cols + c]`). So an `n × n` matrix occupies
`8 · n · n` bytes, and an `m × k` times `k × n` product occupies `8 · m · n` bytes.

**Rule C — `codec.compress`'s fixed workspace is part of the operation, and its
availability is a CHECKED PRECONDITION, not an assumption.**

`codec.compress` has no fitting output field either. Its output is written to a
**256-byte scratch region at the fixed byte offset 65 280 (`0x0000_FF00`)**. Byte offset
65 280 and the 256-byte length are **normative**. The output byte count is written into
`rd` as a value, which is the one observable result. This offset is fixed rather than
derived because there is no field left to derive it from, and a fixed *documented*
workspace is reproducible — unlike a workspace inferred from whatever happens to follow
the input in memory, which is the fudge this rule is written to forbid.

**Correction (this amendment, retracted in place).** An earlier draft of this rule said the
workspace "resides in the 64 KiB memory image every execution entry point allocates". That
was **false**, and the Lead disproved it by reading the callers rather than the rule:

| Caller | Memory image | Fits 65 280? |
|---|---|---|
| `src/main.zig` (the CLI) | 65 536 (`image_bytes = 1 << 16`) | yes |
| `src/examples.zig:73` | 20 480 | **no** |
| `src/crossarch.zig:42` | 4 672 | **no** |
| accelerator tests (`vm.zig` `imageWithSize`) | program-sized | **no** |

`Vm.init(image: []u8)` accepts **any** slice, so 65 536 was a convention of one CLI, not a
property of the machine. The rule as drafted was out of bounds for every fixture except
the CLI's, which would have made it untestable in the normal setup.

**The rule is therefore scoped, not weakened.** The workspace exists only when the memory
image is at least **65 536 bytes** (65 280 + 256). The precondition is *checked*, and the
failure mode is a **diagnostic, never a panic and never a silent truncation**:

- **Image ≥ 65 536 bytes:** `codec.compress` executes and writes its output to byte
  65 280.
- **Image < 65 536 bytes:** `codec.compress` **refuses** with a bounds sentence naming the
  required address (65 280), the required length (256) and the actual image length, and
  touching no byte. It does not clip the workspace, does not relocate it, and does not
  write a short stream at the end of memory.

This keeps the offset deterministic and specified while making its precondition explicit
and testable in both directions. The alternative — lowering the offset so it fits today's
fixtures — was **rejected**: it would bake a caller's `data_base` convention into the
contract, which is exactly what Rule C exists to avoid, and it would silently corrupt any
program whose data region reached the new offset. A caller that wants `codec.compress`
must allocate an image large enough for the workspace; that requirement is now stated
rather than assumed.

`codec.decompress` **cannot** use this rule and stays refused; see Rule E.1.

**Rule D — `count = 0` means "no count", and that is a diagnostic error.**

§3.6's sentence *"`0` means 'derive the count from the destination register'"* is
**superseded by this amendment for every operation.** Reading `rd` as an input count would
impose a calling convention in which a program pre-loads its own *result* register with a
length before every accelerator instruction — the same register named as both an input and
an output. That is a plausible convention, not a stated one, and F36's whole point is that
an unstated convention must not be implemented behind the user's back.

The rule is therefore: **`count = 0` is a diagnostic error for every operation that needs
a length.** There is exactly one exception, stated per row in Rule E: `matrix.identity`
does not read `count` as its length at all — its order comes from `rs1` — so its `count`
field is required to be **zero**, and a non-zero value is itself a diagnostic. Its order
`rs1 = 0` is the empty matrix rather than an error. The rejected alternative was to keep
the 1.1 sentence and let `rd` seed the count; it is rejected because it silently changes
what `rd` means per call site, and because no unit could be attached to it without
guessing.

**Rule E — per operation.** Two conventions hold for every row below. First, an operand
named as an address holds an **address value** (Rule A), and the row says which register
that is. Second, redundant bits are normative: an operand a row does not use
**must be zero in the word**, and a non-zero value is a diagnostic error, the same rule
§3.6 already applies to `reserved[39:32]`. A redundant operand is rejected rather than
ignored so no program can carry a meaning the operation does not have.

| Opcode | Addresses | Shape | `count` | Unit | Status |
|---|---|---|---|---|---|
| `0x60` `matrix.det` | `rs1` **value** = matrix address; `rd` receives the determinant | `n` = `rs3`, `1..15` (u4, `0` = 16); 8·n·n bytes at `rs1` | must be `0` | — | **executes** |
| `0x61` `matrix.invert` | `rs1` **value** = input address, `rd` **value** = output address | `n` = `rs2`, `1..15` (u4, `0` = 16) | must be `0` | — | **executes** |
| `0x62` `matrix.mul` | not expressible | — | — | — | **refused**, Rule E.5 |
| `0x65` `matrix.mulout` | `rd` **value** = product address, `rs1` **value** = A address, `rs2` **value** = B address | each matrix is `rows:u32 \| cols:u32` at its address followed by row-major `f64` (Rule E.7); `rs3` and `count` must be `0` | must be `0` | — | **executes** |
| `0x63` `matrix.transform` | `rs1` **address value** (stream base) | 4×4 `m` = 16 `f64` at `rs2`; three streams of `count` `f64` each, consecutive from `rs1` (`count = 0` refused) | elements **per stream** | `f64` elements | **executes** |
| `0x64` `matrix.identity` | `rd` **value** = output address | `n` = `rs1`, `0..16`; `n = 0` is the empty matrix and is **not** an error, because `0` is a meaningful order here rather than a missing length | must be `0` (the order is in `rs1`, not here) | `f64` elements per side | **executes** |
| `0x70` `fft.forward` | `rd` **value**, `rs1` **value** | — | `N` = `count`, `0` refused; `N` must be a power of two | **complex elements** (16 bytes) | **executes** |
| `0x71` `fft.inverse` | as `0x70` | — | as `0x70` | complex elements | **executes** |
| `0x72` `fft.ntt` | `rs1` **value**; `rd` receives the element count | `rs2` and `rs3` must be `0` — see rule E.6 | `N` = `count`, `0` refused | **u64 elements** (8 bytes) | **executes** |
| `0x73` `fft.ntt.inverse` | as `0x72` | as `0x72` | as `0x72` | u64 elements | **executes** |
| `0x80` `codec.compress` | `rs1` **value** (input), `rd` **value** (compressed byte count) | output → the 256-byte workspace at byte 65 280 (Rule C) | `count` = input bytes, `0` refused | **bytes** | **executes** |
| `0x81` `codec.decompress` | `rs1` **value** (input) | — | not expressible | — | **refused**, Rule E.1 |
| `0x82` `codec.fnv1a` | `rd` **value**, `rs1` **value** | — | `count` = bytes, `0` refused | **bytes** | **executes** |
| `0x83` `codec.checksum16` | `rd` **value**, `rs1` **value** | — | `count` = bytes, `0` refused | **bytes** | **executes** |

**Rule E.1 — `codec.decompress` stays refused, and this is not an oversight.** The
operation needs a decompressed-length bound `out.len` that Rule C's fixed workspace cannot
supply. This is a property of the operation, not of the guess that was available:
`compress` stops at the first byte that will not fit and reports how much it wrote, so a
256-byte workspace is sound for it. `decompress` reads a length out of the *input stream*
and returns `BufferTooSmall` if the decompressed text is larger — so a decompress with a
256-byte bound would **refuse valid inputs whose output exceeds 256 bytes**, which is a
silent narrowing of the operation's domain. There is no field left to carry a bound:
`rd`, `rs1`, `rs2`, `rs3` and `count` are all named for this row. If the workspace size
were raised to something larger it must be stated here, and any value chosen remains a cap
the operation's own semantics do not have. The row is left refused with the reason rather
than given a bound it cannot honour.

**Rule E.2 — all thirteen operations map their `rd` result into the 64-bit register by
bit reinterpretation only.** An `f64` determinant or matrix is not converted to an
integer; it is written as its IEEE-754 bit pattern (`@bitCast`). This is why the
misaligned-address check below is a refusal and not a silent copy: the operation reads and
reinterpret-casts `f64`, so its input address must be 8-byte aligned, and an `fft.*`
address must be 16-byte aligned for `Complex`.

**Rule E.3 — an accelerator whose address, length or alignment is unusable refuses; it
never reads unaligned memory, never truncates a range, and never returns zero.** Every
address is bounds-checked against the memory image, and every alignment is checked against
the element width, **before the first byte is touched**. A refusal reports the operation,
the offending address and the length or width it required, in a sentence (§7). No
`@alignCast` may be applied to a computed address: a misaligned cast is a panic, not a
diagnostic.

**Rule E.5 — `matrix.mul` is refused, and the reason is a genuine field shortage.**

`matrix.multiply(a, b, out)` consumes **three addresses** (`a`, `b`, `out`) and needs
**two orders** (`a`'s and `b`'s) to know how to index them. The word has four operand
fields: `rd`, `rs1`, `rs2`, `rs3`. Five inputs cannot fit four fields, and `count` is
already required to be zero on this row by the redundant-operand rule.

Three ways out were considered and all three are rejected:

1. **Read one order from `count`.** That abandons a uniform `count` rule, and it still
   leaves only four slots for the remaining four inputs *only if* one order is assumed
   square — which is inventing a constraint the operation does not have.
2. **Take one order from the other matrix's data.** It would make `a` and `b` aliasable
   in a way the model explicitly forbids (`multiply`'s own comment: *"`out` must not
   alias either input"*), and the order would be read from a region the operation is
   about to overwrite.
3. **Drop an address and derive it.** Deriving `out` from `a`'s extent is exactly the
   "workspace inferred from memory layout" fudge Rule C rejects for `compress`.

A fourth option — splitting `matrix.mul` into two opcodes, one per operand order — is a
**new opcode**, not an operand rule, so it is out of scope for an amendment that states
it does not change the encoding. It is the right fix if this is wanted later, and it is
recorded here so the next revision does not re-derive the shortage from scratch.

> **Amendment 1.19 update (normative, kept below the original text).** That second opcode
> now exists as **`0x65` `matrix.mulout`, Rule E.7** — but not as "one per operand order".
> The orders are not what forces a split: they are read from each matrix's own
> `rows:u32 | cols:u32` header, the form Rule A already defines, so one opcode serves every
> shape. `0x62` is **not** repurposed and its refusal above still stands verbatim; a reader
> who wants a multiply that runs uses `0x65`.

So `matrix.mul` joins `codec.decompress` as refused. Its row above is left in the table
with the reason rather than deleted, because the opcode is still assigned by 1.1 and a
reader who assembles `matrix.mul` must be able to find out why it will not run.

**Rule E.6 — `fft.ntt`'s `rs2` is reserved-zero in this revision, and that is a
supported scope, not a silent narrowing.** 1.1's row says *"modulus in `rs2`"*, but the
model (`fft.ntt`) takes no modulus parameter at all: it always works modulo
`fft.ntt_modulus` (998 244 353). Accepting a modulus register and then ignoring it is the
**F34 class** — a field that is validated but dropped, so a program that set a modulus of
17 would receive residues modulo 998 244 353 and no diagnostic. Rule E's redundant-operand
rule therefore applies to `rs2`: it must be zero. A revision that gives the model a
modulus parameter should lift this reservation in the same change that lifts the model
limit, not before.

**Rule E.7 — `matrix.mulout` (0x65) is the multiply whose operands DO fit, and it is not a
redefinition of `matrix.mul`.** Amendment 1.18 was right to refuse `0x62`: that word has
three addresses to name and only `rd`, `rs1` and `rs2` to name them with, because it also
needs two orders and `rs3`/`count` are required to be zero by the redundant-operand rule.
"Pick a convention for the orders" was the failure mode F36 exists to prevent — a plausible
wrong matrix.

The shortage was never the *addresses*; it was the *orders*. Amendment 1.19 adds a second
opcode for the case where the orders do not have to be in the word at all, because **each
matrix carries its own header in memory** — the form Rule A already defines:

```
  byte 0            byte 4            byte 8 ...
+-----------------+-----------------+-------------------------------+
|  rows (u32 LE)  |  cols (u32 LE)  |  row-major f64 data ...       |
+-----------------+-----------------+-------------------------------+
```

- **`rs1`'s address** holds input A, **`rs2`'s** holds input B, **`rd`'s** holds the product.
  All three are Rule A **address values** (not register indices), and all three must be
  **8-byte aligned**, because the f64 data that follows every header is read as `f64`.
- **The product's header is WRITTEN by the operation, not read.** It is set to
  (`A.rows`, `B.cols`), so the product is a self-describing matrix and can itself be an
  input to a later `matrix.mulout`. Whatever the destination bytes held before is
  overwritten; this is the one row in §3.6 that writes a header.
- **The orders come from the data.** `a.cols` must equal `b.rows`; anything else is a
  diagnostic naming both shapes, and nothing is written.
- **`rs3` and `count` must be zero**, per Rule E's redundant-operand rule. There is no
  length to carry: the region lengths are `8 + 8·rows·cols`, derived from the headers.
- **A side is 1..16.** `0` on either side is a diagnostic (a matrix with no entries has no
  product), and so is anything above 16. The limit is **not** a machine limit and is not a
  performance statement: `matrix.multiply` accumulates into a fixed `[256]f64` stack buffer
  so that no allocation happens inside the execution loop (Rule E.4), and 256 covers every
  product up to 16×16. A larger matrix refuses with a sentence rather than truncating.
- **Every header and every data region is bounds-checked and alignment-checked before the
  first byte is touched** (Rule E.3). A header that is itself in bounds but whose declared
  data would run past the image is refused by the header's own numbers, not by whatever
  room happens to be left.
- **`rd` is not rewritten.** Unlike `matrix.det`, this row's entire result is in memory, so
  there is no scalar to reinterpret into a register; `rd` keeps holding the address it
  named. Rule E.2 does not apply to it.
- **`matrix.mul` (0x62) is unchanged.** It still refuses with Rule E.5's sentence. A reader
  who assembles `matrix.mul` and wants it to run should assemble `matrix.mulout` and give
  its matrices headers; nothing is silently re-routed.

The rejected alternative for `0x65` was to read `count` as a shared side length and assume
both matrices square. It is rejected because it narrows the operation to square products,
which the model does not require, and because it would still not name which of `rs1`/`rs2`
is on the left — the exact ambiguity that made `0x62` unusable.

**Rule E.4 — the operation must not allocate.** All slices are views into the flat memory
model (§2.3), per AGENTS.md §4.1. No accelerator operation may allocate inside the
execution loop.

### 3.7 Thread instructions (high nibble `0x9`)

| Opcode | Mnemonic | Semantics |
|--------|----------|-----------|
| `0x90` | `thread.spawn` | start thread slot(s) `operand[7:0]` at address `rs1` |
| `0x91` | `thread.join`  | wait for thread slot(s) `operand[7:0]` |
| `0x92` | `thread.yield` | yield the current slot |

Slot range is `T0`–`T7` (spec §4.1). `operand[7:0]` is a bitmask, one bit per slot.

**Amendment 1.6 (normative).** Every revision up to 1.5 declared this mask as
`operand[4:0]`, which is **five bits — incapable of addressing eight slots.** `T0`–`T7`
requires eight bits, and the code has always used a `u8` (`assembler.zig` `slot_mask: u8`,
`thread.zig` `slot_count = 8`). So the contract could not express its own slot range, and
`thread.spawn T0-T7` assembled to `operand = 0xff` — setting `operand[47:5]` non-zero,
which the previous revision's own reserved-bits rule declared illegal. The word was
malformed by the rule in the same section that required it.

The width is **`operand[7:0]`**, matching the implementation and the eight-slot range.
`operand[47:8]` is the reserved region. This defect was invisible while `T0-T7` merely
aborted (F7); fixing the abort exposed it. Found by Lead arithmetic check on the repaired
output word, not by any test — no test asserted the mask's bit position.

**Assembly syntax (normative, clarified in 1.4).** The slot mask is written **first**, the
address register second:

```
thread.spawn T0, R0          # start slot T0 at the address in R0
thread.spawn T0, T2, R0      # start slots T0 and T2
thread.spawn T0-T7, R0       # start all eight slots
thread.spawn no slots, R0    # legal: empty mask, starts nothing
thread.join  T0, T2          # wait for slots T0 and T2
thread.yield                 # yield the current slot; takes no operand
```

The opcode table above says "slots `operand[7:0]` at address `rs1`", which describes
*which field holds what* and not the textual order. That phrasing was read as
address-first by `verifier` and is a fair reading, so the order is fixed explicitly here.
Slots-first is authoritative because the disassembler already emits that form and it
round-trips; changing it would invalidate every word the disassembler produces.

`thread.yield` takes **no operand**. Although it shares the `0x9` nibble, the current-slot
implicit operand is not encoded, and supplying a slot list is a diagnostic error. The
opcode table's shared `operand[7:0]` row applies to `spawn` and `join` only.

Amendment 1.1 already defines `no slots` as legal for `spawn`/`join`. The same empty-mask
text is accepted wherever a slot list is accepted.

**Amendment 1.1 (normative).** `operand[7:0] == 0` is a legal encoding that names no
slot. It is not an error: it is the bit pattern an uninitialised or deliberately empty
mask word produces, and a disassembler must be able to print it and an assembler must
be able to read that text back. Writing `thread.spawn` with no slot list assembles to
mask `0`. Textual form:

| Bitmask | Text |
|---------|------|
| `0` | `no slots` |
| `1` | `T0` |
| `0b101` | `T0, T2` |
| `0b11111111` | `T0–T7` (enumerated as `T0, T1, … T7` when re-assembled) |

`T0–T7` is accepted on input as shorthand for all eight slots, but the disassembler
always enumerates slots individually, because a canonical round trip must produce one
fixed form per word. The remaining bits `operand[47:8]` must be zero; a non-zero value
is a diagnostic error (§7).

## 4. Register Index Encoding

| Index | Register |
|-------|----------|
| `0`–`11` | `R0`–`R11` |
| `12` | `SP` |
| `13` | `LR` |
| `14` | `PC` (readable; writing it is a diagnostic error outside jump forms) |
| `15` | `FLAGS` |

`ZERO` has no index: it is expressed by *omitting* a write target. Code that needs a zero
uses the literal immediate `0`, which encodes with no register pressure. This keeps
`ZERO` from consuming one of only 16 index slots.

An earlier revision of this paragraph added "and any read of index `15` in a source
position where a zero is required is not defined". Index `15` is `FLAGS` — as this
section's own table says two lines above — so that sentence described `FLAGS` as if it
were the zero register, a leftover from a draft in which index `15` held `ZERO`. It is
deleted rather than reworded, because there is no such thing as "a source position where
a zero is required": a zero operand is the literal `0`, never a register. Found by
`verifier` (F9).

Index `12`–`15` in `rd` of a normal ALU op is **encodable**; in `rs1`/`rs2` it is legal
for `SP`, `LR` and `FLAGS` and a diagnostic error for `PC`.

"Encodable" is not "meaningful". `PC` (index `14`) as a destination encodes fine — the
bits are well-formed — but the fixed 8-byte advance overwrites it on the fall-through
path, so the computed value would be discarded. That is why `PC` as a destination is an
error: not because the register index is illegal, but because the result cannot take
effect. An earlier revision stated both facts separately — "writing it is a diagnostic
error outside jump forms" in the table above, and "index 12–15 in `rd` … is legal" here —
which read as a flat contradiction to anyone encoding `add PC, R1, R2`. `core-vm` hit the
collision while implementing the fault and resolved it this way; the wording above is
theirs.

## 5. Width Suffix Encoding

| Value | Suffix | Bits | Register write behaviour |
|-------|--------|------|--------------------------|
| `0` | none | 64 | full write |
| `1` | `.l` | 32 | write low 32, **zero-extend** upper 32 |
| `2` | `.w` | 16 | write low 16, **zero-extend** upper 48 |
| `3` | `.b` | 8  | write low 8, **zero-extend** upper 56 |

Zero-extension on every sub-width write is mandatory and observable, per spec §2.2:
it is the mechanism that removes partial-register stall dependencies. A test must
prove that a sub-width write clears the upper bits rather than preserving them.
Value `4`–`15` are reserved and are a diagnostic error.

## 6. Capability Descriptor Layout (128-bit)

```
 byte 15        8 7              0
+---------------+----------------+
|  permissions  |    reserved    |   high 64 bits
+---------------+----------------+
|           base (64)            |   low  64 bits, word 0
+--------------------------------+
```

A capability occupies **two consecutive 64-bit registers**, starting at an even index.
Simulator representation:

- `base` — starting address, 64-bit.
- `length` — accessible byte count, 64-bit. An earlier revision of this line said it was
  "stored in `permissions[23:0]`", which is impossible: a 64-bit value cannot be held in
  24 bits. No such packing exists — `capability.zig` carries `length` as a full `u64`
  field beside `base` and `perms`, and the descriptor is the pair of registers shown
  above. The line was removed rather than reworded because it described an implementation
  that was never written. (`verifier` found the contradiction.)
- `perms` — bit flags: bit 0 read, bit 1 write, bit 2 execute. The remaining permission
  bits (`perms[7:3]`) are reserved and must be zero.

  **Fidelity note (v1.7).** The reserved bits are marked in the model
  (`capability.zig` declares `_reserved: u5`), but the model **does not currently reject a
  non-zero value**, and it could not: `Perms` is a Zig packed struct constructible only
  through its named fields, `_reserved` defaults to `0`, and no public entry point accepts
  a raw byte, so a non-zero value is unreachable rather than merely unchecked. The earlier
  claim that a non-zero value "is a diagnostic error" described an enforcement path that
  does not exist. Stating the reservation and the absence of enforcement is honest;
  inventing a diagnostic for an unreachable state would be dead code. If a raw-byte
  constructor is ever added, the rejection must be added with it. (`verifier`, F10.)

Every memory access in the simulator goes through a capability check. An access whose
address is below `base` or at/above `base + length` must fail with a diagnostic naming
the address, the base and the length. It must not silently truncate, and it must not
return zero.

This is a **software model** of the CHERI descriptor. It is not cryptographic and it
does not resist a hostile program that constructs a descriptor by hand. See §8.

## 7. Diagnostics Contract

Per AGENTS.md §4.2 and spec §5.2, no instruction failure is reported as a bare
hexadecimal code. Every failure produces a sentence naming the instruction, the
operands, and what was expected.

Diagnostics are values, not exceptions: the VM returns a `Diagnostic` through the
normal call path, and the CLI prints it. Zig error returns may carry control flow, but
the user-visible text is always plain language. A test must assert that the rendered
text contains no `0x`-only error string and that it names the offending operand.

## 8. Fidelity Ledger

This project describes a chip that does not exist. Everything in the simulator is a
model, and the model's limits must be stated in code, not hidden.

| Area | Status | What is actually implemented |
|------|--------|------------------------------|
| Registers, memory, ALU | **Executable model** | Real behaviour, fully tested. |
| `stream.*`, `select.*`, `field.*` | **Executable model** | Real behaviour, fully tested. |
| Capability checks | **Software model** | Bounds and permission checks only. Not cryptographic, no tag bits, no unforgeable provenance. |
| SMT-8 threads | **Interleaved software model** | Deterministic interleaving with private register files. Not parallel, not zero-cycle, not real simultaneous multithreading. |
| `matrix.*`, `fft.*`, `codec.*` | **Functional model** | Correct results computed in software. No hardware acceleration, no cycle claims. |
| RTL / FPGA (Phase 4) | **Lint-verified specification + simulation** | RTL in `rtl/` passes `verilator --lint-only -Wall --top-module core` over the whole tree, and runs in Verilator testbenches. The `--top-module core` is required: without it `MULTITOP` and per-module `UNUSEDPARAM` make any multi-file invocation fail regardless of code quality, so the bare command above is NOT the one that passes. One `UNUSEDSIGNAL` is suppressed in `core.sv` with a reproducible justification (a Verilator false positive on packed structs). Now synthesized via `sv2v` + Yosys (`zig build synth`; cell counts in `docs/STATUS.md`). Still **not** timing-closed, not placed or routed, never placed on real silicon, and no clock frequency is claimed. A cell count is not a timing result. |
| Cycle counts / benchmarks | **Advisory** | Simulator instruction counts. They are not a performance claim about silicon and must never be presented as one. |

A module whose behaviour is modelled must say so at the top of the file. A benchmark
that reports a number must print the word "simulated". Claiming silicon performance
this repository cannot measure is the one failure mode that makes the whole project
worthless.

## 9. Versioning

This document is the interface between the assembler, the decoder, the VM and the
disassembler. Any change to §2–§5 requires updating all four plus the tests in the
same change. Encoding changes are not a refactor.

| Version | Date | Change |
|---------|------|--------|
| 1.0 | — | Initial normative layout, §1–§9. |
| 1.1 | 2026-11-08 | §3.6 accelerator operand layout made normative (was deferred to model modules) and 13 operations assigned fixed opcodes. §3.7 zero slot mask defined as legal and round-trippable. Closes the assembler round-trip gap on `0x60`–`0x8F` and mask-0 `0x90`–`0x92`. |
| 1.2 | 2026-11-08 | §3.1 immediate diagram corrected: `imm28` is bits `[27:0]`, not `[39:0]`. The diagram and the prose contradicted each other (40-bit drawing vs "signed 28-bit" name). The name wins, matching `assembler.zig`'s range check and `decoder.zig`'s `u28`. Bits `[39:28]` are now explicitly reserved-zero. Found by `rtl-core` while cross-checking the RTL against `decoder.zig` — the RTL had implemented the diagram and diverged from the simulator on every immediate with a bit in `[39:28]` set. |
| 1.3 | 2026-11-08 | §3.2 `operand[35:0]`, §3.3 and §3.4 reserved fields now state their rejection rule explicitly, matching §3.6 — "reserved" means rejected when set, not ignored. Removed a stale §2 sentence claiming a "wide immediate form" that §3.1 never defined and no implementation has. All six operand layouts audited and confirmed to sum to exactly 48 bits. |
| 1.4 | 2026-11-08 | Four contract defects found by `verifier` under task-15. (a) §3.1's `zero[39:28]` reservation was stated as a global fact but `stream.setp` (§3.4) legally uses those same bits for its 40-bit stride; reservations are now explicitly scoped per instruction class, and §3.4 notes the deliberate overlap. (b) §6 claimed `length` is 64-bit "stored in `permissions[23:0]`" - impossible, and no such packing exists; the line described an implementation never written and was removed. (c) §3.7's operand order was ambiguous; slots-first is now stated explicitly, matching the disassembler's round-tripping output, and `thread.yield` is documented as taking no operand. (d) §2's phantom "wide immediate form" was removed in 1.3. Outstanding: the ALU reserved-bit check required by (a) is NOT yet implemented - see item F6. |
| 1.5 | 2026-11-08 | §4's two sentences about `PC` contradicted each other: the index table called writing it "a diagnostic error outside jump forms" while the paragraph below called index 12-15 in `rd` "legal". `add PC, R1, R2` is both. Resolved by separating *encodable* from *meaningful*: the encoding is well-formed, but the fixed 8-byte advance discards the result, so `PC` as a destination errors for that reason, not for illegality. §4's deleted FLAGS-as-zero sentence (F9) also removed. Wording from `core-vm`, who hit the collision while implementing the fault. |
| 1.6 | 2026-11-08 | §3.7's thread slot mask was declared as `operand[4:0]` - FIVE bits - in every revision through 1.5, while the architecture has EIGHT slots `T0`-`T7` and the code has always used a `u8`. The contract could not express its own slot range. `thread.spawn T0-T7` encoded to `operand=0xff`, making `operand[47:8]` non-zero, which the immediately preceding reserved-bits rule declared illegal - the section forbade the word its own slot range required. Corrected to `operand[7:0]`, reserved region `operand[47:8]`. Invisible until F7's abort was fixed: the abort masked the malformed word. Found by Lead arithmetic check, not by a test - no test asserted the mask's bit position. |
| 1.7 | 2026-11-08 | Two undocumented ranges closed, both flagged by `tooling` during a bit-position audit and deliberately left unimplemented by them because no reservation was declared - correct restraint. (a) §3.3 `field.*` left `operand[27:0]` unmentioned; now reserved, must be zero. (b) §3.0 marked only `nop`/`halt` as "must be zero", implying `jump`/`call`/`ret` were unconstrained; their `rd`/`rs1` are now explicitly unused-and-must-be-zero. F10 addressed: §6's reserved permission bits claimed a diagnostic that does not exist and could not - `Perms` is constructible only via named fields and `_reserved` defaults to 0, so a non-zero value is unreachable. The contract now states the reservation AND the absence of enforcement rather than describing a path that was never written. Also: F11 stale `operand[4:0]` in Amendment 1.1 corrected to `operand[7:0]` (`verifier`), and the §8 RTL row now names the exact lint command including `--top-module core` instead of a bare `--lint-only -Wall` that does not actually pass (`verifier`). |
| 1.8 | 2026-11-08 | F10: §6's reserved permission bits no longer claim a diagnostic that cannot fire. |
| 1.9 | 2026-11-08 | §3.3's `field.insert` textual form stated explicitly (`offset`/`width` named, `src2` trailing). The contract showed only `field.extract` and left `insert`'s order inferable; `tooling` flagged the oddity and the form is frozen rather than reordered, because it round-trips and reordering would invalidate every existing `.dis` file. Same resolution as slots-first and `thread.yield`: the doc was ambiguous, the round-tripping behaviour wins. |
| 1.10 | 2026-11-08 | §3.4's element-width field now states its DEFAULT and where the suffix attaches. The field was named but never defaulted, and the syntax line itself shows no suffix, so the common case was undefined. Ruled: **no suffix = width 0, full 64-bit elements**, matching §5 and every word this repository has ever encoded. Also fixed: the suffix belongs on the element register (`stream.add R0.w, ...`), not the pointer or offset register. Triggered by `rtl-core2` finding that the assembler never parsed the field at all, so a `.w` was silently discarded. |
| 1.11 | 2026-11-08 | §3.5 never defined an operand layout, and the assembler and decoder diverged over it. `runCapability` accepted three registers while `Cap` holds two, so `cap.load R2, R3, R4` assembled with `R4` silently discarded — defect F12, third of the F1/F8 class. Ruled: `rs2` and `operand[47:0]` are reserved-zero, and the descriptor's pair is named by `rd`/`rs1` alone, which must be even or two neighbouring descriptors overlap. `cap.load`/`cap.store` stay decode-only and must refuse loudly: the encoding has no address field and inventing one (a third register, or the pair holding the address) would contradict §6. `cap.check` is fully determined and must execute. Found by Lead during recon for the dispatch-wiring task, not by any test — the operand was accepted, so nothing failed. |
| 1.12 | 2026-11-08 | **Corrects 1.11 on the day it was written.** 1.11 claimed `cap.check` "is fully determined and must execute". That was false, and `core-vm` disproved it by implementing it (defect F13, Lead's error). §6's pair yields `base` and `perms` only — `length` has **no bit position in the pair**, as §6's own v1.7 note already recorded for the deleted `permissions[23:0]` claim — so a `Capability` cannot be reconstructed and `Capability.init` rejects a zero length. Worse, `check(address, size, access)` needs three inputs and the encoding `(op, rd, rs1)` supplies none, and **"capability access status" is defined nowhere in the repository** (one grep hit: the §3.5 table row). All three `cap.*` opcodes are now decode-only, refused with a diagnostic instead of a fabricated value. The recurring shape: Lead ruled a thing "fully determined" without checking that the inputs it needs exist. |
| 1.13 | 2026-11-08 | **F14, and a correction to the Lead's diagnosis of it.** 1.11's even-index rule was implemented as "**both** registers must be even", gated on `op != .cap_check`, which rejected **legal** instructions: `cap.load R2, R3` and `cap.store R3, R2` both refused, though in each only the pair-naming register must be even. Fixed so the rule applies to exactly one register — `rd` for `cap.load`, `rs1` for `cap.store`. The test that should have caught it used only even `rs1` values in its positive controls, so "both must be even" was invisible; the same false-negative class, in the negative direction, also left `cap.load R2, R5` asserting rejection of a legal word. **Lead's diagnosis of the secondary wrong-operand blame was wrong and `tooling` corrected it:** the task claimed the `rd` even-index check fired first on `cap.load R2, R3, R4`, but `rd` is `R2` — even — so it could not have fired; the blame came from F14's `rs1` over-reach itself. The check reordering is defensive hardening only and is observable solely when the pair register is odd *and* a surplus operand exists (`cap.load R3, R2, R4`). Recorded because a wrong root cause in a task description is how a fix gets aimed at the wrong layer. |
| 1.15 | 2026-11-08 | **F19-F30: twelve defects found by a differential fuzzer**, not by reading. `tests/roundtrip_fuzz.zig` fuzzes the contract's own `asm -> dis -> asm` byte-identity claim over 20,000 generated words. **Seven are one defect** (F20, F21, F22, F23, F25, F26, F29): a field the encoder writes but the renderer never names, so the assembler re-creates it as zero and the loss is silent at exit 0. F21 is the sharpest - two distinct words render to identical text and one is rewritten into the other. **Four share the F8 shape** (F24, F27, F28, F30): the decoder accepts what the assembler refuses, and `run-bin` executes it. F27 is a self-contradiction in this document - §4's table calls `PC` "readable" while the paragraph beneath calls it "a diagnostic error". F30 is F6 repeating for `compare`: §3.2.1 reserves `operand[35:0]`, but `0x20` is routed through the ALU check on `[39:28]`, so `[27:0]` is enforced by nothing. F19 is a genuine gap in §3.4 (`stream.setp` uses neither `rs1` nor `operand[47:40]` and requires neither to be zero). **No section text is amended by this row** - it records findings and their reproducing words; the normative fixes are still outstanding *as of this row*. **Superseded by 1.16**, which closes them; read that row for the fixes and for two corrections to the findings recorded here (F30 retracted, F29 re-attributed). Also recorded: this repository has **two encoders** (`Instruction.word()` in `assembler.zig` and `encode()` in `decoder.zig`), which agree with each other and both contradict §3.2.1. |
| 1.14 | 2026-11-08 | **F15 (finding).** §3.5 reserves `operand[47:0]` for `cap.*` and §7 requires a diagnostic for a non-zero reserved value, but the **decoder does not enforce it**, so a hand-built or loaded image carries the bits through silently — `0x5023400000000000` disassembles as `cap.load R2, R3`, exit 0. Every other class rejects its own reservation through the decoder (`thread.*` §3.7, and the §3.6 accelerator `reserved[39:32]`); `cap.*` is the only exception. The assembler refuses to *emit* such a word, but the assembler never sees a blob, and blobs are the primary input of `run-bin` — the same "the assembler is not the only entry point" reasoning that produced the VM half of F8. `cap.*` is also absent from `tools/audit-reserved.sh` in both halves, presence and falsification, which is why the gap survived this long. **Status at the time of writing: the decoder check and the audit entry were both still outstanding (task-24); this row records the defect, not a fix.** |

| 1.16 | 2026-11-09 | **F19–F30 fixed, and two findings corrected.** Every defect recorded in 1.15 is now closed in code, on both layers where a layer existed to close. **The seven field-loss defects (F20, F21, F22, F23, F25, F26, F29) are one fix:** a word whose mnemonic cannot name every bit it carries is rendered as `.raw opcode, operand, rd, rs1` and re-assembled exactly, instead of dropping the unnamed field. `.raw` is consequently no longer restricted to the accelerator range 0x60–0x8F — that restriction made the fallback unassemblable, which is worse than the loss it replaced. **F19** closed by making §3.4 explicit: `stream.setp` names its pointer with `rd` and reserves `rs1` and `operand[47:40]`; the decoder and the assembler both reject violations. **F24** (`offset + width <= 64`, §3.3.1), **F27** (§4: `PC` in `rs1`/`rs2` is a diagnostic error) and **F23** (§3.7: `rs1` is defined for `thread.spawn` only) are now enforced **in the decoder as well as the assembler** — all three shared the F8 shape, where a rule enforced only at assembly time is unenforced on the `run-bin` path. **Two findings in 1.15 were wrong and are corrected here, not overwritten.** (a) **F30 is retracted:** it claimed §3.2.1 reserves `compare`'s `operand[35:0]`, but §3.2.1 states no bit layout at all — it defines only the status enum. `compare` correctly follows §3.1's ALU layout, and the recorded word `0x20D1600000000800` is handled correctly (`zero[39:28] = 0`, `imm28 = 0x800 = 2048`); nothing is dropped. (b) **F29 was misattributed:** it recorded a lost `trueReg`, but the lost field is the **§5 width suffix**, which `compare`'s renderer never emitted (`0x201D830000000000` → `...80...`). Fixed by emitting the suffix, and the assembler now parses it. **F28 is correct behaviour, not a defect:** `cap.load R7, R5` has a zero operand and decodes legally; only the assembler's §3.5 even-index rule refuses the odd `rs1`, and the decoder accepting a well-formed word from a blob is right. **A further VM defect was found while fixing F19:** `vm.zig`'s `stream.setp` wrote `rs1` instead of `rd`, so the instruction updated R0 and left the named pointer untouched — invisible while a test fixture set `rs1` by hand. **Also fixed:** a test fixture encoded the `setp` stride as `@bitCast(@as(i48, -16))`, sign-extending into the reserved `operand[47:40]` and producing `0xFFFFFFFFFFF0` — a word the assembler never emits. Verified: 39/39 build steps, 452/452 tests, all four cross-check programs byte-identical, fuzzer `checked=11592 identical=11592` with rejections up from 1669 to 3923 and no loss of round-trip fidelity. |

| 1.17 | 2026-11-09 | **Three instructions added: `branch` (0x05), `load` (0x1A), `store` (0x1B).** Every revision through 1.16 defined `jump`, `call` and `ret` — **all unconditional** — and nothing else, so the ISA **could not express a loop**. Not inefficiently: not at all. The consequence was visible in two places already recorded as defects: `benchmarks/bench.zig`'s "element-by-element loop" was unrolled by the **Zig generator at build time** because the ISA had no way to express the loop, and F32's two "shapes" were one instruction at two chunk sizes because no second shape could be written. Likewise the only memory-touching opcodes were the fused `stream.*` engine and the decode-only `cap.*`, so a single-element fetch-modify-write was **not expressible** — `mov R5, [R4]` was rejected. **`branch` (§3.0.1)** tests the status enum `compare` already produces, so no flags register is introduced and the branchless-predication design is unchanged; its offset is a signed 28-bit displacement **relative to the branch itself**, not the absolute `imm48` that `jump`/`call` use, because a compiler can emit a relative offset for a forward reference without knowing the final layout. **`load`/`store` (§3.1.1)** are the scalar counterpart to the fused engine, inheriting §3.1's operand layout with `rs1` as the base and a signed 28-bit displacement; they do **not** post-increment, because auto-increment belongs to the stream engine and a scalar access that moved its own base would be unusable for random access. **Four defects were found while implementing this, three by the round-trip fuzzer within one run:** (a) the assembler's `.control` encoder arm handled only `jump`/`call`, so `branch` assembled to operand 0 — a branch testing EQUAL against offset 0 that fell through, making **every loop run forever**; (b) `branch`'s width nibble was first specified as "checked for validity but not used", which the fuzzer disproved by round-tripping a word through an encoder that dropped it — a field that is *validated* but *dropped* loses four bits silently, the F20–F26 class, so it is now reserved-and-rejected; (c) the decoder accepted a branch offset that is **not a multiple of 8**, which the assembler refused, so a blob could branch into the middle of an instruction — the F24/F27 two-layer shape; (d) `load`/`store` accepted a surplus third operand and silently discarded it, the F12/F19 class. All four are fixed and pinned by tests. Verified: 556/556 tests, fuzzer `checked=11839 identical=11839` (up from 11592), a real loop summing 8 loaded elements computes 180 in 63 instructions, and the new instructions round-trip byte-identically. |

The Phase 4 RTL consumes §2–§5 directly, so an encoding change now invalidates the RTL
and its testbench as well as the four software components above.

| 1.18 | 2026-11-09 | **§3.6 gains its missing operand arithmetic (amendment 1.18), closing F36's contract half: ELEVEN of thirteen accelerators now execute, TWO stay refused.** Amendment 1.1 fixed which *field* holds which operand and stopped there, so `docs/STATUS.md` F36 recorded that the contract named a matrix with no dimension, an output buffer with no address, and a `count` with no source and no unit — and both the simulator and the RTL correctly refused all thirteen rather than invent one. **No bit layout changed and no field was added**; the amendment works within `rs2`/`rs3`/`reserved`/`count` and says so explicitly. Rules added: (A) an operand register named as an address holds the **address value**, not an index, with exactly two exceptions — the two matrix-header forms that read a register as `rows:u32 | cols:u32`; (B) matrix data is row-major `f64`; (C) `codec.compress`'s output goes to a **normative fixed 256-byte workspace at byte 65 280**, whose availability is a **CHECKED PRECONDITION** — an image under 65 536 bytes refuses with a sentence naming the address and length, touching no byte; (D) **§3.6 line 490's "derive the count from the destination register" is RETRACTED IN PLACE at line 490 and superseded for every operation** — `count = 0` is a diagnostic error wherever the operation needs a length, because reading `rd` as an input count names one register as both input and output and imposes an unstated calling convention; (E) a per-operation table giving every address, every dimension source, every output and every unit, with **redundant operands required to be zero rather than ignored**; (E.6) `fft.ntt`'s `rs2` is reserved-zero because the model takes no modulus parameter, so accepting one and ignoring it would be the F34 "validated but dropped" class. **The dimension decision is the load-bearing one:** `matrix.det` takes `n` from `rs3` (its `rs1` is the matrix address and `rd` receives the scalar result, so `rs2` and `rs3` were the only free fields); `matrix.invert` takes `n` from `rs2` because its `rs3` is needed for nothing else while `rs1`/`rd` are the input and output addresses; `matrix.identity` takes its order from `rs1` and requires `count = 0`, since making `count=N` the order was the only spelling the old table allowed and it was self-contradictory. `matrix.transform`'s rigid-body `m` is at the address in `rs2`, the only free field on that row. **TWO rows remain refused, and each for a stated reason that is not a missing constant.** (a) **`matrix.mul` (0x62)** needs *three* addresses and *two* orders — five inputs for four fields. Reading an order from `count`, deriving the product's address from an input's extent, and aliasing one matrix's header into another's data were each considered and rejected (Rule E.5); the honest fix is a second opcode, which an amendment that does not change the encoding may not add. (b) **`codec.decompress` (0x81)** needs an `out.len` bound, all five fields are spoken for on its row, and reusing `compress`'s 256-byte workspace would silently reject valid inputs whose decompressed form exceeds 256 bytes — a narrowed domain, not a missing number (Rule E.1). **A correction to this row's own first draft, kept rather than overwritten:** it claimed Rule C's workspace sits in "the 64 KiB image every execution entry point allocates". That was **false** — `src/crossarch.zig:42` allocates 4 672 bytes, `src/examples.zig:73` 20 480, and `Vm.init` accepts any slice, so 65 536 is a CLI convention and not a machine property. Rule C now states the precondition and the small-image refusal mode instead of assuming it. Verification is recorded in `docs/STATUS.md` F36's closing entry; CLS64 has no LLVM backend, so every word quoted for these operations is checked against this repository's own decoder and encoder pair, which is self-consistency and not independent verification. |
| 1.19 | 2026-11-09 | **A fourteenth accelerator opcode: `matrix.mulout` (0x65), which EXECUTES; `matrix.mul` (0x62) is untouched and still refuses.** Amendment 1.18 declined to invent a matrix-multiply convention and was right to: its word has three addresses to name and could carry only two, and picking a rule for the two missing orders would have produced a plausible wrong matrix. **This amendment does not relax that refusal.** It adds a second opcode for the case where the fields genuinely suffice, because **the orders do not have to be in the word** — each matrix carries its own `rows:u32 | cols:u32` header in memory, which is Rule A's header form that 1.18 already defined. So `0x65` needs only the three **addresses** (`rd` = product, `rs1` = A, `rs2` = B), which fit the existing layout exactly, with `rs3` and `count` required to be zero by Rule E's redundant-operand rule. Rule E.7 states the whole operation: all three addresses are Rule A **address values** and must be 8-byte aligned; the product's header is **WRITTEN** as (`A.rows`, `B.cols`) and is the one header in §3.6 the operation does not read, so a product is itself a valid input; `a.cols` must equal `b.rows` or nothing is written; a side is `1..16`, and that limit is the fixed `[256]f64` accumulator `matrix.multiply` uses to stay allocation-free (Rule E.4), **not** a machine or timing statement — a larger matrix refuses with a sentence rather than truncating; every header and data region is bounds- and alignment-checked before the first byte is touched (Rule E.3), a header in bounds whose declared data would overflow being refused from the header's own numbers; and `rd` is **not** rewritten, because this row's result is entirely in memory and Rule E.2's reinterpretation has nothing to carry. **The rejected alternative** was to read `count` as a shared square side: it narrows the operation to square products and still does not say which input is on the left, which is precisely the ambiguity that made `0x62` unusable. Rule E.5 gains a note beneath its original text rather than a rewrite: the "second opcode" it predicted now exists, but not as one opcode per operand order, and `0x62` is not re-routed. Verified end to end through the CLI (`asm` -> `run-bin`) against a product computed independently in Python — `[[1,2,3],[4,5,6]]` times `[[7,8],[9,10],[11,12]]` equals `[[58,64],[139,154]]` — with the program loading every element back and halting only when all four match, plus tests for a dimension mismatch, an out-of-bounds header, an out-of-bounds data region, a misaligned address, non-zero `rs3`/`count`, a zero and an oversized side, and a test pinning that `0x62` still refuses. CLS64 has no LLVM backend, so these words are checked only against this repository's own decoder and encoder pair: that is self-consistency, not independent verification. |

| 1.20 | 2026-11-09 | **§3.6 now names the layer that refuses a reserved accelerator opcode (amendment 1.20, resolves F37). NO ENCODING CHANGED: no bit moved and no opcode was added.** F37 recorded that `decoder.decode` accepts every byte in `0x60`-`0x8F` as `.accelerator` with no §3.6 registry lookup, and offered two readings — teach the decoder the registry and return `.err`, or reword §3.6 so the **simulator** refuses. **Only the second survives contact with the rest of the contract**, and the deciding evidence was already in the tree: `src/disassembler.zig:552` is a passing, load-bearing test, *"a RESERVED accelerator opcode round-trips as raw bytes, not as a neighbour"*, which requires `decode` to return `.ok` for a reserved byte, because the disassembler reaches its `.raw` fallback **only** through the `.accelerator` arm (`src/disassembler.zig:109` into `accelerator`, `117-125`). Rejecting in the decoder breaks that test and contradicts clause 2 of §3.6's own sentence. **The three clauses are now stated normatively and each is assigned a layer:** (1) a reserved opcode **decodes** as an accelerator instruction with an unrecognised operation, and `decoder.decode` **must not** be changed to reject it; (2) it **round-trips as raw bytes** (`.raw`) keeping every bit; (3) the **simulator refuses it at execution** — a fault, not a decode error — with a diagnostic naming the byte and never reinterpreting it as a neighbour. **Part of F37 is retracted in place:** it filed the decoder's behaviour as the *F8 shape* ("a rule enforced in one layer while another path reaches the same input ungoverned"). That framing was wrong — no rule was bypassed, because §3.6 never required a decode error. The decoder is the governed path doing what clause 1 specifies; what was missing was a statement of **which layer owns the refusal**, and that ambiguity is what made the decoder look ungoverned. Pinned in two places that must agree: a new test in `src/decoder.zig` ("F37 / amendment 1.20") plus a comment at the `.accelerator` arm recording that the absent registry lookup is deliberate, alongside the existing `src/vm.zig:3141` test for the simulator half. **Load-bearing, proven by mutation in a throwaway copy, never the shared tree:** making the decoder return `.err` for `0x6F` — exactly the rejected option — makes the new test fail with `reached unreachable code` and the test process abort. **What may not be said:** that a reserved opcode is rejected at decode time. It is not, and this amendment says so. |

| 1.21 | 2026-11-09 | **The RTL is brought level with the contract, closing F40 — no encoding changed.** Amendment 1.19 added a fourteenth §3.6 opcode, `matrix.mulout` (0x65), to the contract and the simulator and touched nothing in `rtl/`, so `rtl/pkg/celeris64_pkg.sv`, `rtl/accel.sv` and `rtl/tb/core_tb.sv` still encoded the 13-opcode table: 13 recognised / 35 reserved against the contract's 14 / 34 for the 48-byte range `0x60`-`0x8F`. **The testbench did not merely omit 0x65 — `check_recognised_table()` asserted it must raise `unknown_op`**, the opposite of the contract. **The decision, and why it went this way:** the RTL is uniformly **decode-only** for every accelerator, because §3.6 calls these operations a software model and `rtl/CROSSCHECK.md` §4/§5.7 records that choice deliberately. So 0x65 is **recognised and raises `not_implemented`** exactly like the other thirteen, and **no matrix datapath was built** — the alternative, giving one accelerator a datapath and not the rest, was rejected as uneven and as the thing the previous session explicitly warned against. Changed: `OP_MATRIX_MULOUT = 8'h65` in the package; the opcode added to `accel.sv`'s exhaustive `unique case`, whose header comment had named 0x65 as its example of a *reserved* byte and now explains the decode-only choice instead; and the testbench table widened from `b <= 8'h64` to `b <= 8'h65`. **Verified by running, both directions, and the BEFORE state is the load-bearing evidence:** before the fix the testbench **passed, 159/159, exit 0**, printing `all 13 normative opcodes recognised (13), 35 reserved rejected` — it called 0x65 reserved because the testbench itself encoded the old table, so the check written to catch this disagreement could not see it. That is the **F31 shape**, a green gate hiding a disagreement, and it is why this was recorded rather than repaired quietly. After the fix it prints `all 14 normative opcodes recognised (14 observed), 34 reserved rejected`, still 159/159, exit 0. Removing 0x65 from `accel.sv` in a throwaway copy makes it **fail** with `expected 14 recognised / 34 reserved, got 13 recognised and 35 reserved`, failures=1, exit 1 — proving the corrected table is load-bearing. **A second defect was found and fixed in the same task:** the closing `$display` printed `ok` and the **expected** count unconditionally, so under mutation it emitted a passing line beside the failure; it now counts what the RTL **actually** reports, separately from what the test expects, and prints `ok` only when the count is right. No timing, area, frequency or silicon claim is made or implied anywhere — the RTL is synthesised but never timing-closed and never on silicon, and it remains decode-only for all fourteen accelerators. |
