# The bitemporal data model

This guide teaches the model BiTemporalData.jl is built on by example. Every code
block below runs when the docs are built, so the outputs are real.

The core idea: a fact is tracked along **two independent time axes**.

- **Valid time** — when the fact is true *in the world*.
- **Transaction time** — when the *system* believed it.

Keeping them separate lets you tell two different kinds of change apart — the
world changed vs. we changed our mind — and reproduce exactly what was known at
any past moment. We'll build that up one operation at a time, tracking one
person's salary.

## A first fact

Make a store (`String` keys, `Float64` values), record a salary valid from the
new year, and read it back. `ts` pins the transaction time so the example is
reproducible; in real code you omit it and it defaults to `now()`.

```@example salary
using BiTemporalData, Dates

store = MemoryStore{String, Float64}()
insert!(store, "alice", 100.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))

as_of(store, "alice"; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 2))
```

[`as_of`](@ref) asks a single question: *what did we believe at `tx_at` was true
on `valid_at`?*

## "We were wrong": correcting along transaction time

The 100 was a typo — the real figure is 110. [`correct!`](@ref) supersedes it.
The old record is **not deleted**; it is closed in transaction time, so an earlier
`tx_at` still reproduces the old belief.

```@example salary
correct!(store, "alice", 110.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 3))

(
    believed_before = as_of(store, "alice"; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 2)),
    believed_now = as_of(store, "alice"; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 4)),
)
```

Same `valid_at`, different `tx_at`, different answer: a correction moves along the
**transaction** axis.

## "The world changed": amending along valid time

Alice gets a raise to 130, effective 1 July — the old figure was *right* for the
first half of the year. [`amend!`](@ref) splits the timeline: the old value holds
before the effective date, the new value after.

```@example salary
amend!(store, "alice", 130.0; effective = Date(2024, 7, 1), ts = DateTime(2024, 8, 1))

(
    spring = as_of(store, "alice"; valid_at = Date(2024, 3, 1), tx_at = DateTime(2024, 8, 2)),
    autumn = as_of(store, "alice"; valid_at = Date(2024, 9, 1), tx_at = DateTime(2024, 8, 2)),
)
```

Same `tx_at`, different `valid_at`, different answer: an amendment moves along the
**valid** axis. That contrast — `correct!` on transaction time, `amend!` on valid
time — is the whole model.

## The full history

Nothing was overwritten. [`history`](@ref) returns every record ever written for a
key, including the superseded ones, as a column table. Only `tx_to` ever changes
(it closes when a record is superseded); everything else is append-only.

```@example salary
history(store, "alice")
```

A record is "currently believed" when its `tx_to` is still open (the `MAX_DT`
sentinel).

## Reading the whole store: snapshot

For analytics and ML you don't query record by record — you freeze the store at a
`tx_at` with [`snapshot`](@ref). With a `valid_at`, it collapses to one value per
entity. Freezing `tx_at` makes the result reproducible and free of look-ahead
leakage.

```@example salary
snapshot(store; valid_at = Date(2024, 9, 1), tx_at = DateTime(2024, 8, 2))
```

## Sub-day valid time

Valid time is a `DateTime`, so a fact can change intraday — a `Date` is just taken
as midnight. Here a sensor reading becomes valid at 12:30:

```@example salary
insert!(store, "sensor", 21.5; valid_from = DateTime(2024, 1, 1, 12, 30), ts = DateTime(2024, 1, 1))

(
    at_13_00 = as_of(store, "sensor"; valid_at = DateTime(2024, 1, 1, 13), tx_at = DateTime(2024, 2, 1)),
    at_12_00 = as_of(store, "sensor"; valid_at = DateTime(2024, 1, 1, 12), tx_at = DateTime(2024, 2, 1)),
)
```

With `using TimeZones`, a `ZonedDateTime` works too — it is stored as its UTC
instant, so times given in different zones still compare correctly.

## Where to next

- The [Reference](@ref reference) documents every operation and type.
- `snapshot` is the read boundary for bulk/ML workloads; `ColumnarStore` and the
  `SQLiteStore`/`DuckDBStore` extensions back it with different storage.
