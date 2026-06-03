@testitem "load! bulk-ingests a Tables source" tags = [:unit] begin
    using Dates

    # A vector of NamedTuples is a valid Tables.jl row source. Rows are out of
    # transaction-time order on purpose; load! must sort them.
    table = [
        (city = "A", t = 1.0, day = Date(2024, 1, 1), issued = DateTime(2024, 1, 3)),
        (city = "A", t = 2.0, day = Date(2024, 1, 1), issued = DateTime(2024, 1, 1)),
        (city = "A", t = 3.0, day = Date(2024, 1, 1), issued = DateTime(2024, 1, 2)),
        (city = "B", t = 9.0, day = Date(2024, 2, 1), issued = DateTime(2024, 1, 2)),
    ]

    s = MemoryStore{String, Float64}()
    @test load!(
        s, table;
        key = :city, value = :t,
        valid_from = :day, valid_to = r -> r.day + Day(1), ts = :issued,
    ) === s   # returns the same store

    # Equivalent to applying correct! in ascending ts order by hand.
    ref = MemoryStore{String, Float64}()
    for r in sort(table; by = r -> r.issued)
        correct!(ref, r.city, r.t; valid_from = r.day, valid_to = r.day + Day(1), ts = r.issued)
    end
    @test snapshot(s) == snapshot(ref)

    # Belief chains across the three vintages of A's 2024-01-01.
    a(tx) = as_of(s, "A"; valid_at = Date(2024, 1, 1), tx_at = tx)
    @test a(DateTime(2024, 1, 1)) == 2.0
    @test a(DateTime(2024, 1, 2)) == 3.0
    @test a(DateTime(2024, 1, 3)) == 1.0
    @test history(s, "A").value == [2.0, 3.0, 1.0]
    @test as_of(s, "B"; valid_at = Date(2024, 2, 1), tx_at = DateTime(2024, 1, 2)) == 9.0

    # The valid_to default (MAX_DATE) leaves the range open-ended.
    open = load!(
        MemoryStore{String, Float64}(), [(k = "x", v = 5.0, d = Date(2024, 1, 1))];
        key = :k, value = :v, valid_from = :d, ts = r -> DateTime(2024, 1, 1),
    )
    @test history(open, "x").valid_to == [MAX_DATE]

    # Empty source is a no-op.
    @test isempty(entities(load!(MemoryStore{Int, Int}(), NamedTuple[]; key = :k, value = :v, valid_from = :f, ts = :t)))
end
