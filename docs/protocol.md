# Synthetic FTE1 wire protocol (version 1)

This is a single-instrument **synthetic ITCH-style protocol**. It is not native
NASDAQ ITCH, MoldUDP64, OUCH, or an exchange/broker gateway. All multibyte values
are unsigned big endian. Prices are integer multiples of $0.0001. One UDP
datagram carries exactly one command. No real orders are submitted anywhere.

## Network envelope

Ethernet II, destination MAC `02:00:00:00:00:01`, IPv4 destination
`192.168.1.128`, UDP destination 9000. Source IPv4 must be `192.168.1.1`.
IPv4 must have IHL=5, total length=76, protocol=17, valid header checksum,
zero fragment offset, MF=0 and reserved flag=0 (DF may be set).
UDP length must be 56. Receive accepts both a valid UDP checksum and zero
(legal for IPv4). Ethernet FCS, RX_ER, byte alignment and SFD are checked
before the parser sees a frame. RX accepts PHY-shortened preambles and aligns
payload bytes after SFD; TX always emits seven preamble bytes. Frames contain exactly 90
bytes from destination MAC through payload, excluding FCS; VLANs, IP options,
fragments, jumbo frames and other protocols are rejected. This length is above
Ethernet's padding threshold. There is no ARP/ICMP/DHCP stack: use a static
neighbor entry. TX uses a configured host MAC, fixed host IP/UDP port 9000,
valid IPv4 checksum and Ethernet FCS, and a zero IPv4 UDP checksum.

## Command payload: 48 bytes

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 4 | ASCII `FTE1` |
| 4 | 1 | Kind: `A`, `E`, `X`, `D`, `R`, `S`, `C` |
| 5 | 1 | Version = 1 |
| 6 | 2 | Reserved, zero |
| 8 | 4 | Nonzero session/epoch ID |
| 12 | 4 | Event sequence or control request nonce |
| 16 | 8 | Full order ID (zero is legal) |
| 24 | 4 | Quantity |
| 28 | 4 | Price |
| 32 | 1 | Side: ASCII `B`/`S` for Add, zero otherwise |
| 33 | 1 | Signal enable = 1 for enabled, other values disabled (`C` only) |
| 34 | 2 | Reserved, zero |
| 36 | 4 | Max spread in price units (`C` only) |
| 40 | 4 | Minimum quantity on **each** BBO side (`C` only) |
| 44 | 4 | Minimum absolute bid/ask quantity difference (`C` only) |

`A` adds a positive quantity at one supported grid price. `E` executes and `X`
cancels a positive quantity no larger than the live order quantity. `D` removes
the remaining order; its quantity is zero. All non-Add market events require
zero side and price. Unsupported event fields are rejected atomically by the
book. Control commands ignore order ID, quantity, price and side. Market events
ignore bytes 33 and 36–47. Reserved fields are always checked.

An `R` request requires sequence=0 and a session different from the current
one. It resets the FPGA order book, clears BBO, sets expected event sequence=1,
and returns `R`. Session IDs must not be reused for a replay. Strategy config
and lifetime counters survive an `R`; a board/link reset clears everything.

`C` changes strategy configuration and returns `C`. `S` requests a snapshot and
returns eight `S` packets. Their control nonce echoes the request sequence;
control nonces do not advance the market-event sequence. They should be fresh
for each control request. The host uses random 32-bit nonces.

## Telemetry common header: 128 bytes

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 4 | ASCII `FTET` |
| 4 | 1 | Version = 1 |
| 5 | 1 | Kind: `U` event result, `R`, `C`, or `S`; unknown command kind may echo on error |
| 6 | 1 | Flags: bit0 feed trusted, bit1 internal fault, bit2 bid valid, bit3 ask valid, bit4 BUY, bit5 SELL |
| 7 | 1 | Status (below) |
| 8 | 4 | Current FPGA session |
| 12 | 4 | Last consumed market-event sequence |
| 16 | 4 | Telemetry packet sequence, wraps modulo 2^32 |
| 20 | 4 | Echo of command event sequence/control nonce |
| 24 | 8 | Echoed order ID (meaningful for `U`) |
| 32 | 4 | Best bid price |
| 36 | 4 | Best ask price |
| 40 | 8 | Best bid aggregate quantity |
| 48 | 8 | Best ask aggregate quantity |
| 56 | 2 | Changed depth index: bids 0–255, asks 256–511; `0xffff` = none |
| 58 | 1 | Snapshot chunk 0–7; zero on other responses |
| 59 | 1 | Snapshot chunk count=8; zero on other responses |
| 60 | 8 | **Absolute** post-update aggregate quantity at changed index (zero removes level) |
| 68 | 4 | Latest accepted event's core input-handshake → signal accepted by telemetry controller, cycles |
| 72 | 4 | Consumed market events, including book rejections |
| 76 | 4 | Book rejections and unsupported commands |
| 80 | 4 | MAC bad FCS/truncation/RX_ER/alignment frames |
| 84 | 4 | MAC busy-mailbox dropped frames |
| 88 | 4 | Parser rejected frames |
| 92 | 4 | Input sequence gap/duplicate/disabled-feed attempts |
| 96 | 8 | Core cycle counter (latched before packet assembly) |
| 104 | 4 | Configured max spread |
| 108 | 4 | Configured minimum BBO quantity |
| 112 | 4 | Configured minimum absolute quantity imbalance |
| 116 | 1 | Signal enable (0/1) |
| 117 | 2 | Configured core MHz (25, 50, 100 or 200), not a physical frequency measurement |
| 119 | 2 | Live-order capacity (default board profile 256; independent of 512 aggregate depth entries) |
| 121 | 7 | Reserved, zero |

Normal responses have 128-byte payloads. Snapshot responses have 640 bytes:
the common header plus 64 consecutive unsigned 64-bit quantities. Chunk `n`
covers depth indices `64*n` through `64*n+63`. The FPGA freezes all book updates
until all eight packets finish transmission. BBO, session and consumed event
sequence therefore identify the same snapshot. Individual counter samples and
packet sequence advance while the snapshot is transmitted.

BUY/SELL flags describe the individual `U` event decision. Control/snapshot
responses clear those flags and do not generate a new strategy decision. The
terminal labels the last known FPGA event decision explicitly. A snapshot that
recovers a missing event cannot recover that event's decision, so the terminal
shows AWAIT EVENT until another `U` arrives; it never recomputes a decision.

Statuses: 0=OK, 1=bad event, 2=duplicate active ID, 3=unknown ID,
4=capacity, 5=invalid reduction, 6=internal fault;
`f1`=wrong/zero session, `f2`=input sequence mismatch or
untrusted/faulted feed, `f3`=unsupported command or invalid same-session reset. A syntactically valid,
correctly sequenced event consumes its sequence even if the book rejects it.
Rejections leave the book unchanged and suppress that event's signal.

## Loss and recovery

The supplied sender uses one outstanding command and waits for its response.
The MAC cannot apply physical backpressure to Ethernet. An occupied mailbox
drops subsequent frames and increments a counter; it never overwrites a frame.
Telemetry is serialized through an acknowledged TX mailbox. No telemetry is
silently discarded internally to satisfy output backpressure.

1. Host starts with an untrusted display. After reset it requests `S`.
2. Publish depth only after chunks 0..7 arrive in order with identical session,
   event sequence, request nonce, and consecutive telemetry packet numbers.
   Incomplete, reordered, stale-session and wrong-nonce snapshots cannot publish.
3. Once trusted, apply absolute `U` level updates only in consecutive packet and
   event-sequence order. FPGA BBO and decisions are displayed directly.
4. A telemetry gap, missing final response or timeout makes the display stale;
   withhold depth and signals, request a fresh snapshot (three bounded attempts).
   Idle polling refreshes trust once a second. Duplicates and old datagrams are ignored.
5. After a lost event acknowledgement, the sender uses a snapshot to determine
   whether the FPGA consumed that event. It never blindly retransmits it. If the
   event was not consumed, stop and reset/replay the source file.
6. An input event gap or duplicate makes the FPGA feed untrusted and suppresses
   all subsequent input events. A display snapshot cannot reconstruct an event
   the FPGA never received. Start a new `R` session and replay from the beginning.
   Market event sequence wrap also requires a new session. PHY link loss resets
   the network/core and requires a fresh session.

This protocol assumes an isolated development LAN. It has no authentication,
retransmission log, multicast recovery service or exchange connectivity.
