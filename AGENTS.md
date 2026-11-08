# AGENTS.md — Celeris-64 (CLS64) Development Mandate

## 1. System Vision & Primary Objectives

Celeris-64 (shorthand: CLS64) is a 64-bit scalar architecture engineered from first principles around Data-Oriented Design (DOD), minimal abstraction, and extreme information density. It eliminates out-of-order execution complexity and web-stack runtime overhead, replacing them with deterministic, interrupt-free, zero-copy memory stream processing.

All AI agents operating in this repository must strictly adhere to the architectural invariants, memory models, and coding standards set forth in this document.

## 2. Core Architectural Invariants

1. Registers & Sub-Register Slicing:
    - General Purpose: `R0` through `R11` (12 orthogonal 64-bit containers).
    - System Registers: `ZERO` (hardwired to 0), `PC` (Program Counter), `SP` (Stack Pointer), `LR` (Link Register), `FLAGS` (Carry/Overflow/Status).
    - Sub-Width Addressing: Explicit width suffixes (`.l` for 32-bit, `.w` for 16-bit, `.b` for 8-bit). Writing to a sub-register automatically zero-extends upper bits to prevent partial-register stall dependencies.
2. Byte Ordering: Strictly Little-Endian to support zero-cost bitfield slicing and type narrowing without byte-swapping penalties.
3. Memory Model: Flat, continuous 64-bit virtual and physical memory space modeled as a dynamic byte slice (`[]u8`). Legacy segment registers, page-table windowing, and TLB-invalidating bank switches are strictly prohibited.
4. Hardware SMT: SMT-8 thread slots (`T0`–`T7`) per physical core. Thread contexts manage private register arrays while sharing core-level L1/L2 caches to allow zero-cycle thread switching on DRAM latency.
5. Memory Safety: Integrated CHERI capability pointers (128-bit descriptors holding base, length, and cryptographic access permissions).

## 3. Dedicated Hardware Primitives

1. Stream Engine (`stream.*`): Hardware-managed vector/scalar auto-incrementing memory loops without explicit software loop indices or pointer arithmetic overhead.
2. Branchless Masking (`select.*`): Conditional evaluation executed as hardware bitwise selection masks using explicit status enums to eliminate branch mispredictions.
3. Bitfield Slicing (`field.*`): Single-cycle inline packing and unpacking of arbitrary non-power-of-two domain values (e.g., `U1`, `U3`, `U5`) without manual bit-shifting or mask boilerplate.
4. Matrix Accelerators (`matrix.*`): Direct hardware execution of linear algebra routines (inversions, determinants, linear transformations) on continuous Structure-of-Arrays (SoA) memory streams.

## 4. Coding & Architecture Standards (Zig Engine)

1. Memory Allocations: Zero dynamic allocations inside execution loops. All buffers and state memory must be allocated upfront during virtual machine initialization.
2. Error Handling & Diagnostics: Exceptions, hidden unwinding, and bare hexadecimal error codes (e.g., `0x0000005`) are forbidden. Diagnostics must output explicit, plain-language, human-centric explanations.
3. Register Spilling: Overusing general registers (`R0`–`R11`) past capacity must trigger clean diagnostic warnings during assembly or simulation.

## 5. Directory & File Structure

```txt
celeris64/
├── build.zig                 # Zig build system configuration
├── src/
│   ├── main.zig              # CLI entry point and binary loader
│   ├── vm.zig                # Core virtual machine & fetch-decode-execute loop
│   ├── registers.zig         # R0–R11, ZERO, PC, SP, LR, FLAGS definitions
│   ├── memory.zig            # Flat byte-array unified memory model
│   ├── decoder.zig           # Opcode decoder & field.* bitfield extraction
│   ├── stream.zig            # stream.* processing logic
│   └── diagnostics.zig       # Plain-language error reporting engine
└── tests/
    └── vm_tests.zig          # Complete integration and unit test suite
```
