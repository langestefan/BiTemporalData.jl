# The four primitives every backend must implement. The default operations in
# `defaults.jl` and `snapshot.jl` are written entirely in terms of these.

"""
    get_records(s::BitemporalStore, key) -> iterable of Record

Return all records ever written for `key`, in append order, including
superseded ones (those with a closed `tx_to`). Return an empty iterable for an
unknown key.
"""
function get_records end

"""
    put_record!(s::BitemporalStore, key, record::Record) -> Record

Append `record` under `key`. The incoming `record` carries `id = nothing`; the
backend assigns an `id` and returns the populated `Record`.
"""
function put_record! end

"""
    close_tx!(s::BitemporalStore, id, ts::DateTime) -> Nothing

Close the transaction interval of the record identified by `id`, setting its
`tx_to` to `ts`. Idempotent: closing an already-closed record is a no-op.
"""
function close_tx! end

"""
    entities(s::BitemporalStore) -> iterable of K

Return every key the store knows about. This is what lets store-wide operations
(such as [`snapshot`](@ref)) work without a key argument.
"""
function entities end
