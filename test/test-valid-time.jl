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

@testitem "tx_at and ts accept any TimeType (a Date is midnight)" tags = [:unit] begin
    using BiTemporalData
    using Dates

    backends = [
        () -> MemoryStore{String, Float64}(),
        () -> ColumnarStore{String, Float64}(),
        () -> SQLiteStore{String, Float64}(":memory:"),
        () -> DuckDBStore{String, Float64}(":memory:"),
    ]
    for make in backends
        s = make()
        # `ts` given as a Date is taken as midnight.
        insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = Date(2024, 1, 1))
        correct!(s, "A", 2.0; valid_from = Date(2024, 1, 1), ts = Date(2024, 1, 3))
        @test history(s, "A").tx_from[1] == DateTime(2024, 1, 1, 0, 0)

        # `tx_at` given as a Date works on as_of, snapshot, as_of_batch, diff.
        @test as_of(s, "A"; valid_at = Date(2024, 6, 1), tx_at = Date(2024, 1, 2)) == 1.0
        @test as_of(s, "A"; valid_at = Date(2024, 6, 1), tx_at = Date(2024, 1, 4)) == 2.0
        @test snapshot(s; valid_at = Date(2024, 6, 1), tx_at = Date(2024, 1, 2)).value == [1.0]
        @test as_of_batch(s, ["A"], [Date(2024, 6, 1)], [Date(2024, 1, 4)]) == [2.0]
        d = diff(s; tx_at_old = Date(2024, 1, 2), tx_at_new = Date(2024, 1, 4))
        @test d.kind == [:corrected] && d.old_value == [1.0] && d.new_value == [2.0]
    end
end
