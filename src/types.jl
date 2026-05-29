"Sentinel for an open-ended `valid_to`: `typemax(Date)`."
const MAX_DATE = typemax(Date)

"Sentinel for an open `tx_to`: `typemax(DateTime)`. `tx_to == MAX_DT` means currently believed."
const MAX_DT = typemax(DateTime)

"""
    Record{V}

Append-only bitemporal record: `value` over half-open `[valid_from, valid_to)`
(valid time) and `[tx_from, tx_to)` (transaction time). Only `tx_to` may change
(see [`close_tx!`](@ref)). `id` is backend-assigned by [`put_record!`](@ref).
"""
struct Record{V}
    id::Any
    value::V
    valid_from::Date
    valid_to::Date
    tx_from::DateTime
    tx_to::DateTime
end

"""
    BitemporalStore{K,V}

Store of `V` values keyed by `K`. Backends implement [`get_records`](@ref),
[`put_record!`](@ref), [`close_tx!`](@ref), [`entities`](@ref) and inherit
`insert!`, [`correct!`](@ref), [`amend!`](@ref), [`as_of`](@ref),
[`history`](@ref), [`snapshot`](@ref).
"""
abstract type BitemporalStore{K, V} end

# `Record` is immutable, so closing `tx_to` means rebuilding.
_close(r::Record, ts::DateTime) =
    Record(r.id, r.value, r.valid_from, r.valid_to, r.tx_from, ts)

# Do half-open `[a, b)` and `[c, d)` overlap?
_overlaps(a, b, c, d) = a < d && c < b

_believed(r::Record) = r.tx_to == MAX_DT
