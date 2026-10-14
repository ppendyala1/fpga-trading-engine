# Planned verification

Compare hardware results with an independent Python reference model.

Cover Add, Execute, Cancel, Delete, multiple orders at one price, removal of the best price, empty sides, full capacity, unknown IDs, duplicates, invalid quantities, lookup collisions, reset, backpressure, and consecutive dependent updates.

Later cover truncated packets, header lengths, wrong destinations, unsupported fragments, checksum/FCS errors, and sequence gaps.

The goal is 10,000+ reproducible simulated events with recorded seeds, plus directed corner cases. No tests have run yet.
