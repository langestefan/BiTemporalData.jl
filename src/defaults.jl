# Default operations on the abstract `BitemporalStore`, built only from the four
# primitives in `interface.jl`. Backends inherit these automatically and may
# override any one with a faster native path.

# All ranges are half-open `[from, to)`. Writes stamp `tx_from = ts` and leave
# `tx_to = MAX_DT` ("currently believed"). The `ts` keyword exists for test
# determinism; production callers should omit it.

_currently_believed(r::Record) = r.tx_to == MAX_DT

function _check_range(valid_from::Date, valid_to::Date)
    valid_from < valid_to || throw(
        ArgumentError(
            "valid_from ($valid_from) must be strictly before valid_to ($valid_to)",
        ),
    )
    return nothing
end

"""
    insert!(s::BitemporalStore, key, value; valid_from, valid_to = MAX_DATE, ts = now())

Record a new fact: `value` holds over `[valid_from, valid_to)`. Appends exactly
one record. Returns the populated [`Record`](@ref).
"""
function Base.insert!(
        s::BitemporalStore{K, V},
        key,
        value;
        valid_from::Date,
        valid_to::Date = MAX_DATE,
        ts::DateTime = now(),
    ) where {K, V}
    _check_range(valid_from, valid_to)
    return put_record!(s, key, Record{V}(nothing, value, valid_from, valid_to, ts, MAX_DT))
end

"""
    correct!(s::BitemporalStore, key, value; valid_from, valid_to = MAX_DATE, ts = now())

"We were wrong about the value over this valid range." Closes `tx_to` on every
currently-believed record overlapping `[valid_from, valid_to)`, then appends one
new record carrying the corrected `value` over that range. History is preserved:
the superseded records remain readable via [`history`](@ref) and [`as_of`](@ref)
at an earlier `tx_at`.
"""
function correct!(
        s::BitemporalStore{K, V},
        key,
        value;
        valid_from::Date,
        valid_to::Date = MAX_DATE,
        ts::DateTime = now(),
    ) where {K, V}
    _check_range(valid_from, valid_to)
    for r in get_records(s, key)
        if _currently_believed(r) && _overlaps(r.valid_from, r.valid_to, valid_from, valid_to)
            close_tx!(s, r.id, ts)
        end
    end
    return put_record!(s, key, Record{V}(nothing, value, valid_from, valid_to, ts, MAX_DT))
end

"""
    amend!(s::BitemporalStore, key, value; effective, ts = now())

"The world changed on `effective`." Splits the timeline: closes the
currently-believed chapter(s) covering `effective`, re-appends the prior value
trimmed to `[valid_from, effective)`, and appends `value` from `effective`
onward. Throws `ArgumentError` if no currently-believed record covers
`effective`.
"""
function amend!(
        s::BitemporalStore{K, V},
        key,
        value;
        effective::Date,
        ts::DateTime = now(),
    ) where {K, V}
    covering = [
        r for r in get_records(s, key) if
            _currently_believed(r) && r.valid_from <= effective < r.valid_to
    ]
    isempty(covering) && throw(
        ArgumentError("no currently-believed record covers effective date $effective"),
    )
    for r in covering
        close_tx!(s, r.id, ts)
        if r.valid_from < effective
            # The old value still holds up to (but not including) the change.
            put_record!(
                s,
                key,
                Record{V}(nothing, r.value, r.valid_from, effective, ts, MAX_DT),
            )
        end
        # The new chapter runs from the change to the end of the old chapter.
        put_record!(s, key, Record{V}(nothing, value, effective, r.valid_to, ts, MAX_DT))
    end
    return nothing
end

"""
    as_of(s::BitemporalStore, key; valid_at = today(), tx_at = now()) -> Union{V,Nothing}

The value the system believed at `tx_at` was true at `valid_at`, or `nothing` if
the key had no such value. Read-only.
"""
function as_of(
        s::BitemporalStore{K, V},
        key;
        valid_at::Date = today(),
        tx_at::DateTime = now(),
    ) where {K, V}
    best::Union{Record{V}, Nothing} = nothing
    for r in get_records(s, key)
        if r.tx_from <= tx_at < r.tx_to &&
                r.valid_from <= valid_at < r.valid_to &&
                (best === nothing || r.tx_from > best.tx_from)
            best = r
        end
    end
    return best === nothing ? nothing : best.value
end

"""
    history(s::BitemporalStore, key) -> NamedTuple of column vectors

Every record ever written for `key`, including superseded ones, as a columnar
table with columns `value`, `valid_from`, `valid_to`, `tx_from`, `tx_to`. The
result is a Tables.jl-compatible column table (a `NamedTuple` of equal-length
vectors).
"""
function history(s::BitemporalStore{K, V}, key) where {K, V}
    rs = collect(get_records(s, key))
    return (
        value = V[r.value for r in rs],
        valid_from = Date[r.valid_from for r in rs],
        valid_to = Date[r.valid_to for r in rs],
        tx_from = DateTime[r.tx_from for r in rs],
        tx_to = DateTime[r.tx_to for r in rs],
    )
end
