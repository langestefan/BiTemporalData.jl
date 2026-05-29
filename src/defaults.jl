# Default operations on `BitemporalStore`, built from the four primitives. All
# ranges are half-open `[from, to)`; writes stamp `tx_from = ts`, `tx_to = MAX_DT`.
# The `ts` keyword is for test determinism; callers normally omit it.

function _check_range(valid_from::Date, valid_to::Date)
    valid_from < valid_to ||
        throw(ArgumentError("valid_from ($valid_from) must be before valid_to ($valid_to)"))
    return nothing
end

"""
    insert!(s, key, value; valid_from, valid_to = MAX_DATE, ts = now())

Record a new fact over `[valid_from, valid_to)`. Returns the stored [`Record`](@ref).
"""
function Base.insert!(
        s::BitemporalStore{K, V}, key, value;
        valid_from::Date, valid_to::Date = MAX_DATE, ts::DateTime = now(),
    ) where {K, V}
    _check_range(valid_from, valid_to)
    return put_record!(s, key, Record{V}(nothing, value, valid_from, valid_to, ts, MAX_DT))
end

"""
    correct!(s, key, value; valid_from, valid_to = MAX_DATE, ts = now())

"We were wrong." Close every believed record overlapping the range, then append
the corrected `value`. History stays readable via [`as_of`](@ref) at an earlier `tx_at`.
"""
function correct!(
        s::BitemporalStore{K, V}, key, value;
        valid_from::Date, valid_to::Date = MAX_DATE, ts::DateTime = now(),
    ) where {K, V}
    _check_range(valid_from, valid_to)
    for r in get_records(s, key)
        if _believed(r) && _overlaps(r.valid_from, r.valid_to, valid_from, valid_to)
            close_tx!(s, r.id, ts)
        end
    end
    return put_record!(s, key, Record{V}(nothing, value, valid_from, valid_to, ts, MAX_DT))
end

"""
    amend!(s, key, value; effective, ts = now())

"The world changed on `effective`." Close the believed chapter(s) covering
`effective`, re-append the old value over `[valid_from, effective)`, and append
`value` from `effective` on. Errors if nothing covers `effective`.
"""
function amend!(
        s::BitemporalStore{K, V}, key, value;
        effective::Date, ts::DateTime = now(),
    ) where {K, V}
    covering = filter(get_records(s, key)) do r
        _believed(r) && r.valid_from <= effective < r.valid_to
    end
    isempty(covering) &&
        throw(ArgumentError("no believed record covers effective date $effective"))
    for r in covering
        close_tx!(s, r.id, ts)
        r.valid_from < effective &&
            put_record!(s, key, Record{V}(nothing, r.value, r.valid_from, effective, ts, MAX_DT))
        put_record!(s, key, Record{V}(nothing, value, effective, r.valid_to, ts, MAX_DT))
    end
    return nothing
end

"""
    as_of(s, key; valid_at = today(), tx_at = now()) -> Union{V,Nothing}

The value believed at `tx_at` to hold at `valid_at`, or `nothing`.
"""
function as_of(
        s::BitemporalStore{K, V}, key;
        valid_at::Date = today(), tx_at::DateTime = now(),
    ) where {K, V}
    hits = [
        r for r in get_records(s, key)
            if r.tx_from <= tx_at < r.tx_to && r.valid_from <= valid_at < r.valid_to
    ]
    isempty(hits) && return nothing
    return argmax(r -> r.tx_from, hits).value
end

"""
    history(s, key) -> NamedTuple of column vectors

Every record for `key` (including superseded), as a Tables.jl column table.
"""
function history(s::BitemporalStore{K, V}, key) where {K, V}
    rs = collect(get_records(s, key))
    return (
        value = V[r.value for r in rs],
        valid_from = [r.valid_from for r in rs],
        valid_to = [r.valid_to for r in rs],
        tx_from = [r.tx_from for r in rs],
        tx_to = [r.tx_to for r in rs],
    )
end
