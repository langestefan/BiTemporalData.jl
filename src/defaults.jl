# Default operations on `BitemporalStore`, built from the four primitives. All
# ranges are half-open `[from, to)`; writes stamp `tx_from = ts`, `tx_to = MAX_DT`.
# The `ts` keyword is for test determinism; callers normally omit it.

function _check_range(valid_from::DateTime, valid_to::DateTime)
    valid_from < valid_to ||
        throw(ArgumentError("valid_from ($valid_from) must be before valid_to ($valid_to)"))
    return nothing
end

"""
    insert!(s, key, value; valid_from, valid_to = MAX_DT, ts = now(UTC), check_overlap = false)

Record a new fact over `[valid_from, valid_to)`. `valid_from`/`valid_to` accept any
`TimeType` (a `Date` is taken as midnight). Returns the stored [`Record`](@ref).

By default `insert!` does not check for overlap with an existing believed record:
two overlapping current beliefs both stand, and a read resolves them by the
[`as_of`](@ref) tie rule (latest `tx_from`, then the later write). To re-state a
fact, use [`correct!`](@ref), which closes the prior belief first. Pass
`check_overlap = true` to instead reject an `insert!` that overlaps a believed
record (it points you at `correct!`).
"""
function Base.insert!(
        s::BitemporalStore{K, V}, key, value;
        valid_from::TimeType, valid_to::TimeType = MAX_DT, ts::TimeType = now(UTC),
        check_overlap::Bool = false,
    ) where {K, V}
    vf, vt, t = _instant(valid_from), _instant(valid_to), _instant(ts)
    _check_range(vf, vt)
    if check_overlap
        for r in get_records(s, key)
            _believed(r) && _overlaps(r.valid_from, r.valid_to, vf, vt) && throw(
                ArgumentError(
                    "insert! range [$vf, $vt) overlaps a believed record for key $(repr(key)); use correct! to re-state",
                ),
            )
        end
    end
    return put_record!(s, key, Record{V}(nothing, value, vf, vt, t, MAX_DT))
end

# Shared close path for `correct!`/`retract!`: close every believed record
# overlapping `[vf, vt)` at `ts`, re-inserting the preserved slivers (the parts
# of a partially-overlapped record that fall outside `[vf, vt)`) with the old
# value. Returns the re-inserted sliver records. Validates tx ordering up front
# (T5) so a rejected `ts` leaves the store untouched, even on a backend with no
# rollback.
function _close_range!(
        s::BitemporalStore{K, V}, key, vf::DateTime, vt::DateTime, ts::DateTime,
    ) where {K, V}
    overlapping = filter(get_records(s, key)) do r
        _believed(r) && _overlaps(r.valid_from, r.valid_to, vf, vt)
    end
    for r in overlapping
        ts >= r.tx_from || throw(
            ArgumentError(
                "ts ($ts) predates the record's tx_from ($(r.tx_from)); transaction time is append-only",
            ),
        )
    end
    slivers = Record{V}[]
    for r in overlapping
        close_tx!(s, r.id, ts)
        r.valid_from < vf &&
            push!(slivers, put_record!(s, key, Record{V}(nothing, r.value, r.valid_from, vf, ts, MAX_DT)))
        vt < r.valid_to &&
            push!(slivers, put_record!(s, key, Record{V}(nothing, r.value, vt, r.valid_to, ts, MAX_DT)))
    end
    return slivers
end

"""
    correct!(s, key, value; valid_from, valid_to = MAX_DT, ts = now(UTC))

"We were wrong." Close every believed record overlapping the range, then append
the corrected `value`. A record only partially overlapped keeps its surrounding
belief: the slivers outside `[valid_from, valid_to)` are re-inserted with the old
value, so correcting a subrange never silently retracts the rest. History stays
readable via [`as_of`](@ref) at an earlier `tx_at`. Returns the stored corrected
[`Record`](@ref).
"""
function correct!(
        s::BitemporalStore{K, V}, key, value;
        valid_from::TimeType, valid_to::TimeType = MAX_DT, ts::TimeType = now(UTC),
    ) where {K, V}
    vf, vt, t = _instant(valid_from), _instant(valid_to), _instant(ts)
    _check_range(vf, vt)
    return with_write_tx(s) do
        _close_range!(s, key, vf, vt, t)
        put_record!(s, key, Record{V}(nothing, value, vf, vt, t, MAX_DT))
    end
end

"""
    retract!(s, key; valid_from, valid_to = MAX_DT, ts = now(UTC)) -> Vector{Record}

"There is no value here anymore." Close every believed record overlapping
`[valid_from, valid_to)` without inserting a replacement, so [`as_of`](@ref) over
the range returns `nothing` at `tx_at >= ts` while the prior belief stays
reproducible at an earlier `tx_at`. A partially-overlapped record keeps its
surrounding slivers, exactly as [`correct!`](@ref). Returns the re-inserted
sliver records (empty for a full retraction).
"""
function retract!(
        s::BitemporalStore{K, V}, key;
        valid_from::TimeType, valid_to::TimeType = MAX_DT, ts::TimeType = now(UTC),
    ) where {K, V}
    vf, vt, t = _instant(valid_from), _instant(valid_to), _instant(ts)
    _check_range(vf, vt)
    return with_write_tx(s) do
        _close_range!(s, key, vf, vt, t)
    end
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
constant. Rows are applied in ascending `ts` order (ties keep source order) with
the same close/sliver/insert semantics as [`correct!`](@ref), so repeated
observations of the same key and valid range chain together in transaction time.
Returns `s`.

Each key's records are fetched once and the believed set is maintained in memory
while its rows are applied, so loading N observations of one key costs one read
instead of N (the per-row `correct!` path re-read on every row). Each key's writes
run in one [`with_write_tx`](@ref).
"""
function load!(s::BitemporalStore{K, V}, table; key, value, valid_from, ts, valid_to = MAX_DT) where {K, V}
    kf, valf, vff, vtf, tf = _accessor.((key, value, valid_from, valid_to, ts))
    # Materialize once, normalizing key and time types up front.
    obs = [
        (
                key = convert(K, kf(r)), value = valf(r),
                vf = _instant(vff(r)), vt = _instant(vtf(r)), ts = _instant(tf(r)),
            ) for r in rows(table)
    ]
    # Stable sort so ties on `ts` keep source order (the later row wins the tie).
    sort!(obs; by = o -> o.ts, alg = Base.Sort.MergeSort)
    # Group by key, preserving first-seen order for deterministic output.
    order = K[]
    bykey = Dict{K, Vector{eltype(obs)}}()
    for o in obs
        haskey(bykey, o.key) || push!(order, o.key)
        push!(get!(() -> eltype(obs)[], bykey, o.key), o)
    end
    for key in order
        with_write_tx(s) do
            believed = filter(_believed, get_records(s, key))
            for o in bykey[key]
                _check_range(o.vf, o.vt)
                remaining = Record{V}[]
                for r in believed
                    if _overlaps(r.valid_from, r.valid_to, o.vf, o.vt)
                        o.ts >= r.tx_from || throw(
                            ArgumentError(
                                "ts ($(o.ts)) predates the record's tx_from ($(r.tx_from)); transaction time is append-only",
                            ),
                        )
                        close_tx!(s, r.id, o.ts)
                        r.valid_from < o.vf &&
                            push!(remaining, put_record!(s, key, Record{V}(nothing, r.value, r.valid_from, o.vf, o.ts, MAX_DT)))
                        o.vt < r.valid_to &&
                            push!(remaining, put_record!(s, key, Record{V}(nothing, r.value, o.vt, r.valid_to, o.ts, MAX_DT)))
                    else
                        push!(remaining, r)   # untouched belief carries forward
                    end
                end
                push!(remaining, put_record!(s, key, Record{V}(nothing, o.value, o.vf, o.vt, o.ts, MAX_DT)))
                believed = remaining
            end
        end
    end
    return s
end

"""
    amend!(s, key, value; effective, ts = now(UTC)) -> Vector{Record}

"The world changed on `effective`." Close the believed chapter(s) covering
`effective`, re-append the old value over `[valid_from, effective)`, and append
`value` from `effective` on. Errors if nothing covers `effective`. Returns the
newly inserted [`Record`](@ref)s.
"""
function amend!(
        s::BitemporalStore{K, V}, key, value;
        effective::TimeType, ts::TimeType = now(UTC),
    ) where {K, V}
    eff, t = _instant(effective), _instant(ts)
    covering = filter(get_records(s, key)) do r
        _believed(r) && r.valid_from <= eff < r.valid_to
    end
    isempty(covering) &&
        throw(ArgumentError("no believed record covers effective date $eff"))
    for r in covering
        t >= r.tx_from || throw(
            ArgumentError(
                "ts ($t) predates the record's tx_from ($(r.tx_from)); transaction time is append-only",
            ),
        )
    end
    return with_write_tx(s) do
        inserted = Record{V}[]
        for r in covering
            close_tx!(s, r.id, t)
            r.valid_from < eff &&
                push!(inserted, put_record!(s, key, Record{V}(nothing, r.value, r.valid_from, eff, t, MAX_DT)))
            push!(inserted, put_record!(s, key, Record{V}(nothing, value, eff, r.valid_to, t, MAX_DT)))
        end
        inserted
    end
end

# The as_of pick for one query: among the records whose belief at `tx_at` covers
# `valid_at`, the one with the maximal `tx_from`. `>=` breaks ties by append order
# (the later write at the same instant wins; see T6), and is the single source of
# the selection rule shared by `as_of` and `as_of_batch`.
function _pick(recs, valid_at::DateTime, tx_at::DateTime)
    best = nothing
    for r in recs
        if r.tx_from <= tx_at < r.tx_to && r.valid_from <= valid_at < r.valid_to &&
                (best === nothing || r.tx_from >= best.tx_from)
            best = r
        end
    end
    return best === nothing ? nothing : best.value
end

"""
    as_of(s, key; valid_at = now(UTC), tx_at = now(UTC)) -> Union{V,Nothing}

The value believed at `tx_at` to hold at `valid_at`, or `nothing`. Both `valid_at`
and `tx_at` accept any `TimeType` (a `Date` is taken as midnight). When more than
one record is believed over `valid_at` at `tx_at`, the one with the latest
`tx_from` wins, and a tie on `tx_from` resolves to the later write (append order).

A record closed at the very instant it was created (`tx_to == tx_from`, e.g. a
correction whose `ts` equals an earlier write's) has an empty belief interval: it
never satisfies `tx_from <= tx_at < tx_to`, so `as_of` never returns it, though
[`history`](@ref) still shows it. Transaction time has millisecond resolution
(`DateTime`), so distinct real-time writes rarely collide; [`load!`](@ref) rows
sharing a key, range, and `ts` keep only the last (the later write wins the tie).
"""
function as_of(
        s::BitemporalStore{K, V}, key;
        valid_at::TimeType = now(UTC), tx_at::TimeType = now(UTC),
    ) where {K, V}
    return _pick(get_records(s, key), _instant(valid_at), _instant(tx_at))
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
