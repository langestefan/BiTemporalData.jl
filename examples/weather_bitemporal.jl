# Bitemporal weather demo. Run with:  julia --project=examples examples/weather_bitemporal.jl
#
# Open-Meteo midday temperature forecasts for 3 cities (see README.md). Every row
# is a forecast of `target_date`'s temperature (effective time) as issued on
# `issued_on` (assertive time). The same day is forecast on each of the 7
# preceding days, so the revisions are real -- nothing here is hand-edited.

using BiTemporalData, CSV, DataFrames, Dates

df = CSV.read(joinpath(@__DIR__, "weather_forecasts.csv"), DataFrame)

# Load the whole table in one call. `load!` records each row as a forecast (a
# `correct!` in issue order), so the daily revisions chain in assertive time.
store = load!(
    MemoryStore{String, Float64}(), df;
    key = :city, value = :temp_c,
    effective_from = :target_date, effective_to = r -> r.target_date + Day(1),
    asserted_at = r -> DateTime(r.issued_on),
)

# How Amsterdam's forecast for 2026-06-02 evolved as the day approached.
println("\nForecast history for Amsterdam, 2026-06-02 (value, issued = assertive_from):")
println(filter(:effective_from => ==(Date(2026, 6, 2)), DataFrame(history(store, "Amsterdam"))))

# The same question, asked a week ahead vs the day before.
week_ahead = as_of(store, "Amsterdam"; effective_at = Date(2026, 6, 2), assertive_at = DateTime(2026, 5, 27))
day_before = as_of(store, "Amsterdam"; effective_at = Date(2026, 6, 2), assertive_at = DateTime(2026, 6, 1))
println("\nAmsterdam 2026-06-02: forecast a week ahead = $(week_ahead)°C, day before = $(day_before)°C")

# Point-in-time board: every city's forecast for 2026-06-02 as it stood on May 30.
println("\nForecast board for 2026-06-02, as known on 2026-05-30:")
println(DataFrame(snapshot(store; effective_at = Date(2026, 6, 2), assertive_at = DateTime(2026, 5, 30))))

# Which forecasts changed between two daily runs.
println("\nForecasts revised between 2026-05-30 and 2026-06-01:")
println(DataFrame(diff(store; assertive_at_old = DateTime(2026, 5, 30), assertive_at_new = DateTime(2026, 6, 1))))
