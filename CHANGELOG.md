# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog],
and this project adheres to [Semantic Versioning].

## [Unreleased]

- Initial release
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
