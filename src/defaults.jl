# Default operations on `BitemporalStore`, built from the four primitives. All
# ranges are half-open `[from, to)`; writes stamp `assertive_from = asserted_at`, `assertive_to = MAX_DT`.
# The `asserted_at` keyword is for test determinism; callers normally omit it.

function _check_range(effective_from::DateTime, effective_to::DateTime)
    effective_from < effective_to ||
        throw(ArgumentError("effective_from ($effective_from) must be before effective_to ($effective_to)"))
    return nothing
end

"""
    insert!(s, key, value; effective_from, effective_to = MAX_DT, asserted_at = now(UTC), check_overlap = false)

Record a new fact over `[effective_from, effective_to)`. `effective_from`/`effective_to` accept any
`TimeType` (a `Date` is taken as midnight). Returns the stored [`Record`](@ref).

By default `insert!` does not check for overlap with an existing asserted record:
two overlapping current assertions both stand, and a read resolves them by the
[`as_of`](@ref) tie rule (latest `assertive_from`, then the later write). To re-state a
fact, use [`correct!`](@ref), which closes the prior assertion first. Pass
`check_overlap = true` to instead reject an `insert!` that overlaps an asserted
record (it points you at `correct!`).
"""
function Base.insert!(
        s::BitemporalStore{K, V}, key, value;
        effective_from::TimeType, effective_to::TimeType = MAX_DT, asserted_at::TimeType = now(UTC),
        check_overlap::Bool = false,
    ) where {K, V}
    vf, vt, t = _instant(effective_from), _instant(effective_to), _instant(asserted_at)
    _check_range(vf, vt)
    if check_overlap
        for r in get_records(s, key)
            _asserted(r) && _overlaps(r.effective_from, r.effective_to, vf, vt) && throw(
                ArgumentError(
                    "insert! range [$vf, $vt) overlaps an asserted record for key $(repr(key)); use correct! to re-state",
                ),
            )
        end
    end
    return put_record!(s, key, Record{V}(nothing, value, vf, vt, t, MAX_DT))
end

# Shared close path for `correct!`/`retract!`: close every asserted record
# overlapping `[vf, vt)` at `asserted_at`, re-inserting the preserved slivers (the parts
# of a partially-overlapped record that fall outside `[vf, vt)`) with the old
# value. Returns the re-inserted sliver records. Validates assertive ordering up front
# (T5) so a rejected `asserted_at` leaves the store untouched, even on a backend with no
# rollback.
function _close_range!(
        s::BitemporalStore{K, V}, key, vf::DateTime, vt::DateTime, asserted_at::DateTime,
    ) where {K, V}
    overlapping = filter(get_records(s, key)) do r
        _asserted(r) && _overlaps(r.effective_from, r.effective_to, vf, vt)
    end
    for r in overlapping
        asserted_at >= r.assertive_from || throw(
            ArgumentError(
                "asserted_at ($asserted_at) predates the record's assertive_from ($(r.assertive_from)); assertive time is append-only",
            ),
        )
    end
    slivers = Record{V}[]
    for r in overlapping
        close_tx!(s, r.id, asserted_at)
        r.effective_from < vf &&
            push!(slivers, put_record!(s, key, Record{V}(nothing, r.value, r.effective_from, vf, asserted_at, MAX_DT)))
        vt < r.effective_to &&
            push!(slivers, put_record!(s, key, Record{V}(nothing, r.value, vt, r.effective_to, asserted_at, MAX_DT)))
    end
    return slivers
end

"""
    correct!(s, key, value; effective_from, effective_to = MAX_DT, asserted_at = now(UTC))

"We were wrong." Close every asserted record overlapping the range, then append
the corrected `value`. A record only partially overlapped keeps its surrounding
assertion: the slivers outside `[effective_from, effective_to)` are re-inserted with the old
value, so correcting a subrange never silently retracts the rest. History stays
readable via [`as_of`](@ref) at an earlier `assertive_at`. Returns the stored corrected
[`Record`](@ref).
"""
function correct!(
        s::BitemporalStore{K, V}, key, value;
        effective_from::TimeType, effective_to::TimeType = MAX_DT, asserted_at::TimeType = now(UTC),
    ) where {K, V}
    vf, vt, t = _instant(effective_from), _instant(effective_to), _instant(asserted_at)
    _check_range(vf, vt)
    return with_write_tx(s) do
        _close_range!(s, key, vf, vt, t)
        put_record!(s, key, Record{V}(nothing, value, vf, vt, t, MAX_DT))
    end
end

"""
    retract!(s, key; effective_from, effective_to = MAX_DT, asserted_at = now(UTC)) -> Vector{Record}

"There is no value here anymore." Close every asserted record overlapping
`[effective_from, effective_to)` without inserting a replacement, so [`as_of`](@ref) over
the range returns `nothing` at `assertive_at >= asserted_at` while the prior assertion stays
reproducible at an earlier `assertive_at`. A partially-overlapped record keeps its
surrounding slivers, exactly as [`correct!`](@ref). Returns the re-inserted
sliver records (empty for a full retraction).
"""
function retract!(
        s::BitemporalStore{K, V}, key;
        effective_from::TimeType, effective_to::TimeType = MAX_DT, asserted_at::TimeType = now(UTC),
    ) where {K, V}
    vf, vt, t = _instant(effective_from), _instant(effective_to), _instant(asserted_at)
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
    load!(s, table; key, value, effective_from, asserted_at, effective_to = MAX_DT)

Bulk-load bitemporal observations from any [Tables.jl](https://github.com/JuliaData/Tables.jl)
source (a `DataFrame`, `CSV.File`, vector of `NamedTuple`s, ...). Each mapping is a
column-name `Symbol`, a `row -> value` function (for computed columns), or a
constant. Rows are applied in ascending `asserted_at` order (ties keep source order) with
the same close/sliver/insert semantics as [`correct!`](@ref), so repeated
observations of the same key and valid range chain together in assertive time.
Returns `s`.

Each key's records are fetched once and the asserted set is maintained in memory
while its rows are applied, so loading N observations of one key costs one read
instead of N (the per-row `correct!` path re-read on every row). Each key's writes
run in one [`with_write_tx`](@ref).
"""
function load!(s::BitemporalStore{K, V}, table; key, value, effective_from, asserted_at, effective_to = MAX_DT) where {K, V}
    kf, valf, vff, vtf, tf = _accessor.((key, value, effective_from, effective_to, asserted_at))
    # Materialize once, normalizing key and time types up front.
    obs = [
        (
                key = convert(K, kf(r)), value = valf(r),
                vf = _instant(vff(r)), vt = _instant(vtf(r)), asserted_at = _instant(tf(r)),
            ) for r in rows(table)
    ]
    # Stable sort so ties on `asserted_at` keep source order (the later row wins the tie).
    sort!(obs; by = o -> o.asserted_at, alg = Base.Sort.MergeSort)
    # Group by key, preserving first-seen order for deterministic output.
    order = K[]
    bykey = Dict{K, Vector{eltype(obs)}}()
    for o in obs
        haskey(bykey, o.key) || push!(order, o.key)
        push!(get!(() -> eltype(obs)[], bykey, o.key), o)
    end
    for key in order
        with_write_tx(s) do
            asserted = filter(_asserted, get_records(s, key))
            for o in bykey[key]
                _check_range(o.vf, o.vt)
                remaining = Record{V}[]
                for r in asserted
                    if _overlaps(r.effective_from, r.effective_to, o.vf, o.vt)
                        o.asserted_at >= r.assertive_from || throw(
                            ArgumentError(
                                "asserted_at ($(o.asserted_at)) predates the record's assertive_from ($(r.assertive_from)); assertive time is append-only",
                            ),
                        )
                        close_tx!(s, r.id, o.asserted_at)
                        r.effective_from < o.vf &&
                            push!(remaining, put_record!(s, key, Record{V}(nothing, r.value, r.effective_from, o.vf, o.asserted_at, MAX_DT)))
                        o.vt < r.effective_to &&
                            push!(remaining, put_record!(s, key, Record{V}(nothing, r.value, o.vt, r.effective_to, o.asserted_at, MAX_DT)))
                    else
                        push!(remaining, r)   # untouched assertion carries forward
                    end
                end
                push!(remaining, put_record!(s, key, Record{V}(nothing, o.value, o.vf, o.vt, o.asserted_at, MAX_DT)))
                asserted = remaining
            end
        end
    end
    return s
end

"""
    amend!(s, key, value; effective, asserted_at = now(UTC)) -> Vector{Record}

"The world changed on `effective`." Close the asserted chapter(s) covering
`effective`, re-append the old value over `[effective_from, effective)`, and append
`value` from `effective` on. Errors if nothing covers `effective`. Returns the
newly inserted [`Record`](@ref)s.
"""
function amend!(
        s::BitemporalStore{K, V}, key, value;
        effective::TimeType, asserted_at::TimeType = now(UTC),
    ) where {K, V}
    eff, t = _instant(effective), _instant(asserted_at)
    covering = filter(get_records(s, key)) do r
        _asserted(r) && r.effective_from <= eff < r.effective_to
    end
    isempty(covering) &&
        throw(ArgumentError("no asserted record covers effective date $eff"))
    for r in covering
        t >= r.assertive_from || throw(
            ArgumentError(
                "asserted_at ($t) predates the record's assertive_from ($(r.assertive_from)); assertive time is append-only",
            ),
        )
    end
    return with_write_tx(s) do
        inserted = Record{V}[]
        for r in covering
            close_tx!(s, r.id, t)
            r.effective_from < eff &&
                push!(inserted, put_record!(s, key, Record{V}(nothing, r.value, r.effective_from, eff, t, MAX_DT)))
            push!(inserted, put_record!(s, key, Record{V}(nothing, value, eff, r.effective_to, t, MAX_DT)))
        end
        inserted
    end
end

# The as_of pick for one query: among the records whose assertion at `assertive_at` covers
# `effective_at`, the one with the maximal `assertive_from`. `>=` breaks ties by append order
# (the later write at the same instant wins; see T6), and is the single source of
# the selection rule shared by `as_of` and `as_of_batch`.
function _pick(recs, effective_at::DateTime, assertive_at::DateTime)
    best = nothing
    for r in recs
        if r.assertive_from <= assertive_at < r.assertive_to && r.effective_from <= effective_at < r.effective_to &&
                (best === nothing || r.assertive_from >= best.assertive_from)
            best = r
        end
    end
    return best === nothing ? nothing : best.value
end

"""
    as_of(s, key; effective_at = now(UTC), assertive_at = now(UTC)) -> Union{V,Nothing}

The value asserted at `assertive_at` to hold at `effective_at`, or `nothing`. Both `effective_at`
and `assertive_at` accept any `TimeType` (a `Date` is taken as midnight). When more than
one record is asserted over `effective_at` at `assertive_at`, the one with the latest
`assertive_from` wins, and a tie on `assertive_from` resolves to the later write (append order).

A record closed at the very instant it was created (`assertive_to == assertive_from`, e.g. a
correction whose `asserted_at` equals an earlier write's) has an empty assertion interval: it
never satisfies `assertive_from <= assertive_at < assertive_to`, so `as_of` never returns it, though
[`history`](@ref) still shows it. Assertive time has millisecond resolution
(`DateTime`), so distinct real-time writes rarely collide; [`load!`](@ref) rows
sharing a key, range, and `asserted_at` keep only the last (the later write wins the tie).
"""
function as_of(
        s::BitemporalStore{K, V}, key;
        effective_at::TimeType = now(UTC), assertive_at::TimeType = now(UTC),
    ) where {K, V}
    return _pick(get_records(s, key), _instant(effective_at), _instant(assertive_at))
end

"""
    history(s, key) -> NamedTuple of column vectors

Every record for `key` (including superseded), as a Tables.jl column table.
"""
function history(s::BitemporalStore{K, V}, key) where {K, V}
    rs = collect(get_records(s, key))
    return (
        value = V[r.value for r in rs],
        effective_from = [r.effective_from for r in rs],
        effective_to = [r.effective_to for r in rs],
        assertive_from = [r.assertive_from for r in rs],
        assertive_to = [r.assertive_to for r in rs],
    )
end
