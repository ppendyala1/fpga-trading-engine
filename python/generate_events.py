# Planned role: Reproducible event streams and test vectors.

import argparse
import csv
import random
from dataclasses import asdict
from pathlib import Path

from reference_model import BookConfig, Event, OrderBook


def generate_trace(
    count: int = 10_000,
    seed: int = 411,
    config: BookConfig | None = None,
):
    if count < 0:
        raise ValueError("Event count must be nonnegative")

    rng = random.Random(seed)
    book = OrderBook(config)

    cfg = book.config
    next_id = 1

    for _ in range(count):
        active = book.orders

        add = not active or (
            len(active) < cfg.max_orders
            and rng.random() < 0.45
        )

        if add:
            event = Event(
                kind="A",
                order_id=next_id,
                quantity=rng.randint(1, 1000),
                side=rng.choice(("B", "S")),
                price=(
                    cfg.base_price
                    + rng.randrange(cfg.price_levels) * cfg.tick_size
                ),
            )

            next_id += 1

        else:
            order_id = rng.choice(list(active))
            kind = rng.choice(("E", "X", "D"))

            quantity = (
                0
                if kind == "D"
                else rng.randint(1, active[order_id].quantity)
            )

            event = Event(kind, order_id, quantity)

        yield event, book.apply(event)


def write_vectors(
    path: Path,
    count: int,
    seed: int,
) -> dict[str, int]:
    path.parent.mkdir(parents=True, exist_ok=True)

    fields = [
        "event_index",
        "kind",
        "order_id",
        "quantity",
        "side",
        "price",
        "bid_valid",
        "bid_price",
        "bid_quantity",
        "ask_valid",
        "ask_price",
        "ask_quantity",
    ]

    counts = dict.fromkeys(("A", "E", "X", "D"), 0)

    with path.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fields)
        writer.writeheader()

        for index, (event, bbo) in enumerate(
            generate_trace(count, seed)
        ):
            row = {
                "event_index": index,
                **asdict(event),
                **asdict(bbo),
            }

            row["bid_valid"] = int(bbo.bid_valid)
            row["ask_valid"] = int(bbo.ask_valid)

            writer.writerow(row)
            counts[event.kind] += 1

    return counts


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)

    parser.add_argument("--count", type=int, default=10_000)
    parser.add_argument("--seed", type=int, default=411)

    parser.add_argument(
        "--output",
        type=Path,
        default=(
            Path(__file__).resolve().parents[1]
            / "tb/vectors/events.csv"
        ),
    )

    args = parser.parse_args()

    if args.count < 1:
        parser.error("--count must be positive")

    counts = write_vectors(args.output, args.count, args.seed)

    print(
        f"Wrote {args.count} events to {args.output} "
        f"(seed={args.seed})"
    )
    print("Event counts:", counts)
