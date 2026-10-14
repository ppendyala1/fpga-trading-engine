# Planned architecture

Receive PHY/MAC -> frame validation -> asynchronous FIFO -> IPv4/UDP parser -> ITCH-style decoder -> order book -> BBO -> trading signal.

The exact FIFO placement depends on the selected MAC interface and clock domains. Frame validation must prevent corrupt packets from changing committed order-book state.

## Decisions to settle before RTL

- Event interface and valid/ready handshake.
- Supported message framing and byte order.
- Active-order capacity, supported price range, and symbol filtering.
- Order-ID lookup, collision handling, and overflow behavior.
- BRAM read latency and consecutive-update hazards.
- Packet sequence gaps and invalid-book behavior.
- Latency boundaries, queueing, and output observation.
