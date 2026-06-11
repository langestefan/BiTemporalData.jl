module BiTemporalDataSQLiteExt

# SQLite re-exports DBInterface, so loading SQLite is enough to load the
# extension; we reach `execute`/`lastrowid` through it.
using SQLite: SQLite, DB
using SQLite.DBInterface: execute, lastrowid
using Serialization: serialize, deserialize
using Dates: Dates, DateTime, TimeType, UTC, now
using BiTemporalData: SQLiteStore, Record, MAX_DT, _instant
import BiTemporalData: get_records, put_record!, close_tx!, entities, snapshot, with_write_tx

# Generic (de)serialization of keys and values to/from SQLite BLOBs.
_blob(x) = (io = IOBuffer(); serialize(io, x); take!(io))
_unblob(b) = deserialize(IOBuffer(b))

# All four times are `DateTime`, stored as their integer `Dates.value`.
_dt(n) = DateTime(Dates.UTM(n))

# --- constructors ---------------------------------------------------------

function SQLiteStore{K, V}(db::DB; table::AbstractString = "records") where {K, V}
    # `table` is interpolated into SQL (no parameter binding for identifiers), so
    # restrict it to a plain identifier; all data is bound as parameters.
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", table) ||
        throw(ArgumentError("invalid table name $(repr(table)); must match ^[A-Za-z_][A-Za-z0-9_]*\$"))
    execute(
        db,
        """
        CREATE TABLE IF NOT EXISTS $table (
            id INTEGER PRIMARY KEY,
            key BLOB NOT NULL,
            value BLOB NOT NULL,
            effective_from INTEGER NOT NULL,
            effective_to INTEGER NOT NULL,
            assertive_from INTEGER NOT NULL,
            assertive_to INTEGER NOT NULL
        )
        """,
    )
    execute(db, "CREATE INDEX IF NOT EXISTS idx_$(table)_key ON $table (key)")
    return SQLiteStore{K, V, typeof(db)}(db, String(table))
end

function SQLiteStore{K, V}(path::AbstractString; table::AbstractString = "records") where {K, V}
    return SQLiteStore{K, V}(DB(path); table)
end

# --- primitives -----------------------------------------------------------

function put_record!(s::SQLiteStore{K, V}, key, r::Record{V}) where {K, V}
    res = execute(
        s.db,
        "INSERT INTO $(s.table) (key, value, effective_from, effective_to, assertive_from, assertive_to) " *
            "VALUES (?, ?, ?, ?, ?, ?)",
        (
            # Normalize the key to `K` first: serialization is type-sensitive, so
            # the blob must not depend on the caller's concrete argument type
            # (e.g. an `InlineString` from CSV vs a `String`).
            _blob(convert(K, key)), _blob(r.value),
            Dates.value(r.effective_from), Dates.value(r.effective_to),
            Dates.value(r.assertive_from), Dates.value(r.assertive_to),
        ),
    )
    id = lastrowid(res)
    return Record{V}(id, r.value, r.effective_from, r.effective_to, r.assertive_from, r.assertive_to)
end

function get_records(s::SQLiteStore{K, V}, key) where {K, V}
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

function close_tx!(s::SQLiteStore, id, asserted_at::DateTime)
    # Idempotent: the `assertive_to = MAX_DT` guard means a second call matches no rows.
    execute(
        s.db,
        "UPDATE $(s.table) SET assertive_to = ? WHERE id = ? AND assertive_to = ?",
        (Dates.value(asserted_at), id, Dates.value(MAX_DT)),
    )
    return nothing
end

function entities(s::SQLiteStore{K, V}) where {K, V}
    return K[_unblob(row.key) for row in execute(s.db, "SELECT DISTINCT key FROM $(s.table)")]
end

# SQLite is transactional: run a multi-statement write atomically. `transaction`
# rolls back and rethrows if `f` errors, so a failed correct!/amend!/retract!
# leaves the file unchanged.
with_write_tx(f, s::SQLiteStore) = SQLite.transaction(f, s.db)

# --- native snapshot ------------------------------------------------------
# Replace the generic N+1 walk (entities + one get_records per key) with one
# window-function query, the same form as the DuckDB backend. Output column
# shape matches the generic `snapshot`; row order is backend-defined.

function snapshot(
        s::SQLiteStore{K, V};
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
        # `id DESC` breaks assertive_from ties by append order, matching _pick.
        for row in execute(
                s.db,
                "SELECT key, value FROM (" *
                    "SELECT key, value, " *
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
