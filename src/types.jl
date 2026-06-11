"Sentinel for an open range end: `typemax(DateTime)`. `assertive_to == MAX_DT` means currently asserted."
const MAX_DT = typemax(DateTime)

"""
    Record{V}

Append-only bitemporal record: `value` over half-open `[effective_from, effective_to)`
(effective time) and `[assertive_from, assertive_to)` (assertive time). Both axes are `DateTime`.
Only `assertive_to` may change (see [`close_tx!`](@ref)). `id` is backend-assigned by
[`put_record!`](@ref).

Assertive time is UTC by convention: the operations default `asserted_at` to `now(UTC)`,
so the "latest `assertive_from` wins" rule and audit ordering never go backwards across a
DST boundary. A caller passing an explicit `asserted_at` is responsible for supplying UTC.
"""
struct Record{V}
    id::Any
    value::V
    effective_from::DateTime
    effective_to::DateTime
    assertive_from::DateTime
    assertive_to::DateTime
end

"""
    BitemporalStore{K,V}

Store of `V` values keyed by `K`. Backends implement [`get_records`](@ref),
[`put_record!`](@ref), [`close_tx!`](@ref), [`entities`](@ref) and inherit
`insert!`, [`correct!`](@ref), [`amend!`](@ref), [`as_of`](@ref),
[`history`](@ref), [`snapshot`](@ref).
"""
abstract type BitemporalStore{K, V} end

# Normalize any time input to the stored `DateTime`. A `Date` becomes midnight; a
# `DateTime` passes through. The TimeZones extension adds a `ZonedDateTime` method
# that converts to the UTC instant (so times across zones order correctly).
_instant(x::TimeType) = DateTime(x)

# `Record` is immutable, so closing `assertive_to` means rebuilding.
_close(r::Record, asserted_at::DateTime) =
    Record(r.id, r.value, r.effective_from, r.effective_to, r.assertive_from, asserted_at)

# Do half-open `[a, b)` and `[c, d)` overlap?
_overlaps(a, b, c, d) = a < d && c < b

_asserted(r::Record) = r.assertive_to == MAX_DT
