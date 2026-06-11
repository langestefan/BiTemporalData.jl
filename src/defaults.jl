# Default operations on `BitemporalStore`, built from the four primitives. All
# ranges are half-open `[from, to)`; writes stamp `tx_from = ts`, `tx_to = MAX_DT`.
# The `ts` keyword is for test determinism; callers normally omit it.

function _check_range(valid_from::DateTime, valid_to::DateTime)
    valid_from < valid_to ||
        throw(ArgumentError("valid_from ($valid_from) must be before valid_to ($valid_to)"))
    return nothing
end

"""
    insert!(s, key, value; valid_from, valid_to = MAX_DT, ts = now(UTC))

Record a new fact over `[valid_from, valid_to)`. `valid_from`/`valid_to` accept any
`TimeType` (a `Date` is taken as midnight). Returns the stored [`Record`](@ref).
"""
function Base.insert!(
        s::BitemporalStore{K, V}, key, value;
        valid_from::TimeType, valid_to::TimeType = MAX_DT, ts::DateTime = now(UTC),
    ) where {K, V}
    vf, vt = _instant(valid_from), _instant(valid_to)
    _check_range(vf, vt)
    return put_record!(s, key, Record{V}(nothing, value, vf, vt, ts, MAX_DT))
end

"""
    correct!(s, key, value; valid_from, valid_to = MAX_DT, ts = now(UTC))

"We were wrong." Close every believed record overlapping the range, then append
the corrected `value`. History stays readable via [`as_of`](@ref) at an earlier `tx_at`.
"""
function correct!(
        s::BitemporalStore{K, V}, key, value;
        valid_from::TimeType, valid_to::TimeType = MAX_DT, ts::DateTime = now(UTC),
    ) where {K, V}
    vf, vt = _instant(valid_from), _instant(valid_to)
    _check_range(vf, vt)
    for r in get_records(s, key)
        if _believed(r) && _overlaps(r.valid_from, r.valid_to, vf, vt)
            close_tx!(s, r.id, ts)
        end
    end
    return put_record!(s, key, Record{V}(nothing, value, vf, vt, ts, MAX_DT))
end

# Turn a column spec into a `row -> value` accessor: a `Symbol` reads that column,
# a function is used as-is (for computed columns), anything else is a constant.
_accessor(spec::Symbol) = Base.Fix2(getcolumn, spec)
_accessor(spec::Base.Callable) = spec
_accessor(spec) = Returns(spec)

"""
    load!(s, table; key, value, valid_from, ts, valid_to = MAX_DT)

Bulk-load bitemporal observations from any [Tables.jl](https://github.com/JuliaData/Tables.jl)
source (a `DataFrame`, `CSV.File`, vector of `NamedTuple`s, ...). Each mapping is a
column-name `Symbol`, a `row -> value` function (for computed columns), or a
constant. Rows are processed in ascending `ts` order and each is recorded with
[`correct!`](@ref), so repeated observations of the same key and valid range chain
together in transaction time. Returns `s`.
"""
function load!(s::BitemporalStore, table; key, value, valid_from, ts, valid_to = MAX_DT)
    k, v, vf, vt, t = _accessor.((key, value, valid_from, valid_to, ts))
    for r in sort(collect(rows(table)); by = t)
        correct!(s, k(r), v(r); valid_from = vf(r), valid_to = vt(r), ts = t(r))
    end
    return s
end

"""
    amend!(s, key, value; effective, ts = now(UTC))

"The world changed on `effective`." Close the believed chapter(s) covering
`effective`, re-append the old value over `[valid_from, effective)`, and append
`value` from `effective` on. Errors if nothing covers `effective`.
"""
function amend!(
        s::BitemporalStore{K, V}, key, value;
        effective::TimeType, ts::DateTime = now(UTC),
    ) where {K, V}
    eff = _instant(effective)
    covering = filter(get_records(s, key)) do r
        _believed(r) && r.valid_from <= eff < r.valid_to
    end
    isempty(covering) &&
        throw(ArgumentError("no believed record covers effective date $eff"))
    for r in covering
        close_tx!(s, r.id, ts)
        r.valid_from < eff &&
            put_record!(s, key, Record{V}(nothing, r.value, r.valid_from, eff, ts, MAX_DT))
        put_record!(s, key, Record{V}(nothing, value, eff, r.valid_to, ts, MAX_DT))
    end
    return nothing
end

"""
    as_of(s, key; valid_at = now(UTC), tx_at = now(UTC)) -> Union{V,Nothing}

The value believed at `tx_at` to hold at `valid_at`, or `nothing`. `valid_at`
accepts any `TimeType` (a `Date` is taken as midnight).
"""
function as_of(
        s::BitemporalStore{K, V}, key;
        valid_at::TimeType = now(UTC), tx_at::DateTime = now(UTC),
    ) where {K, V}
    va = _instant(valid_at)
    hits = [
        r for r in get_records(s, key)
            if r.tx_from <= tx_at < r.tx_to && r.valid_from <= va < r.valid_to
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
