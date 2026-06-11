# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog],
and this project adheres to [Semantic Versioning].

## [Unreleased]

- Initial release
- Transaction-time correctness pass (from a review of the v1 data model):
  - **(Breaking)** `correct!` now preserves the surrounding belief when it
    overlaps only part of a record: the slivers outside the corrected range are
    re-inserted with the old value, so correcting a subrange no longer silently
    retracts the rest.
  - **(Breaking)** A close (`correct!`/`amend!`/`retract!`) whose `ts` predates a
    record's `tx_from` now throws `ArgumentError` instead of creating an inverted
    transaction interval.
  - **(Breaking)** Ties on `tx_from` now resolve to the later write (append
    order) everywhere: `as_of`, `as_of_batch`, and the SQLite/DuckDB native
    snapshots (`ORDER BY tx_from DESC, id DESC`).
  - **(Breaking)** `amend!` returns the newly inserted records (was `nothing`).
  - Transaction-time defaults are now `now(UTC)`, so DST fall-back cannot push
    `tx_from` backwards. Callers passing explicit `ts` should supply UTC.
- Add `retract!(s, key; valid_from, valid_to, ts)`: state "we now believe nothing
  here" over a range, keeping prior beliefs reproducible. Forwarded through
  `ThreadSafe`.
- Multi-step writes (`correct!`, `amend!`, `retract!`) now run atomically on
  transactional backends via the new `with_write_tx` hook: SQLite/DuckDB roll back
  a half-applied write. `MemoryStore`/`ColumnarStore` keep the no-op default.
- `tx_at`, `tx_at_old`/`tx_at_new`, the `tx_ats` batch vector, and every `ts`
  keyword now accept any `TimeType` (a `Date` is taken as midnight).
- `entities` on the in-memory backends returns a detached snapshot
  (`collect(keys(...))`), so iterating it through `ThreadSafe` is safe against a
  concurrent writer; `as_of_batch`, `diff`, and `load!` on a `ThreadSafe` store
  now run wholly under the lock (consistent point-in-time reads).
- `insert!` gains an opt-in `check_overlap = true` keyword that rejects a range
  overlapping a believed record.
- `SQLiteStore` gets a native window-function `snapshot` (no more N+1 walk), and
  `load!` fetches each key's records once instead of re-reading per row.
- Both DB extension constructors reject a `table` name that is not a plain SQL
  identifier.
- Add `load!` to bulk-ingest a Tables.jl source (e.g. a `DataFrame` or `CSV.File`)
  into a store, mapping columns to `key`/`value`/`valid_from`/`valid_to`/`ts`.
- Add a readable `show` for any `BitemporalStore` (summary instead of a full dump).
- Add `ColumnarStore`, an in-memory struct-of-arrays backend with native
  `snapshot`/`as_of`/`as_of_batch` that scan the columns directly without building
  `Record`s (the fastest backend for the read path; see `benchmark/`).
- Add `as_of_batch(...; threaded = true)`, a backend-aware parallel batch read.
  In-memory backends thread over the queries; on-disk backends fetch serially and
  thread the scan. New backends opt in via `supports_parallel_reads`.
- Add a `Benchmark PR` workflow that runs the `benchmark/benchmarks.jl`
  AirspeedVelocity.jl suite to compare each PR against `main` and comment the
  result. `benchmark` and `examples` are now `[workspace]` sub-projects.
- Valid time is now `DateTime` (was `Date`), so facts can change intraday.
  Operations accept any `TimeType` (a `Date` is taken as midnight). A TimeZones
  extension stores `ZonedDateTime` inputs as their UTC instant. `MAX_DATE` is
  removed; use `MAX_DT` for both axes. (Breaking.)
- Add `SQLiteStore`, a persistent backend shipped as a package extension (load it
  with `using SQLite`).
- Add `DuckDBStore`, a persistent columnar backend shipped as a package extension
  (load it with `using DuckDB`); it overrides `snapshot` with a native query.

<!-- Links -->

[keep a changelog]: https://keepachangelog.com/en/1.1.0/
[semantic versioning]: https://semver.org/spec/v2.0.0.html

<!-- Versions -->

[unreleased]: https://github.com/langestefan/BiTemporalData.jl/compare/v0.1.0...HEAD
