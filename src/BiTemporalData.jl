module BiTemporalData

using Dates: Date, DateTime, now, today

include("types.jl")
include("interface.jl")
include("defaults.jl")
include("snapshot.jl")
include("analytical.jl")
include("memory.jl")
include("threadsafe.jl")

# Core types and sentinels
export BitemporalStore, MAX_DATE, MAX_DT, MemoryStore, Record, ThreadSafe

# Default operations (insert! and diff extend Base, so they are not re-exported)
export amend!, as_of, as_of_batch, asof_join, correct!, history, snapshot

# Backend primitives (for authors of new backends)
export close_tx!, entities, get_records, put_record!

end
