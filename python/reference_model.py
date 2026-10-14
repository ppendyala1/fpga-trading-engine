# Planned role: Software order book and expected-result generation.
from dataclasses import dataclass, replace

U32 = (1 << 32) - 1
U64 = (1 << 64) - 1


class BookError(ValueError):
    """Rejected event; the book remains unchanged."""


@dataclass(frozen=True)
class BookConfig:
    max_orders: int = 1024
    base_price: int = 1_500_000  # $150.0000
    tick_size: int = 100        # $0.0100
    price_levels: int = 256

    def __post_init__(self):
        values = (
            self.max_orders,
            self.base_price,
            self.tick_size,
            self.price_levels,
        )

        if any(type(v) is not int for v in values):
            raise ValueError("Configuration values must be integers")

        if (
            self.max_orders < 1
            or self.price_levels < 1
            or self.tick_size < 1
        ):
            raise ValueError(
                "Capacity, level count, and tick size must be positive"
            )

        end = self.base_price + (self.price_levels - 1) * self.tick_size

        if self.base_price < 0 or end > U32:
            raise ValueError("Supported prices must fit unsigned 32 bits")


@dataclass(frozen=True)
class Event:
    kind: str           # A=Add, E=Execute, X=Cancel, D=Delete
    order_id: int
    quantity: int = 0
    side: str = ""      # B=bid, S=ask; only on Add
    price: int = 0      # only on Add


@dataclass(frozen=True)
class Order:
    side: str
    price: int
    quantity: int


@dataclass(frozen=True)
class BBO:
    bid_valid: bool
    bid_price: int
    bid_quantity: int
    ask_valid: bool
    ask_price: int
    ask_quantity: int


class OrderBook:
    def __init__(self, config: BookConfig | None = None):
        self.config = config or BookConfig()

        self._orders: dict[int, Order] = {}
        self._bids: dict[int, int] = {}
        self._asks: dict[int, int] = {}

    @property
    def orders(self) -> dict[int, Order]:
        return self._orders.copy()

    def levels(self, side: str) -> dict[int, int]:
        if side not in ("B", "S"):
            raise ValueError("Side must be B or S")

        return (
            self._bids if side == "B" else self._asks
        ).copy()

    def reset(self) -> None:
        self._orders.clear()
        self._bids.clear()
        self._asks.clear()

    def bbo(self) -> BBO:
        bid = max(self._bids, default=0)
        ask = min(self._asks, default=0)

        return BBO(
            bid_valid=bool(self._bids),
            bid_price=bid,
            bid_quantity=self._bids.get(bid, 0),
            ask_valid=bool(self._asks),
            ask_price=ask,
            ask_quantity=self._asks.get(ask, 0),
        )

    @staticmethod
    def _uint(value: int, maximum: int, name: str):
        if type(value) is not int or not 0 <= value <= maximum:
            raise BookError(
                f"{name} is outside its unsigned integer range"
            )

    def apply(self, event: Event) -> BBO:
        """Validate first; update orders and aggregate levels atomically."""
        if event.kind not in ("A", "E", "X", "D"):
            raise BookError("Unsupported event type")

        self._uint(event.order_id, U64, "order_id")
        self._uint(event.quantity, U32, "quantity")
        self._uint(event.price, U32, "price")

        if event.kind == "A":
            if event.side not in ("B", "S") or event.quantity == 0:
                raise BookError(
                    "Add needs B/S side and positive quantity"
                )

            if event.order_id in self._orders:
                raise BookError("Duplicate active order ID")

            if len(self._orders) >= self.config.max_orders:
                raise BookError("Order capacity reached")

            offset = event.price - self.config.base_price

            if (
                offset < 0
                or offset % self.config.tick_size != 0
                or offset // self.config.tick_size
                >= self.config.price_levels
            ):
                raise BookError("Price is outside the configured grid")

            levels = (
                self._bids if event.side == "B" else self._asks
            )

            total = levels.get(event.price, 0) + event.quantity

            if total > U64:
                raise BookError("Price-level quantity overflow")

            self._orders[event.order_id] = Order(
                event.side,
                event.price,
                event.quantity,
            )

            levels[event.price] = total

        else:
            if event.side != "" or event.price != 0:
                raise BookError(
                    "Non-Add events must omit side and price"
                )

            if event.order_id not in self._orders:
                raise BookError("Unknown order ID")

            order = self._orders[event.order_id]

            if event.kind == "D":
                if event.quantity != 0:
                    raise BookError("Delete must omit quantity")

                removed = order.quantity

            else:
                if not 1 <= event.quantity <= order.quantity:
                    raise BookError(
                        "Reduction must be positive and no larger "
                        "than the order"
                    )

                removed = event.quantity

            levels = (
                self._bids if order.side == "B" else self._asks
            )

            remaining = order.quantity - removed

            if remaining:
                self._orders[event.order_id] = replace(
                    order,
                    quantity=remaining,
                )
            else:
                del self._orders[event.order_id]

            total = levels[order.price] - removed

            if total:
                levels[order.price] = total
            else:
                del levels[order.price]

        return self.bbo()


if __name__ == "__main__":
    book = OrderBook()

    demo = [
        Event("A", 42, 100, "B", 1_500_000),
        Event("A", 43, 80, "S", 1_500_200),
        Event("E", 42, 30),
        Event("X", 43, 20),
        Event("D", 42),
    ]

    for event in demo:
        print(f"{event}\n  -> {book.apply(event)}")