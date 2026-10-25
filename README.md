# FPGA Low-Latency Trading Engine

Target board: Digilent Arty A7-100T
Toolchain: AMD Vivado 2026.1 on Windows

## Current status

Completed the Python order-book reference model supporting Add, Execute,
Cancel, and Delete events, price-level quantity aggregation, and best
bid/ask calculation.

All 13 Python tests passed, including a 10,000-event comparison against
an independent replay implementation. Generated reproducible CSV test
vectors with expected BBO results.

SystemVerilog implementation and FPGA hardware validation are pending.

## Planned behavior

A PC generates ITCH-style Add, Execute, Cancel, and Delete events and sends them over Ethernet/IPv4/UDP. FPGA logic decodes the events, updates a bounded BRAM-backed order book, tracks best bid and offer, and emits configurable trading signals. The initial feed is synthetic; transport framing and supported message formats will be documented before implementation.

200 MHz operation and below 250 ns decision latency are design targets, not measured results. Define measurement boundaries and include queueing behavior before reporting latency.



## Build sequence

1. Define decoded event interfaces and first-version capacity limits.
2. Implement the Python reference model and order-book RTL.
3. Verify BBO tracking and trading decisions.
4. Implement packet decoding and network error handling.
5. Integrate the Ethernet interface and board clocks.
6. Validate on hardware and record measured performance.

