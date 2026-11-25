"""Read and independently validate captured RTL Ethernet telemetry."""
from pathlib import Path
import struct
import zlib
from protocol import decode, DisplayBook


def checksum(data):
    if len(data) & 1:
        data += b'\0'
    total = sum(struct.unpack('!' + 'H' * (len(data)//2), data))
    while total >> 16:
        total = (total & 0xffff) + (total >> 16)
    return (~total) & 0xffff


def wire_payload(wire):
    if wire[:8] != b'\x55'*7+b'\xd5':
        raise ValueError('Bad TX preamble/SFD')
    frame=wire[8:]
    if zlib.crc32(frame[:-4]) != struct.unpack('<I',frame[-4:])[0]:
        raise ValueError('Bad TX FCS')
    data=frame[:-4]
    if data[:14] != bytes.fromhex('0200000000020200000000010800'):
        raise ValueError('Bad Ethernet header')
    ip=data[14:34]
    if checksum(ip) != 0 or ip[0] != 0x45 or ip[9] != 17:
        raise ValueError('Bad IP checksum/header')
    if ip[12:] != bytes([192,168,1,128,192,168,1,1]):
        raise ValueError('Wrong IP endpoints')
    length=struct.unpack_from('!H',ip,2)[0]
    if len(data)!=14+length:
        raise ValueError('Bad IP length')
    src,dst,ul,uc=struct.unpack_from('!HHHH',data,34)
    if src!=9000 or dst!=9000 or ul!=length-20 or uc!=0:
        raise ValueError('Bad UDP header')
    return data[42:]


def main():
    path=Path(__file__).resolve().parents[1]/'build/wire_telemetry.hex'
    records=[decode(wire_payload(bytes.fromhex(line))) for line in path.read_text().splitlines()]
    assert len(records)==41, len(records)
    assert [t.packet for t in records]==list(range(41))
    assert all(t.clock_mhz==25 and t.capacity==256 for t in records)
    assert records[0].kind=='R' and records[0].sequence==0
    for t,seq in zip(records[1:4],(1,2,3)):
        assert t.sequence==seq and t.status==0 and t.feed_ok
    assert records[1].order_id==(1<<60)+42
    assert records[1].bid_quantity==100 and records[1].delta_quantity==100
    assert records[2].ask_quantity==25 and records[2].signal=='BUY'
    assert records[3].bid_quantity==70 and records[3].delta_quantity==70 and records[3].signal=='BUY'
    book=DisplayBook(123);book.request_snapshot(99)
    for t in records[4:12]: book.apply(t)
    assert book.trusted and book.sequence==3
    assert book.levels[0]==70 and book.levels[258]==25 and sum(book.levels)==95
    assert records[12].status==0xf2 and not records[12].feed_ok
    for t in records[12:21]: book.apply(t)
    assert not book.trusted and records[20].gaps==1
    assert records[21].kind=='C' and not records[21].enabled
    assert (records[21].max_spread,records[21].min_quantity,records[21].min_imbalance)==(500,10,20)
    assert records[22].kind=='R' and records[22].session==124 and records[22].sequence==0
    book=DisplayBook(124);book.request_snapshot(100)
    for t in records[24:32]: book.apply(t)
    assert book.trusted and book.sequence==1 and sum(book.levels)==9 and book.levels[257]==9
    assert records[32].status==0xf2 and not records[32].feed_ok
    assert records[-1].gaps==2
    print('PASS: 41 Ethernet wire packets: preamble, FCS, IP checksum, UDP, full IDs, depth, BBO, signals, snapshots, configuration, reset and upstream gaps')


if __name__=='__main__': main()
