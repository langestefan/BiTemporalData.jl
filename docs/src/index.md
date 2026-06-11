```@meta
CurrentModule = BiTemporalData
```

# BiTemporalData

BiTemporalData stores facts along two independent time axes:

- **effective time**: when a fact is true in the world (`effective_from`, `effective_to`);
- **assertive time**: when the system asserted it (`assertive_from`, `assertive_to`).

Tracking both lets you separate *the world changed* from *we changed our mind*,
and reproduce exactly what was known at any past point in time. All intervals are
half-open `[from, to)`, and writes are append-only; the only mutation is closing
a record's `assertive_to`.

The examples below run during the docs build and share one store `s`. Timestamps
are passed explicitly (`asserted_at =`) for reproducibility; real callers omit them and get
`now()`.

## Recording a fact

```@example bt
using BiTemporalData, Dates

# String-keyed store of Float64 values.
s = MemoryStore{String, Float64}()

insert!(s, "AAPL", 100.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 1))

as_of(s, "AAPL"; effective_at = Date(2024, 6, 1), assertive_at = DateTime(2024, 1, 2))
```

## Correcting a mistake

[`correct!`](@ref) supersedes a value we now assert was wrong. The old record is
not deleted; it is closed in assertive time and stays readable:

```@example bt
correct!(s, "AAPL", 110.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 3))

(
    believed_before = as_of(s, "AAPL"; effective_at = Date(2024, 6, 1), assertive_at = DateTime(2024, 1, 2)),
    believed_after = as_of(s, "AAPL"; effective_at = Date(2024, 6, 1), assertive_at = DateTime(2024, 1, 5)),
)
```

## Amending when the world changes

[`amend!`](@ref) is different: the past value was *right*, but the world changed
on a date. It splits the timeline, keeping the old value before the change and the
new value after:

```@example bt
amend!(s, "AAPL", 130.0; effective = Date(2024, 7, 1), asserted_at = DateTime(2024, 8, 1))

(
    spring = as_of(s, "AAPL"; effective_at = Date(2024, 3, 1), assertive_at = DateTime(2024, 8, 2)),
    autumn = as_of(s, "AAPL"; effective_at = Date(2024, 9, 1), assertive_at = DateTime(2024, 8, 2)),
)
```

## History and snapshots

[`history`](@ref) returns every record ever written for a key, superseded ones
included: the full audit trail.

```@example bt
history(s, "AAPL")
```

[`snapshot`](@ref) is the read boundary for bulk/analytics workloads: a flat,
columnar view frozen at a `assertive_at`, which makes it reproducible and leakage-proof.
With a `effective_at` it collapses to one value per entity:

```@example bt
snapshot(s; effective_at = Date(2024, 9, 1), assertive_at = DateTime(2024, 8, 2))
```

## Analytical queries

Three operations build on `snapshot`. [`diff`](@ref) reports what the store's
assertions changed between two assertive times, classifying each row as
`:inserted`, `:retracted`, or `:corrected`:

```@example bt
diff(s; assertive_at_old = DateTime(2024, 1, 2), assertive_at_new = DateTime(2024, 8, 2))
```

[`as_of_batch`](@ref) answers many point-in-time lookups in one pass, ideal for
building leakage-free training sets:

```@example bt
as_of_batch(
    s,
    ["AAPL", "AAPL"],
    [Date(2024, 3, 1), Date(2024, 9, 1)],
    [DateTime(2024, 8, 2), DateTime(2024, 8, 2)],
)
```

[`asof_join`](@ref) inner-joins two stores on `entity` at one point in time.

See the [Reference](@ref reference) for the full API.
