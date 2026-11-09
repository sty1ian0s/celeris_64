# Celeris-64 (CLS64) Instruction Encoding Contract

Document Version: 1.16
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
- `count[31:0]` — element or byte count, unsigned. `0` means "derive the count from
  the destination register", which is the form the assembler emits when no count is
  written.

Each operation names its operands positionally, exactly as the model signature reads:

| Opcode | Mnemonic | Operands | Model signature |
|--------|----------|----------|-----------------|
| `0x60` | `matrix.det`     | `rd, rs1`               | `matrix.determinant(m)` |
| `0x61` | `matrix.invert`  | `rd, rs1, rs2`          | `matrix.invert(m, out)` |
| `0x62` | `matrix.mul`     | `rd, rs1, rs2`          | `matrix.multiply(a, b, out)` |
| `0x63` | `matrix.transform` | `rd, rs1, count=N`    | `matrix.transformSoA(xs, ys, zs, m)`; the three streams are consecutive from `rs1`, `count` is elements **per stream** |
| `0x64` | `matrix.identity` | `rd, count=N`          | `matrix.identity(n, out)` |
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

Behaviour of these operations in the simulator is a **software model** and must be
labelled as such — see §8. The RTL in `rtl/` implements the same encodings; that shared
encoding is what makes cross-checking the two meaningful.

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

The Phase 4 RTL consumes §2–§5 directly, so an encoding change now invalidates the RTL
and its testbench as well as the four software components above.
