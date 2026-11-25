"""Loss, duplicate, reorder, truncation, epoch and snapshot atomicity tests."""
from dataclasses import replace
import struct
import unittest
from protocol import command, decode, DisplayBook


def packet(kind='S', sequence=3, number=0, chunk=0, nonce=99, flags=1, status=0):
    data=bytearray(640 if kind=='S' and not status else 128)
    data[:8]=b'FTET\x01'+kind.encode()+bytes([flags,status])
    struct.pack_into('!H',data,117,50)
    struct.pack_into('!H',data,119,256)
    struct.pack_into('!IIII',data,8,123,sequence,number,nonce)
    struct.pack_into('!HBBQ',data,56,0xffff,chunk,8 if len(data)==640 else 0,0)
    if len(data)==640:
        struct.pack_into('!64Q',data,128,*range(chunk*64,(chunk+1)*64))
    return decode(data)


class ProtocolTests(unittest.TestCase):
    def synced(self):
        book=DisplayBook(123);book.request_snapshot(99)
        for i in range(8): book.apply(packet(number=i,chunk=i))
        self.assertTrue(book.trusted)
        return book

    def test_command_full_id_and_layout(self):
        from reference_model import Event
        data=command('A',123,9,Event('A',2**64-1,2**32-1,'B',1500000))
        self.assertEqual(len(data),48)
        self.assertEqual(data[16:24],b'\xff'*8)
        self.assertEqual(data[32],ord('B'))
        self.assertEqual(data[:8],b'FTE1A\x01\0\0')

    def test_snapshot_atomic_publish(self):
        book=DisplayBook(123);book.request_snapshot(99)
        for i in range(7):
            book.apply(packet(number=i,chunk=i))
            self.assertFalse(book.trusted)
            self.assertEqual(book.levels,[0]*512)
        book.apply(packet(number=7,chunk=7))
        self.assertTrue(book.trusted)
        self.assertEqual(book.levels,list(range(512)))

    def test_every_missing_chunk_and_resync(self):
        for missing in range(8):
            book=DisplayBook(123);book.request_snapshot(99)
            for i in range(8):
                if i!=missing: book.apply(packet(number=i,chunk=i))
            self.assertFalse(book.trusted)
            book.request_snapshot(100)
            for i in range(8): book.apply(packet(number=10+i,chunk=i,nonce=100))
            self.assertTrue(book.trusted)

    def test_event_gap_withholds_book(self):
        book=self.synced()
        book.apply(packet('U',sequence=5,number=9))
        self.assertFalse(book.trusted)
        self.assertEqual(book.drops,1)

    def test_final_packet_loss_timeout(self):
        book=self.synced();book.invalidate('Receive timeout')
        self.assertFalse(book.trusted)

    def test_duplicate_and_old_ignored(self):
        book=self.synced()
        self.assertFalse(book.apply(packet(number=6,chunk=6)))
        self.assertTrue(book.trusted)
        self.assertEqual(book.packet,7)

    def test_snapshot_reordering_fails_closed(self):
        book=DisplayBook(123);book.request_snapshot(99)
        for i in (0,2,1,3,4,5,6,7): book.apply(packet(number=i,chunk=i))
        self.assertFalse(book.trusted)

    def test_old_session_and_wrong_nonce(self):
        book=DisplayBook(123);book.request_snapshot(100)
        for i in range(8):book.apply(packet(number=i,chunk=i,nonce=99))
        self.assertFalse(book.trusted)
        for i in range(8):book.apply(replace(packet(number=10+i,chunk=i,nonce=100),session=122))
        self.assertFalse(book.trusted)

    def test_input_gap_snapshot_cannot_restore_trust(self):
        book=self.synced();book.request_snapshot(100)
        for i in range(8):book.apply(packet(number=10+i,chunk=i,nonce=100,flags=0))
        self.assertFalse(book.trusted)

    def test_rejected_event_advances_sequence_without_delta(self):
        book=self.synced();before=book.levels.copy()
        book.apply(packet('U',sequence=4,number=8,status=3))
        self.assertTrue(book.trusted)
        self.assertEqual(book.sequence,4)
        self.assertEqual(book.levels,before)

    def test_packet_counter_wrap(self):
        book=self.synced();book.packet=0xffffffff
        book.apply(packet('U',sequence=4,number=0))
        self.assertTrue(book.trusted)

    def test_malformed_telemetry(self):
        for data in (b'',b'FTET',bytes(128),bytes(640)):
            with self.assertRaises(ValueError):decode(data)

    def test_snapshots_preserve_only_known_fpga_decisions(self):
        book=self.synced()
        book.apply(packet('U',sequence=4,number=8,flags=17))
        self.assertEqual(book.decision,'BUY')
        book.request_snapshot(100)
        for i in range(8):book.apply(packet(sequence=4,number=9+i,chunk=i,nonce=100))
        self.assertTrue(book.trusted)
        self.assertEqual(book.decision,'BUY')
        book.request_snapshot(101)
        for i in range(8):book.apply(packet(sequence=5,number=17+i,chunk=i,nonce=101))
        self.assertTrue(book.trusted)
        self.assertIsNone(book.decision)  # lost event decision cannot be reconstructed


if __name__=='__main__':unittest.main()
