module BiTemporalData

using Dates: Date, DateTime, now, today

include("types.jl")
include("interface.jl")
include("defaults.jl")
include("snapshot.jl")
include("memory.jl")

# Core types and sentinels
export BitemporalStore, MAX_DATE, MAX_DT, MemoryStore, Record

# Default operations (insert! extends Base.insert!, so it is not re-exported)
export amend!, as_of, correct!, history, snapshot

# Backend primitives (for authors of new backends)
export close_tx!, entities, get_records, put_record!

end
