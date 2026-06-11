# `ThreadSafe` wraps any backend with a store-wide lock. On Julia >= 1.11 the
# store is held in a `Base.Lockable`, so the inner store is only reachable while
# the lock is held (`lock(f, lockable)` runs `f(value)` under the lock); on 1.10
# we keep the equivalent `(store, lock)` pair. The difference is confined to the
# struct and the internal `_locked` helper; every method below is written once.
@static if VERSION >= v"1.11"
    struct ThreadSafe{K, V, S <: BitemporalStore{K, V}} <: BitemporalStore{K, V}
        lockable::Base.Lockable{S, ReentrantLock}
    end
    ThreadSafe(store::BitemporalStore{K, V}) where {K, V} =
        ThreadSafe{K, V, typeof(store)}(Base.Lockable(store, ReentrantLock()))
    # Run `f(inner_store)` while holding the lock.
    _locked(f, t::ThreadSafe) = lock(f, t.lockable)
else
    struct ThreadSafe{K, V, S <: BitemporalStore{K, V}} <: BitemporalStore{K, V}
        store::S
        lock::ReentrantLock
    end
    ThreadSafe(store::BitemporalStore{K, V}) where {K, V} =
        ThreadSafe{K, V, typeof(store)}(store, ReentrantLock())
    # Run `f(inner_store)` while holding the lock.
    _locked(f, t::ThreadSafe) = lock(() -> f(t.store), t.lock)
end

"""
    ThreadSafe(store)

Wrap any [`BitemporalStore`](@ref) with a single store-wide `ReentrantLock`.
Each operation locks once and runs its full primitive sequence atomically, so
multi-primitive writes (`correct!`, `amend!`, `retract!`) and compound reads
(`as_of_batch`, `diff`, `load!`) cannot interleave with a concurrent writer.
This is safety, not concurrency: one operation runs at a time, store-wide.

A `ReentrantLock` (not a `SpinLock`) is used deliberately: the wrapped operations
may yield while holding the lock (e.g. a backend doing database IO), which a
spinlock cannot do safely. On Julia 1.11+ the store is kept in a `Base.Lockable`,
so it is only reachable while the lock is held.

[`asof_join`](@ref) reads two stores and is not wrapped (locking two stores
needs an ordering protocol), so a join across concurrently-written stores is not
a single atomic read.
"""
ThreadSafe

# Operations are the atomicity boundary: lock once around the whole inner call.
Base.insert!(t::ThreadSafe, key, value; kw...) =
    _locked(s -> insert!(s, key, value; kw...), t)
correct!(t::ThreadSafe, key, value; kw...) =
    _locked(s -> correct!(s, key, value; kw...), t)
amend!(t::ThreadSafe, key, value; kw...) =
    _locked(s -> amend!(s, key, value; kw...), t)
retract!(t::ThreadSafe, key; kw...) =
    _locked(s -> retract!(s, key; kw...), t)
as_of(t::ThreadSafe, key; kw...) = _locked(s -> as_of(s, key; kw...), t)
history(t::ThreadSafe, key) = _locked(s -> history(s, key), t)
snapshot(t::ThreadSafe; kw...) = _locked(s -> snapshot(s; kw...), t)
# Return the wrapper, not the inner store, so callers keep the locked handle.
load!(t::ThreadSafe, table; kw...) = (_locked(s -> load!(s, table; kw...), t); t)

# Compound reads run wholly under the lock, so they are a single consistent
# point-in-time read against concurrent writers. Threading the inner batch would
# not help (the lock already serializes), so force the serial path.
function as_of_batch(
        t::ThreadSafe{K, V}, keys::Vector{K},
        valid_ats::Vector{<:TimeType}, tx_ats::Vector{<:TimeType}; threaded::Bool = false,
    ) where {K, V}
    return _locked(s -> as_of_batch(s, keys, valid_ats, tx_ats; threaded = false), t)
end
Base.diff(t::ThreadSafe; kw...) = _locked(s -> diff(s; kw...), t)

# A wrapped store never threads its own reads: one operation runs at a time,
# store-wide, so concurrent get_records never happens (make it explicit).
function supports_parallel_reads(::ThreadSafe)
    return false
end

# Primitives forwarded so the wrapper fully implements the interface. Operations
# above go through `_locked` too, so they never route through these.
get_records(t::ThreadSafe, key) = _locked(s -> get_records(s, key), t)
put_record!(t::ThreadSafe, key, r) = _locked(s -> put_record!(s, key, r), t)
close_tx!(t::ThreadSafe, id, ts) = _locked(s -> close_tx!(s, id, ts), t)
entities(t::ThreadSafe) = _locked(s -> entities(s), t)

# Forward the transaction hook through the lock. Re-taking the lock here is safe
# and cheap (ReentrantLock is reentrant); this is only reached when a caller
# invokes with_write_tx on the wrapper directly, since our own operations call
# the inner store's with_write_tx.
with_write_tx(f, t::ThreadSafe) = _locked(s -> with_write_tx(f, s), t)
