# FPGA Low-Latency Trading Engine

Target board: Digilent Arty A7-100T
Toolchain: AMD Vivado 2026.1 on Windows

## Current status

Repository scaffold only. RTL, Python tools, constraints, and Tcl scripts are comment-only placeholders. No functional tests, synthesis, timing measurements, or board runs have been completed. The scaffold is not yet a runnable Vivado project.

## Planned behavior

A PC generates ITCH-style Add, Execute, Cancel, and Delete events and sends them over Ethernet/IPv4/UDP. FPGA logic decodes the events, updates a bounded BRAM-backed order book, tracks best bid and offer, and emits configurable trading signals. The initial feed is synthetic; transport framing and supported message formats will be documented before implementation.

200 MHz operation and below 250 ns decision latency are design targets, not measured results. Define measurement boundaries and include queueing behavior before reporting latency.

## Folders

| Folder | Purpose |
| --- | --- |
| rtl | Synthesizable SystemVerilog source |
| tb | Self-checking SystemVerilog testbenches |
| tb/vectors | Reproducible test inputs and expected outputs |
| python | Reference model, event generation, and network replay |
| constraints | Board pin and timing constraints |
| scripts | Vivado project creation and simulation automation |
| docs | Architecture, decisions, and selected validation evidence |
| vivado | Local generated Vivado project, excluded from Git |
| results | Local generated test outputs, excluded from Git |

## Build sequence

1. Define decoded event interfaces and first-version capacity limits.
2. Implement the Python reference model and order-book RTL.
3. Verify BBO tracking and trading decisions.
4. Implement packet decoding and network error handling.
5. Integrate the Ethernet interface and board clocks.
6. Validate on hardware and record measured performance.

