# The bitemporal data model

This guide explains the model BiTemporalData.jl is built on: two independent time
axes, and how they let you answer "what did we believe was true, and when?"

## Two kinds of time

Every fact is tracked along two axes:

- **Valid time** — when the fact is true *in the world*.
- **Transaction time** — when the *system* believed it.

These are genuinely different. Valid time is a property of the world (a price
holds from a date, a sensor reads at an instant). Transaction time is a property
of the database (a row was written, then later corrected). Keeping them apart is
the whole point.

## Why two axes

One axis can't tell two different kinds of change apart:

- **The world changed.** Yesterday's price was right; today there is a new one.
- **We changed our mind.** Yesterday's price was *wrong*; we now know the correct
  value for that same day.

With a single "last updated" timestamp both look identical — the old number is
gone either way. Bitemporal storage records *both* axes, so you can reproduce
exactly what the system believed at any past moment, and separate a real-world
change from a correction.

## A record is a rectangle

A stored [`Record`](@ref) covers a half-open box: `[valid_from, valid_to)` on the
valid-time axis and `[tx_from, tx_to)` on the transaction-time axis. Writes are
**append-only** — the only field that ever changes is `tx_to`, which is closed
when a later write supersedes the record. A record whose `tx_to` is still open
(`MAX_DT`) is *currently believed*.

A query picks one point on each axis (`valid_at`, `tx_at`) and returns the record
whose box contains that point.

## The three writes

- [`insert!`](@ref) — record a new fact over a valid range.
- [`correct!`](@ref) — "we were wrong": supersede a value. The old record is
  closed in transaction time, not deleted, so earlier beliefs stay reproducible.
- [`amend!`](@ref) — "the world changed on a date": split the valid-time timeline,
  keeping the old value before the change and the new value after.

`correct!` moves along the transaction axis; `amend!` moves along the valid axis.
That distinction is the model in one sentence.

## Reading the store

- [`as_of`](@ref) answers a single `(valid_at, tx_at)` point.
- [`snapshot`](@ref) freezes the whole store at one `tx_at` — the reproducible,
  leakage-proof read boundary for analytics and ML.

## Where to next

- The [Reference](@ref reference) lists every operation and type.
- The package README has a runnable quick-start walking through `insert!`,
  `correct!`, `amend!`, and `snapshot`.
