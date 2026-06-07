# Benchmarks

```bash
julia --project=bench -e 'using Pkg; Pkg.instantiate()'   # first time only
julia --project=bench bench/snapshot_bench.jl
```

`snapshot_bench.jl` builds the same store (2000 entities × 3 records) in each
backend and times `snapshot` (the ML / bulk-analytics read path) in both modes.

Representative result (your numbers will vary):

| Backend         | full tx-slice | cross-section | vs `MemoryStore` |
| --------------- | ------------- | ------------- | ---------------- |
| `MemoryStore`   | 90 µs         | 790 µs        | 1×               |
| `ColumnarStore` | 12 µs         | 32 µs         | **7–24× faster** |
| `DuckDBStore`   | 2.6 ms        | 2.6 ms        | 3–29× slower     |
| `SQLiteStore`   | 34 ms         | 35 ms         | 45–380× slower   |

`ColumnarStore` wins because it stores records as parallel column vectors, so the
`value` column is built contiguously in one pass: no per-record objects (vs
`MemoryStore`'s array-of-structs), no `Serialization` decode (vs the on-disk
backends). It also allocates 4–11× less. That contiguous `Vector{V}` is what you
hand to a model or copy to a device.
