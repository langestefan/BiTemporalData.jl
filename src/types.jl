"""
    MAX_DATE

Open-ended sentinel for `valid_to`: `typemax(Date)`. A record whose `valid_to`
equals `MAX_DATE` is valid indefinitely into the future.
"""
const MAX_DATE = typemax(Date)

"""
    MAX_DT

Open-ended sentinel for `tx_to`: `typemax(DateTime)`. A record whose `tx_to`
equals `MAX_DT` is *currently believed* — it has not been superseded.
"""
const MAX_DT = typemax(DateTime)

"""
    Record{V}

An append-only bitemporal record holding a single `value` of type `V` over two
half-open time intervals:

- `[valid_from, valid_to)` — *valid time*, when the fact is true in the world.
- `[tx_from, tx_to)` — *transaction time*, when the system believed it.

`value`, `valid_from`, `valid_to`, and `tx_from` are write-once. The only
permitted mutation is closing `tx_to` (see [`close_tx!`](@ref)); a record with
`tx_to == MAX_DT` is currently believed.

`id` is opaque to the abstract layer — each backend chooses its own format and
populates it in [`put_record!`](@ref).
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

Abstract supertype for bitemporal stores keyed by entity key type `K` with value
type `V`. A backend subtypes this and implements the four primitives
[`get_records`](@ref), [`put_record!`](@ref), [`close_tx!`](@ref), and
[`entities`](@ref); it then inherits the default operations (`insert!`,
[`correct!`](@ref), [`amend!`](@ref), [`as_of`](@ref), [`history`](@ref),
[`snapshot`](@ref)) for free.
"""
abstract type BitemporalStore{K, V} end

# Return a copy of `r` with its transaction interval closed at `ts`. `Record` is
# immutable, so closing means rebuilding.
_close(r::Record, ts::DateTime) =
    Record(r.id, r.value, r.valid_from, r.valid_to, r.tx_from, ts)

# Half-open overlap test: do `[a, b)` and `[c, d)` intersect?
_overlaps(a, b, c, d) = a < d && c < b
