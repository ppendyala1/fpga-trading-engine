"""FTE1 synthetic protocol and a fail-closed telemetry display cache.

The cache applies FPGA aggregate quantities; it never computes a book or signal
from market input. See docs/protocol.md for the network contract.
"""
from dataclasses import dataclass
import struct

COMMAND = struct.Struct('!4sBBHIIQIIBBHIII')
BASE_PRICE, TICK_SIZE = 1_500_000, 100


def command(kind, session, sequence=0, event=None, *, enable=True,
            max_spread=1000, min_quantity=1, min_imbalance=1):
    if kind not in 'AEXDRSC' or not 0 < session < 2**32:
        raise ValueError('Unsupported command or zero session')
    oid = event.order_id if event else 0
    qty = event.quantity if event else 0
    price = event.price if event else 0
    side = ord(event.side) if event and event.side else 0
    return COMMAND.pack(b'FTE1', ord(kind), 1, 0, session, sequence,
                        oid, qty, price, side, int(enable) if kind == 'C' else 0,
                        0, max_spread, min_quantity, min_imbalance)


@dataclass(frozen=True)
class Telemetry:
    kind: str
    flags: int
    status: int
    session: int
    sequence: int
    packet: int
    command_sequence: int
    order_id: int
    bid_price: int
    ask_price: int
    bid_quantity: int
    ask_quantity: int
    delta_index: int
    chunk: int
    chunks: int
    delta_quantity: int
    latency_cycles: int
    events: int
    rejects: int
    bad_frames: int
    dropped_frames: int
    malformed: int
    gaps: int
    cycles: int
    max_spread: int
    min_quantity: int
    min_imbalance: int
    enabled: bool
    clock_mhz: int
    capacity: int
    levels: tuple

    @property
    def feed_ok(self):
        return bool(self.flags & 1) and not bool(self.flags & 2)

    @property
    def signal(self):
        return 'BUY' if self.flags & 16 else 'SELL' if self.flags & 32 else 'HOLD'


def decode(data):
    if len(data) not in (128, 640) or data[:5] != b'FTET\x01':
        raise ValueError('Invalid telemetry framing')
    kind, flags, status = chr(data[5]), data[6], data[7]
    clock_mhz=int.from_bytes(data[117:119],'big')
    if clock_mhz not in (25,50,100,200):
        raise ValueError('Unsupported/missing configured clock')
    capacity=int.from_bytes(data[119:121],'big')
    if not 2<=capacity<=1024 or capacity & (capacity-1):
        raise ValueError('Invalid/missing FPGA capacity')
    if kind not in 'URSCD AEX'.replace(' ', '') or flags & 0xc0:
        raise ValueError('Unknown telemetry kind/flags')
    session, sequence, packet, echo = struct.unpack_from('!IIII', data, 8)
    oid, bp, ap, bq, aq = struct.unpack_from('!QIIQQ', data, 24)
    di, chunk, chunks, dq = struct.unpack_from('!HBBQ', data, 56)
    counters = struct.unpack_from('!IIIIIIIQIII', data, 68)
    # latency, events, rejects, bad, dropped, malformed, gaps, cycles, config*3
    if di != 0xffff and di >= 512:
        raise ValueError('Invalid depth index')
    if kind == 'S' and status == 0:
        if len(data) != 640 or chunks != 8 or chunk >= 8:
            raise ValueError('Invalid snapshot framing')
        levels = struct.unpack_from('!64Q', data, 128)
    else:
        if len(data) != 128 or chunks:
            raise ValueError('Unexpected snapshot data')
        levels = ()
    return Telemetry(kind, flags, status, session, sequence, packet, echo,
                     oid, bp, ap, bq, aq, di, chunk, chunks, dq,
                     *counters, bool(data[116]), clock_mhz, capacity, levels)


class DisplayBook:
    """Transactional snapshots; no incomplete or gapped book is shown as live."""
    def __init__(self, session):
        self.session = session
        self.levels = [0] * 512
        self.trusted = False
        self.reason = 'Waiting for FPGA snapshot'
        self.sequence = 0
        self.packet = None
        self.telemetry = None
        self.drops = 0
        self.snapshot_nonce = None
        self.pending = None
        self.decision = None
        self.decision_sequence = 0

    def invalidate(self, reason):
        self.trusted = False
        self.reason = reason
        self.pending = None

    def request_snapshot(self, nonce):
        self.invalidate('Synchronizing FPGA depth')
        self.snapshot_nonce = nonce

    def apply(self, t):
        if t.session != self.session:
            return False
        if self.packet is not None:
            distance = (t.packet - self.packet) & 0xffffffff
            if distance == 0 or distance >= 0x80000000:
                return False  # duplicate or old datagram
            if distance != 1:
                self.drops += distance - 1
                self.invalidate('Telemetry packet gap')
        self.packet = t.packet
        self.telemetry = t
        if not t.feed_ok:
            self.invalidate('Input sequence gap or FPGA fault: reset and replay required')
            return False
        if t.kind == 'S' and t.status == 0 and t.command_sequence == self.snapshot_nonce:
            key = (t.session, t.sequence, t.command_sequence)
            if t.chunk == 0:
                self.pending = (key, [], t.packet)
            if self.pending is None:
                return False
            old_key, values, first_packet = self.pending
            if old_key != key or len(values) != t.chunk * 64 or t.packet != (first_packet+t.chunk) & 0xffffffff:
                self.invalidate('Incomplete snapshot; requesting another is required')
                return False
            values.extend(t.levels)
            if t.chunk == 7:
                self.levels = values
                self.sequence = t.sequence
                if self.decision_sequence != t.sequence:
                    self.decision = None
                self.trusted = True
                self.reason = 'LIVE · FPGA telemetry'
                self.pending = None
                self.snapshot_nonce = None
            return self.trusted
        if t.kind == 'U':
            if not self.trusted or t.sequence != self.sequence + 1:
                self.invalidate('Event sequence gap; snapshot required')
                return False
            if t.delta_index != 0xffff:
                self.levels[t.delta_index] = t.delta_quantity
            self.sequence = t.sequence
            self.decision = t.signal
            self.decision_sequence = t.sequence
        return self.trusted
