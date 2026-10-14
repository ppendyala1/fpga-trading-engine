"""Directed tests and independent replay, using only the standard library."""
import csv
import tempfile
import unittest
from pathlib import Path

from generate_events import generate_trace, write_vectors
from reference_model import (
    BBO,
    BookConfig,
    BookError,
    Event,
    OrderBook,
    U32,
)


class ReferenceModelTests(unittest.TestCase):
    def setUp(self):
        self.book = OrderBook(
            BookConfig(
                max_orders=4,
                base_price=100,
                tick_size=10,
                price_levels=8,
            )
        )

    def add(self, oid, side, price, quantity):
        return self.book.apply(
            Event("A", oid, quantity, side, price)
        )

    def reject(self, event):
        before = (
            self.book.orders,
            self.book.levels("B"),
            self.book.levels("S"),
            self.book.bbo(),
        )

        with self.assertRaises(BookError):
            self.book.apply(event)

        self.assertEqual(
            before,
            (
                self.book.orders,
                self.book.levels("B"),
                self.book.levels("S"),
                self.book.bbo(),
            ),
        )

    def test_empty_and_zero_price(self):
        self.assertEqual(
            self.book.bbo(),
            BBO(False, 0, 0, False, 0, 0),
        )

        zero_book = OrderBook(BookConfig(base_price=0))
        bbo = zero_book.apply(Event("A", 0, 5, "B", 0))

        self.assertTrue(bbo.bid_valid)
        self.assertEqual(bbo.bid_price, 0)

    def test_shared_price_aggregation(self):
        self.add(1, "B", 120, 50)
        self.add(2, "B", 120, 70)
        self.add(3, "S", 140, 80)

        self.assertEqual(
            self.book.bbo(),
            BBO(True, 120, 120, True, 140, 80),
        )

        self.book.apply(Event("E", 1, 20))
        self.assertEqual(self.book.bbo().bid_quantity, 100)

    def test_execute_cancel_and_full_reduction(self):
        self.add(1, "B", 120, 100)

        self.book.apply(Event("E", 1, 30))
        self.assertEqual(self.book.orders[1].quantity, 70)

        self.book.apply(Event("X", 1, 20))
        self.assertEqual(self.book.orders[1].quantity, 50)

        self.book.apply(Event("E", 1, 50))
        self.assertEqual(self.book.orders, {})
        self.assertEqual(self.book.levels("B"), {})

    def test_full_cancel_removes_order(self):
        self.add(1, "S", 150, 9)
        self.book.apply(Event("X", 1, 9))

        self.assertFalse(self.book.bbo().ask_valid)

    def test_delete_best_finds_next_level(self):
        self.add(1, "B", 120, 10)
        self.add(2, "B", 130, 20)
        self.add(3, "S", 150, 30)
        self.add(4, "S", 160, 40)

        self.book.apply(Event("D", 2))
        self.book.apply(Event("D", 3))

        self.assertEqual(
            self.book.bbo(),
            BBO(True, 120, 10, True, 160, 40),
        )

    def test_delete_one_order_keeps_shared_level(self):
        self.add(1, "S", 150, 10)
        self.add(2, "S", 150, 20)

        self.book.apply(Event("D", 1))

        self.assertEqual(self.book.levels("S"), {150: 20})

    def test_capacity_and_reuse(self):
        for oid in range(4):
            self.add(oid, "B", 100, 1)

        self.reject(Event("A", 4, 1, "B", 100))

        self.book.apply(Event("D", 0))
        self.add(0, "S", 170, 2)

        self.assertEqual(len(self.book.orders), 4)

    def test_rejected_events_are_atomic(self):
        self.add(1, "B", 120, 10)

        bad = [
            Event("A", 1, 5, "S", 140),
            Event("D", 99),
            Event("E", 1, 11),
            Event("X", 1, 0),
            Event("D", 1, 1),
            Event("E", 1, 1, "B", 120),
            Event("A", 2, 0, "B", 100),
            Event("A", 2, 1, "Q", 100),
            Event("A", 2, 1, "B", 111),
            Event("A", 2, 1, "B", 90),
            Event("A", 2, 1, "B", 180),
            Event("A", -1, 1, "B", 100),
            Event("A", 1 << 64, 1, "B", 100),
            Event("A", 2, U32 + 1, "B", 100),
            Event("Z", 1),
            Event("E", 1, 1.5),
            Event("A", True, 1, "B", 100),
        ]

        for event in bad:
            with self.subTest(event=event):
                self.reject(event)

    def test_large_ids_and_level_quantity(self):
        self.add((1 << 64) - 1, "B", 100, U32)
        self.add(1 << 40, "B", 100, U32)

        self.assertEqual(
            self.book.bbo().bid_quantity,
            2 * U32,
        )

    def test_reset_and_snapshot_copies(self):
        self.add(1, "B", 100, 4)

        self.book.orders.clear()
        self.book.levels("B").clear()

        self.assertEqual(self.book.bbo().bid_quantity, 4)

        self.book.reset()

        self.assertEqual(
            self.book.bbo(),
            BBO(False, 0, 0, False, 0, 0),
        )

        self.add(1, "S", 170, 7)

    def test_invalid_configuration(self):
        invalid_configs = [
            {"max_orders": 0},
            {"tick_size": 0},
            {"price_levels": -1},
            {"base_price": -1},
            {"base_price": U32},
            {"tick_size": 1.5},
        ]

        for kwargs in invalid_configs:
            with self.subTest(kwargs=kwargs):
                with self.assertRaises(ValueError):
                    BookConfig(**kwargs)

    def test_10000_events_against_independent_replay(self):
        # This second implementation stores only individual orders.
        # It rebuilds every price-level total after each event.
        naive = {}
        replay = OrderBook()
        counts = dict.fromkeys("AEXD", 0)

        for index, (event, expected) in enumerate(
            generate_trace(10_000, 411)
        ):
            counts[event.kind] += 1

            if event.kind == "A":
                naive[event.order_id] = [
                    event.side,
                    event.price,
                    event.quantity,
                ]

            elif event.kind == "D":
                del naive[event.order_id]

            else:
                naive[event.order_id][2] -= event.quantity

                if naive[event.order_id][2] == 0:
                    del naive[event.order_id]

            bids = {}
            asks = {}

            for side, price, quantity in naive.values():
                levels = bids if side == "B" else asks
                levels[price] = levels.get(price, 0) + quantity

            bid = max(bids, default=0)
            ask = min(asks, default=0)

            independent = BBO(
                bool(bids),
                bid,
                bids.get(bid, 0),
                bool(asks),
                ask,
                asks.get(ask, 0),
            )

            self.assertEqual(
                replay.apply(event),
                independent,
                f"BBO at event {index}",
            )
            self.assertEqual(expected, independent)
            self.assertEqual(replay.levels("B"), bids)
            self.assertEqual(replay.levels("S"), asks)

            self.assertEqual(
                {
                    oid: (o.side, o.price, o.quantity)
                    for oid, o in replay.orders.items()
                },
                {
                    oid: tuple(o)
                    for oid, o in naive.items()
                },
            )

        self.assertTrue(all(counts.values()), counts)

    def test_seed_reproducibility_and_csv(self):
        self.assertEqual(
            list(generate_trace(100, 411)),
            list(generate_trace(100, 411)),
        )

        self.assertNotEqual(
            list(generate_trace(100, 411)),
            list(generate_trace(100, 412)),
        )

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.csv"

            self.assertEqual(
                sum(write_vectors(path, 100, 411).values()),
                100,
            )

            with path.open(
                newline="",
                encoding="utf-8",
            ) as stream:
                rows = list(csv.DictReader(stream))

            self.assertEqual(len(rows), 100)

            for row, (event, expected) in zip(
                rows,
                generate_trace(100, 411),
            ):
                self.assertEqual(row["kind"], event.kind)
                self.assertEqual(
                    int(row["order_id"]),
                    event.order_id,
                )
                self.assertEqual(
                    int(row["bid_price"]),
                    expected.bid_price,
                )
                self.assertEqual(
                    int(row["ask_valid"]),
                    int(expected.ask_valid),
                )


if __name__ == "__main__":
    unittest.main()