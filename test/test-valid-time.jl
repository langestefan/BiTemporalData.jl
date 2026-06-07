@testitem "intraday valid time (DateTime) on every backend" tags = [:unit] begin
    using BiTemporalData
    using SQLite, DuckDB
    using Dates

    backends = [
        () -> MemoryStore{String, Float64}(),
        () -> ColumnarStore{String, Float64}(),
        () -> SQLiteStore{String, Float64}(":memory:"),
        () -> DuckDBStore{String, Float64}(":memory:"),
    ]
    for make in backends
        s = make()
        # A Date is taken as midnight...
        insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
        @test history(s, "A").valid_from[1] == DateTime(2024, 1, 1, 0, 0)

        # ...and an intraday DateTime is kept to the minute.
        insert!(s, "B", 2.0; valid_from = DateTime(2024, 1, 1, 12, 30), ts = DateTime(2024, 1, 1))
        @test as_of(s, "B"; valid_at = DateTime(2024, 1, 1, 13), tx_at = DateTime(2024, 2, 1)) == 2.0
        @test as_of(s, "B"; valid_at = DateTime(2024, 1, 1, 12), tx_at = DateTime(2024, 2, 1)) === nothing

        # Mixed Date / DateTime in one batch.
        @test as_of_batch(
            s, ["A", "B"],
            [Date(2024, 6, 1), DateTime(2024, 1, 1, 13)],
            [DateTime(2024, 2, 1), DateTime(2024, 2, 1)],
        ) == [1.0, 2.0]
    end
end
