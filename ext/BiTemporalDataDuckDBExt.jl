module BiTemporalDataDuckDBExt

# DuckDB re-exports DBInterface, so loading DuckDB is enough to load the
# extension; we reach `execute` through it.
using DuckDB: DuckDB, DB
using DuckDB.DBInterface: execute
using Serialization: serialize, deserialize
using Dates: Dates, DateTime, TimeType, UTC, now
using BiTemporalData: DuckDBStore, Record, MAX_DT, _instant
import BiTemporalData: get_records, put_record!, close_tx!, entities, snapshot, with_write_tx

# Generic (de)serialization of keys and values to/from DuckDB BLOBs.
_blob(x) = (io = IOBuffer(); serialize(io, x); take!(io))
_unblob(b) = deserialize(IOBuffer(Vector{UInt8}(b)))

# All four times are `DateTime`, stored as their integer `Dates.value`.
_dt(n) = DateTime(Dates.UTM(n))

_seq(table) = "$(table)_id_seq"

# --- constructors ---------------------------------------------------------

function DuckDBStore{K, V}(db::DB; table::AbstractString = "records") where {K, V}
    # `table` is interpolated into SQL (no parameter binding for identifiers), so
    # restrict it to a plain identifier; all data is bound as parameters. DuckDB
    # has no implicit rowid, so `id` is drawn from a sequence and read back with
    # `RETURNING`.
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", table) ||
        throw(ArgumentError("invalid table name $(repr(table)); must match ^[A-Za-z_][A-Za-z0-9_]*\$"))
    execute(db, "CREATE SEQUENCE IF NOT EXISTS $(_seq(table))")
    execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS $table (
            id BIGINT PRIMARY KEY DEFAULT nextval('$(_seq(table))'),
            key BLOB NOT NULL,
            value BLOB NOT NULL,
            effective_from BIGINT NOT NULL,
            effective_to BIGINT NOT NULL,
            assertive_from BIGINT NOT NULL,
            assertive_to BIGINT NOT NULL
        )
        """,
    )
    return DuckDBStore{K, V, typeof(db)}(db, String(table))
end

function DuckDBStore{K, V}(path::AbstractString; table::AbstractString = "records") where {K, V}
    return DuckDBStore{K, V}(DB(path); table)
end

# --- primitives -----------------------------------------------------------

function put_record!(s::DuckDBStore{K, V}, key, r::Record{V}) where {K, V}
    res = execute(
        s.db,
        "INSERT INTO $(s.table) (key, value, effective_from, effective_to, assertive_from, assertive_to) " *
            "VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
        (
            # Normalize the key to `K` first: serialization is type-sensitive, so
            # the blob must not depend on the caller's concrete argument type.
            _blob(convert(K, key)), _blob(r.value),
            Dates.value(r.effective_from), Dates.value(r.effective_to),
            Dates.value(r.assertive_from), Dates.value(r.assertive_to),
        ),
    )
    id = first(res).id
    return Record{V}(id, r.value, r.effective_from, r.effective_to, r.assertive_from, r.assertive_to)
end

function get_records(s::DuckDBStore{K, V}, key) where {K, V}
    out = Record{V}[]
    for row in execute(
            s.db,
            "SELECT id, value, effective_from, effective_to, assertive_from, assertive_to " *
                "FROM $(s.table) WHERE key = ? ORDER BY id",
            (_blob(convert(K, key)),),
        )
        push!(
            out,
            Record{V}(
                row.id, _unblob(row.value),
                _dt(row.effective_from), _dt(row.effective_to),
                _dt(row.assertive_from), _dt(row.assertive_to),
            ),
        )
    end
    return out
end

function close_tx!(s::DuckDBStore, id, asserted_at::DateTime)
    # Idempotent: the `assertive_to = MAX_DT` guard means a second call matches no rows.
    execute(
        s.db,
        "UPDATE $(s.table) SET assertive_to = ? WHERE id = ? AND assertive_to = ?",
        (Dates.value(asserted_at), id, Dates.value(MAX_DT)),
    )
    return nothing
end

function entities(s::DuckDBStore{K, V}) where {K, V}
    return K[_unblob(row.key) for row in execute(s.db, "SELECT DISTINCT key FROM $(s.table)")]
end

# DuckDB is transactional, but DBInterface.transaction is not wired up, so drive
# it by hand: COMMIT on success, ROLLBACK and rethrow on error, so a failed
# correct!/amend!/retract! leaves the file unchanged.
function with_write_tx(f, s::DuckDBStore)
    execute(s.db, "BEGIN TRANSACTION")
    try
        result = f()
        execute(s.db, "COMMIT")
        return result
    catch
        execute(s.db, "ROLLBACK")
        rethrow()
    end
end

# --- native snapshot ------------------------------------------------------
# Override the default per-entity walk with one columnar query: the point of a
# DuckDB backend. The output column *shape* matches the generic `snapshot`; the
# row order is backend-defined (callers must not rely on it).

function snapshot(
        s::DuckDBStore{K, V};
        effective_at::Union{TimeType, Nothing} = nothing, assertive_at::TimeType = now(UTC),
    ) where {K, V}
    t = Dates.value(_instant(assertive_at))
    if effective_at === nothing
        ent = K[]
        val = V[]
        vf = DateTime[]
        vt = DateTime[]
        for row in execute(
                s.db,
                "SELECT key, value, effective_from, effective_to FROM $(s.table) " *
                    "WHERE assertive_from <= ? AND ? < assertive_to ORDER BY key, id",
                (t, t),
            )
            push!(ent, _unblob(row.key))
            push!(val, _unblob(row.value))
            push!(vf, _dt(row.effective_from))
            push!(vt, _dt(row.effective_to))
        end
        return (entity = ent, value = val, effective_from = vf, effective_to = vt)
    else
        v = Dates.value(_instant(effective_at))
        ent = K[]
        val = V[]
        # Per entity, the value with the latest assertive_from among records that the
        # assertion at `assertive_at` holds over `effective_at`: the SQL form of `as_of`.
        for row in execute(
                s.db,
                "SELECT key, value FROM (" *
                    "SELECT key, value, " *
                    # `id DESC` breaks assertive_from ties by append order, matching _pick (T6).
                    "row_number() OVER (PARTITION BY key ORDER BY assertive_from DESC, id DESC) AS rn " *
                    "FROM $(s.table) " *
                    "WHERE assertive_from <= ? AND ? < assertive_to AND effective_from <= ? AND ? < effective_to" *
                    ") WHERE rn = 1 ORDER BY key",
                (t, t, v, v),
            )
            push!(ent, _unblob(row.key))
            push!(val, _unblob(row.value))
        end
        return (entity = ent, value = val)
    end
end

end # module
