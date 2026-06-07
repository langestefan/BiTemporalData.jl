module BiTemporalData

using Base.Threads: @threads
using Dates: DateTime, TimeType, now
using Tables: getcolumn, rows

include("types.jl")
include("interface.jl")
include("defaults.jl")
include("snapshot.jl")
include("analytical.jl")
include("memory.jl")
include("columnar.jl")
include("sqlite.jl")
include("duckdb.jl")
include("threadsafe.jl")
include("display.jl")

# Core types and sentinels
export BitemporalStore, ColumnarStore,
    DuckDBStore, MAX_DT, MemoryStore, Record, SQLiteStore, ThreadSafe

# Default operations (insert! and diff extend Base, so they are not re-exported)
export amend!, as_of, as_of_batch, asof_join, correct!, history, load!, snapshot

# Backend primitives and traits (for authors of new backends)
export close_tx!, entities, get_records, put_record!, supports_parallel_reads

end
