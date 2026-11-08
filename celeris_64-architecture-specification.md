# Celeris-64 Architecture Specification & Technical Manifesto

Document Version: 1.0
Architecture Target: CLS64 (64-Bit Data-Oriented Streaming APU/Multi-Socket Engine)

## 1. Core Philosophy & Design Principles

Modern microarchitectures consume excessive silicon area and power masking inefficient software patterns. Celeris-64 bakes the axioms of Data-Oriented Design (DOD) directly into physical hardware and assembly primitives:

1. Data is the Problem, Hardware is the Reality: Execution structures must align with physical memory latency, cache-line width, and memory bus throughput.
2. Batch Processing over Element-by-Element: Single-element processing in inner execution loops is prohibited; memory is processed in continuous, contiguous streams.
3. Transformations over Abstractions: Program execution is modeled strictly as pure data transformation pipelines: Data in -> Data out
4. Branchless & Masked Control Flow: Control branches are minimized in favor of hardware predication, SIMD bitwise masks, and status-enum evaluation.
5. Elimination of Boolean Blindness: Program state is held strictly in strongly-typed hardware status enums and defined domain values.

## 2. Register Model & Memory Hierarchy

### 2.1 System & Control Registers

- `ZERO` — Hardwired to `0`. Reads always return zero; writes are ignored.
- `PC` — 64-bit Program Counter.
- `SP` — 64-bit Stack Pointer.
- `LR` — 64-bit Link Register (Function Return Address).
- `FLAGS` — Minimal carry, overflow, and condition status bits.

### 2.2 General-Purpose Registers

- R0 through R11 — 12 orthogonal 64-bit general-purpose data containers.
- Sub-Register Slicing & Zero-Extension:
    - `.l` — Low 32-bit view.
    - `.w` — Low 16-bit view.
    - `.b` — Low 8-bit view.
    - Writing to any sub-register automatically zero-extends the remaining upper bits to avoid micro-architectural register renaming stalls.

### 2.3 Memory Model & Capability Security

- Flat 64-Bit Virtual Memory Space: Full 64-bit virtual pointers enable flat streaming across exabytes of unified memory without page-table windowing stalls.
- CHERI Capability Integration: Pointers are 128-bit cryptographic capability descriptors holding base, length bounds, and permission flags. Out-of-bounds accesses trigger instant hardware traps without requiring runtime bounds-check code.

## 3. Hardware Primitives & Assembly Syntax

### 3.1 Stream & Batch Processing Engine (`stream.*`)

Registers auto-increment pointer bounds natively during batch execution loops:

```asm
# Fused Batch Add: Load chunk, apply offset, write back, auto-step pointer

stream.add R0, [R1]+CHUNK_SIZE, R2
```

### 3.2 Branchless Selection & Masking (select.*)

Eliminates branch mispredictions by resolving conditional logic via hardware bitwise selection:

```asm
# Syntax: select <dest_reg>, <mask_status_reg>, <match_val>, <true_reg>, <false_reg>

compare R0, R1 -> R2              # Populates explicit status enum in R2
select R3, R2, [EQUAL], R4, R5    # R3 = (R2 == EQUAL) ? R4 : R5
```

### 3.3 Packed Bitfield & Slicing (field.*)

Native packing and unpacking of arbitrary non-power-of-two domain types (e.g., U1, U3, U5):

```asm
# Extract a 3-bit domain value starting at bit offset 12

field.extract R0, R1, offset=12, width=3
```

### 3.4 Matrix & Acceleration Primitives (`matrix._`, `fft._`, `codec.*`)

- `matrix.*` — Direct hardware execution of linear algebra, matrix inversions, and rigid-body transforms.
- `fft.*` — Native Fast Fourier Transform and Number Theoretic Transform engines.
- `codec.*` — Direct hardware LZ/Zstd matching and cryptographic primitives at bus speed.

## 4. Hardware SMT & Multi-Socket Topology

    1. SMT-8 Core Architecture: Each physical core supports 8 hardware thread slots (`T0`–`T7`). Threads share core-level L1/L2 caches and execution units, permitting zero-cycle switching on memory latency stalls.
    2. Unified APU & Discrete Multi-Socket Scaling: Scalable target execution from single-chip mobile APUs to multi-socket server nodes via compiler hints (`@target:cpu`, `@target:gpu`).

## 5. Architectural Commitments & Ethics

    1. Full-Functional Chip Policy: 100% of manufactured functional units remain unlocked. Corporate feature disabling, fuse-locking, and artificial tier binning are strictly forbidden.
    2. Human-Centric Diagnostics: All error outputs emit structured, plain-language text instead of raw hexadecimal panic codes.
