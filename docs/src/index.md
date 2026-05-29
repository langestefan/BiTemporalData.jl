```@meta
CurrentModule = BiTemporalData
```

# BiTemporalData

Documentation for [BiTemporalData](https://github.com/langestefan/BiTemporalData.jl).

BiTemporalData stores facts along two independent time axes — *valid time* (when a
fact is true in the world) and *transaction time* (when the system believed it) —
so you can distinguish *the world changed* from *we changed our mind*, and
reproduce exactly what was known at any past point in time.

## Quick start

```@example
using BiTemporalData, Dates

# A store keyed by String entities holding Float64 values.
s = MemoryStore{String,Float64}()

# Record a fact valid from 2024-01-01 onward.
insert!(s, "AAPL", 100.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
before = now()

# We changed our mind: the value over that range was actually 110.0.
correct!(s, "AAPL", 110.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 3))

# The current belief is the corrected value...
@show as_of(s, "AAPL")

# ...but what we believed *before* the correction is still reproducible.
@show as_of(s, "AAPL"; tx_at = before)

# A snapshot is a flat, columnar, point-in-time view — the read boundary for
# bulk/analytics workloads. Freezing tx_at makes it reproducible and leakage-proof.
snapshot(s; valid_at = Date(2024, 6, 1))
```

Use [`amend!`](@ref) instead of [`correct!`](@ref) when the world genuinely
changed on a date (it splits the timeline) rather than when a past value was
wrong. See the [Reference](@ref reference) for the full API.

## Contributors

```@raw html
<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
```
