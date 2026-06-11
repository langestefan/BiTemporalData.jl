"""
    ThreadSafe(store)

Wrap any [`BitemporalStore`](@ref) with a single store-wide `ReentrantLock`.
Each operation locks once and runs its full primitive sequence atomically, so
multi-primitive writes (`correct!`, `amend!`, `retract!`) and compound reads
(`as_of_batch`, `diff`, `load!`) cannot interleave with a concurrent writer.
This is safety, not concurrency: one operation runs at a time, store-wide.

[`asof_join`](@ref) reads two stores and is not wrapped (locking two stores
needs an ordering protocol), so a join across concurrently-written stores is not
a single atomic read.
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
retract!(t::ThreadSafe, key; kw...) =
    lock(() -> retract!(t.store, key; kw...), t.lock)
as_of(t::ThreadSafe, key; kw...) = lock(() -> as_of(t.store, key; kw...), t.lock)
history(t::ThreadSafe, key) = lock(() -> history(t.store, key), t.lock)
snapshot(t::ThreadSafe; kw...) = lock(() -> snapshot(t.store; kw...), t.lock)
load!(t::ThreadSafe, table; kw...) = lock(() -> load!(t.store, table; kw...), t.lock)

# Compound reads run wholly under the lock, so they are a single consistent
# point-in-time read against concurrent writers. Threading the inner batch would
# not help (the lock already serializes), so force the serial path.
function as_of_batch(
        t::ThreadSafe{K, V}, keys::Vector{K},
        valid_ats::Vector{<:TimeType}, tx_ats::Vector{DateTime}; threaded::Bool = false,
    ) where {K, V}
    return lock(() -> as_of_batch(t.store, keys, valid_ats, tx_ats; threaded = false), t.lock)
end
Base.diff(t::ThreadSafe; kw...) = lock(() -> diff(t.store; kw...), t.lock)

# A wrapped store never threads its own reads: one operation runs at a time,
# store-wide, so concurrent get_records never happens (make it explicit).
supports_parallel_reads(::ThreadSafe) = false

# Primitives forwarded so the wrapper fully implements the interface. Operations
# above call `t.store` directly, so they never route through these.
get_records(t::ThreadSafe, key) = lock(() -> get_records(t.store, key), t.lock)
put_record!(t::ThreadSafe, key, r) = lock(() -> put_record!(t.store, key, r), t.lock)
close_tx!(t::ThreadSafe, id, ts) = lock(() -> close_tx!(t.store, id, ts), t.lock)
entities(t::ThreadSafe) = lock(() -> entities(t.store), t.lock)

# Forward the transaction hook to the inner store with no extra lock: the caller
# (an operation above) already holds it.
with_write_tx(f, t::ThreadSafe) = with_write_tx(f, t.store)
