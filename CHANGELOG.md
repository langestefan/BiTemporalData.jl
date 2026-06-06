# CHANGELOG

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog],
and this project adheres to [Semantic Versioning].

## [Unreleased]

- Initial release
- Add `load!` to bulk-ingest a Tables.jl source (e.g. a `DataFrame` or `CSV.File`)
  into a store, mapping columns to `key`/`value`/`valid_from`/`valid_to`/`ts`.
- Add a readable `show` for any `BitemporalStore` (summary instead of a full dump).
- Add `SQLiteStore`, a persistent backend shipped as a package extension (load it
  with `using SQLite`).

<!-- Links -->

[keep a changelog]: https://keepachangelog.com/en/1.1.0/
[semantic versioning]: https://semver.org/spec/v2.0.0.html

<!-- Versions -->

[unreleased]: https://github.com/langestefan/BiTemporalData.jl/compare/v0.1.0...HEAD
