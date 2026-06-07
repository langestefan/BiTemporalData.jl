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

## `threaded_bench.jl`

```bash
julia -t auto --project=bench bench/threaded_bench.jl
```

`as_of_batch(...; threaded = true)` is backend-aware: it picks a strategy from
`supports_parallel_reads`. In-memory backends (`parallel`) thread straight over
the queries; on-disk backends and `ThreadSafe` (`serial`) fetch records serially
(connection-safe) and thread only the per-query scan.

Representative result, 1,000,000-query batch over 2000 entities, 16 threads:

| Backend           | reads    | serial   | threaded | speedup |
| ----------------- | -------- | -------- | -------- | ------- |
| `ColumnarStore`   | parallel | 61 ms    | **8 ms** | 7.4×    |
| `MemoryStore`     | parallel | 125 ms   | 11 ms    | 11.5×   |
| `ThreadSafe(Col)` | serial   | 127 ms   | 50 ms    | 2.5×    |
| `SQLiteStore`     | serial   | 156 ms   | 82 ms    | 1.9×    |
| `DuckDBStore`     | serial   | 3.0 s    | 2.4 s    | ~1×     |

Findings:

- **`ColumnarStore` is fastest, serial and threaded.** It overrides `as_of` /
  `as_of_batch` to scan the column vectors by index, never building a `Record`, so
  the batch read is allocation-free (just the result vector). That makes its serial
  path ~2× faster than `MemoryStore` (no grouping `Dict`, no record materialization)
  and its threaded path the quickest overall. `MemoryStore` shows a larger *ratio*
  only because its serial baseline allocates the grouping it then parallelizes away.
- **On-disk backends** thread only the scan, so the speedup grows with batch size
  (more scan work) up to ~2×; the per-key SQL fetch is the serial floor and isn't
  parallelized (a single connection isn't thread-safe). `DuckDBStore`'s fetch is
  slow enough that the batch is fetch-bound and threading is moot.
- The right strategy is selected automatically per backend; all combinations
  return identical results to the serial path.
