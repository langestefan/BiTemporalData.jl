"""
    ThreadSafe(store)

Wrap any [`BitemporalStore`](@ref) with a single store-wide `ReentrantLock`.
Each operation locks once and runs its full primitive sequence atomically, so
multi-primitive writes (`correct!`, `amend!`) cannot interleave. This is safety,
not concurrency: one operation runs at a time, store-wide.
"""
struct ThreadSafe{K, V, S <: BitemporalStore{K, V}} <: BitemporalStore{K, V}
    store::S
    lock::ReentrantLock
end

ThreadSafe(store::BitemporalStore{K, V}) where {K, V} =
    ThreadSafe{K, V, typeof(store)}(store, ReentrantLock())

# Operations are the atomicity boundary: lock once around the whole inner call.
Base.insert!(t::ThreadSafe, key, value; kw...) =
    lock(() -> insert!(t.store, key, value; kw...), t.lock)
correct!(t::ThreadSafe, key, value; kw...) =
    lock(() -> correct!(t.store, key, value; kw...), t.lock)
amend!(t::ThreadSafe, key, value; kw...) =
    lock(() -> amend!(t.store, key, value; kw...), t.lock)
as_of(t::ThreadSafe, key; kw...) = lock(() -> as_of(t.store, key; kw...), t.lock)
history(t::ThreadSafe, key) = lock(() -> history(t.store, key), t.lock)
snapshot(t::ThreadSafe; kw...) = lock(() -> snapshot(t.store; kw...), t.lock)

# Primitives forwarded so the wrapper fully implements the interface. Operations
# above call `t.store` directly, so they never route through these.
get_records(t::ThreadSafe, key) = lock(() -> get_records(t.store, key), t.lock)
put_record!(t::ThreadSafe, key, r) = lock(() -> put_record!(t.store, key, r), t.lock)
close_tx!(t::ThreadSafe, id, ts) = lock(() -> close_tx!(t.store, id, ts), t.lock)
entities(t::ThreadSafe) = lock(() -> entities(t.store), t.lock)
