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
    # `table` is developer-controlled, so interpolating it is safe; all data is
    # bound as parameters. DuckDB has no implicit rowid, so `id` is drawn from a
    # sequence and read back with `RETURNING`.
    execute(db, "CREATE SEQUENCE IF NOT EXISTS $(_seq(table))")
    execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS $table (
            id BIGINT PRIMARY KEY DEFAULT nextval('$(_seq(table))'),
            key BLOB NOT NULL,
            value BLOB NOT NULL,
            valid_from BIGINT NOT NULL,
            valid_to BIGINT NOT NULL,
            tx_from BIGINT NOT NULL,
            tx_to BIGINT NOT NULL
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
        "INSERT INTO $(s.table) (key, value, valid_from, valid_to, tx_from, tx_to) " *
            "VALUES (?, ?, ?, ?, ?, ?) RETURNING id",
        (
            # Normalize the key to `K` first: serialization is type-sensitive, so
            # the blob must not depend on the caller's concrete argument type.
            _blob(convert(K, key)), _blob(r.value),
            Dates.value(r.valid_from), Dates.value(r.valid_to),
            Dates.value(r.tx_from), Dates.value(r.tx_to),
        ),
    )
    id = first(res).id
    return Record{V}(id, r.value, r.valid_from, r.valid_to, r.tx_from, r.tx_to)
end

function get_records(s::DuckDBStore{K, V}, key) where {K, V}
    out = Record{V}[]
    for row in execute(
            s.db,
            "SELECT id, value, valid_from, valid_to, tx_from, tx_to " *
                "FROM $(s.table) WHERE key = ? ORDER BY id",
            (_blob(convert(K, key)),),
        )
        push!(
            out,
            Record{V}(
                row.id, _unblob(row.value),
                _dt(row.valid_from), _dt(row.valid_to),
                _dt(row.tx_from), _dt(row.tx_to),
            ),
        )
    end
    return out
end

function close_tx!(s::DuckDBStore, id, ts::DateTime)
    # Idempotent: the `tx_to = MAX_DT` guard means a second call matches no rows.
    execute(
        s.db,
        "UPDATE $(s.table) SET tx_to = ? WHERE id = ? AND tx_to = ?",
        (Dates.value(ts), id, Dates.value(MAX_DT)),
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
# DuckDB backend. Output shape matches the generic `snapshot` exactly.

function snapshot(
        s::DuckDBStore{K, V};
        valid_at::Union{TimeType, Nothing} = nothing, tx_at::DateTime = now(UTC),
    ) where {K, V}
    t = Dates.value(tx_at)
    if valid_at === nothing
        ent = K[]
        val = V[]
        vf = DateTime[]
        vt = DateTime[]
        for row in execute(
                s.db,
                "SELECT key, value, valid_from, valid_to FROM $(s.table) " *
                    "WHERE tx_from <= ? AND ? < tx_to ORDER BY key, id",
                (t, t),
            )
            push!(ent, _unblob(row.key))
            push!(val, _unblob(row.value))
            push!(vf, _dt(row.valid_from))
            push!(vt, _dt(row.valid_to))
        end
        return (entity = ent, value = val, valid_from = vf, valid_to = vt)
    else
        v = Dates.value(_instant(valid_at))
        ent = K[]
        val = V[]
        # Per entity, the value with the latest tx_from among records that the
        # belief at `tx_at` holds over `valid_at`: the SQL form of `as_of`.
        for row in execute(
                s.db,
                "SELECT key, value FROM (" *
                    "SELECT key, value, " *
                    # `id DESC` breaks tx_from ties by append order, matching _pick (T6).
                    "row_number() OVER (PARTITION BY key ORDER BY tx_from DESC, id DESC) AS rn " *
                    "FROM $(s.table) " *
                    "WHERE tx_from <= ? AND ? < tx_to AND valid_from <= ? AND ? < valid_to" *
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
