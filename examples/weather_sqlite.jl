# Persistent bitemporal weather demo, on SQLite.
# Run with:  julia --project=examples examples/weather_sqlite.jl
#
# Same Open-Meteo forecast data as `weather_bitemporal.jl` (see README.md), but
# stored in an on-disk SQLite database via the `SQLiteStore` extension. The point
# of this example is persistence: we load the data, close the database, reopen it
# in a fresh store, and answer the same bitemporal questions: nothing is held in
# memory between the two halves.

using BiTemporalData, CSV, DataFrames, Dates
using SQLite  # loads the SQLiteStore extension (re-exports DBInterface)

df = CSV.read(joinpath(@__DIR__, "weather_forecasts.csv"), DataFrame)

# A fresh database file. (Remove a leftover one so reruns start clean.)
dbfile = joinpath(tempdir(), "weather_bitemporal.sqlite")
isfile(dbfile) && rm(dbfile)

# --- Session 1: ingest, then close the database -------------------------------

store = load!(
    SQLiteStore{String, Float64}(dbfile), df;
    key = :city, value = :temp_c,
    valid_from = :target_date, valid_to = r -> r.target_date + Day(1),
    ts = r -> DateTime(r.issued_on),
)
println("Wrote $(nrow(df)) forecasts to $(dbfile)")
println(store)                     # summary via the store's `show`
DBInterface.close!(store.db)       # flush and close the connection

# --- Session 2: reopen the same file and query it -----------------------------
# A brand-new store over the existing file; the bitemporal history is intact.

store = SQLiteStore{String, Float64}(dbfile)
println("\nReopened $(dbfile)")

# How Amsterdam's forecast for 2026-06-02 evolved as the day approached.
println("\nForecast history for Amsterdam, 2026-06-02 (value, issued = tx_from):")
println(filter(:valid_from => ==(Date(2026, 6, 2)), DataFrame(history(store, "Amsterdam"))))

# The same question, asked a week ahead vs the day before.
week_ahead = as_of(store, "Amsterdam"; valid_at = Date(2026, 6, 2), tx_at = DateTime(2026, 5, 27))
day_before = as_of(store, "Amsterdam"; valid_at = Date(2026, 6, 2), tx_at = DateTime(2026, 6, 1))
println("\nAmsterdam 2026-06-02: forecast a week ahead = $(week_ahead)°C, day before = $(day_before)°C")

# Point-in-time board: every city's forecast for 2026-06-02 as it stood on May 30.
println("\nForecast board for 2026-06-02, as known on 2026-05-30:")
println(DataFrame(snapshot(store; valid_at = Date(2026, 6, 2), tx_at = DateTime(2026, 5, 30))))

# Which forecasts changed between two daily runs.
println("\nForecasts revised between 2026-05-30 and 2026-06-01:")
println(DataFrame(diff(store; tx_at_old = DateTime(2026, 5, 30), tx_at_new = DateTime(2026, 6, 1))))

DBInterface.close!(store.db)

# --- Concurrent access via ThreadSafe -----------------------------------------
# A SQLite connection is not safe to share across threads. `ThreadSafe` serializes
# whole operations behind one store-wide lock, which makes concurrent access
# correct. Because that lock is store-wide, it is safety, not parallelism: the two
# timings below should be close (the threaded run does not run reads in parallel),
# and they should produce the same answer.

using Base.Threads

safe = ThreadSafe(SQLiteStore{String, Float64}(dbfile))

# A fixed batch of point-in-time lookups (deterministic, so reruns compare).
cities = ["Amsterdam", "Berlin", "London"]
queries = [
    (cities[mod1(i, 3)], Date(2026, 6, mod1(i, 6) + 1), DateTime(2026, 5, 27) + Day(mod1(i, 7)))
        for i in 1:10_000
]

# Sum the looked-up temperatures (missing -> 0.0), as one task and as N tasks.
ask(s, qs) = sum(q -> something(as_of(s, q[1]; valid_at = q[2], tx_at = q[3]), 0.0), qs; init = 0.0)

function ask_par(s, qs)
    chunks = Iterators.partition(qs, cld(length(qs), nthreads()))
    tasks = map(chunk -> Threads.@spawn(ask(s, chunk)), collect(chunks))
    return sum(fetch, tasks; init = 0.0)   # each task sums its own chunk: race-free
end

ask(safe, queries[1:100])       # warm up (compile) before timing
ask_par(safe, queries[1:100])
t_seq = @elapsed sum_seq = ask(safe, queries)
t_par = @elapsed sum_par = ask_par(safe, queries)

println("\nConcurrent reads through ThreadSafe(SQLiteStore) ($(length(queries)) `as_of` queries):")
println("  threads available: $(nthreads())")
println("  sequential: $(round(t_seq * 1000; digits = 1)) ms")
println("  threaded:   $(round(t_par * 1000; digits = 1)) ms")
println("  same result: $(sum_seq ≈ sum_par)  (single store-wide lock: safety, not a speedup)")

DBInterface.close!(safe.store.db)
println("\nThe database file remains at $(dbfile) for inspection (e.g. `sqlite3`).")
