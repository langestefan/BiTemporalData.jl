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
println("\nThe database file remains at $(dbfile) for inspection (e.g. `sqlite3`).")
