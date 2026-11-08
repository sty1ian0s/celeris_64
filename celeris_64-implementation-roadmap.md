# Celeris-64 Implementation Roadmap

## Phase 1: Instruction Set Simulator (ISS) in Zig

Goal: Build a functional software simulator in Zig to execute Celeris-64 binaries, test custom stream primitives, and validate execution semantics.

### 1. Core Register File & Memory Engine:

- Implement `R0`–`R11`, `ZERO`, `PC`, `SP`, `LR`, and `FLAGS`.
- Implement flat byte-array memory (`[]u8`) supporting little-endian reads/writes and zero-extended sub-register updates (`.l`, `.w`, `.b`).

### 2. Specialized Hardware Primitives:

- `stream.*` auto-incrementing batch processing engine.
- `select.*` branchless status-enum selection masks.
- `field.*` arbitrary bitfield extractions (e.g., `U1`, `U3`, `U5`).

### 3. Execution Loop & Test Suite:

- Build in-order fetch-decode-execute loop in `src/vm.zig`.
- Implement `tests/vm_tests.zig` validating register immutability, stream bounds, and bit extraction.

## Phase 2: Human-Centric Diagnostics & Tooling

Goal: Make the Celeris-64 simulator transparent, accessible, and self-documenting.

### 1. Plain-Language Disassembler:

- Emit clear step-by-step disassembly showing register mutations and stream pointers in plain text.

### 2. Resource Spill Diagnostics:

- Explicit diagnostic notices when software attempts to spill past the 12 general-purpose registers (`R0`–`R11`).

## Phase 3: Architectural Benchmarking & Native Ecosystem

Goal: Prove performance advantages over legacy web and desktop stacks.

### 1. Comparative Benchmarks:

- Side-by-side assembly and memory usage comparisons against x86-64/ARM and web runtime stacks.

### 2. Native Standard Libraries:

- Provide lean native standard libraries for UI layout, graphics rendering, and networking.

## Phase 4: Hardware Realization (RTL & FPGA)

Goal: Translate the verified software simulator into physical hardware circuits.

### 1. RTL Specification:

- Write SystemVerilog / Verilator code mapping execution units, stream engines, and register files.

### FPGA Prototyping:

- Deploy logic onto FPGA hardware to evaluate real memory bandwidth and cycle performance.
