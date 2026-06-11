# The four primitives every backend implements.

"`get_records(s, key)`: all records for `key` in append order; empty if unknown."
function get_records end

"`put_record!(s, key, record)`: append `record` (`id = nothing`); return it with `id` assigned."
function put_record! end

"`close_tx!(s, id, ts)`: set the record's `tx_to` to `ts`. Idempotent."
function close_tx! end

"""
`entities(s)`: all keys the store knows about. The returned iterable must be
safe to iterate after the call returns, i.e. detached from the store's internal
state (return a snapshot, not a live view), so a caller behind [`ThreadSafe`](@ref)
can iterate it once the lock is released.
"""
function entities end

# An optional fifth hook: run a multi-statement write atomically.

"""
    with_write_tx(f, s)

Run `f()` atomically on `s` if the backend supports transactions, otherwise just
`f()`. Multi-step writes (`correct!`, `amend!`, `retract!`) wrap their body in
this so a crash midway cannot leave a transactional backend half-updated. The
default is a no-op (`f()`); transactional backends override it. Returns `f()`'s
value.
"""
with_write_tx(f, ::BitemporalStore) = f()
