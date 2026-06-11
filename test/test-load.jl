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

    # The valid_to default (MAX_DT) leaves the range open-ended.
    open = load!(
        MemoryStore{String, Float64}(), [(k = "x", v = 5.0, d = Date(2024, 1, 1))];
        key = :k, value = :v, valid_from = :d, ts = r -> DateTime(2024, 1, 1),
    )
    @test history(open, "x").valid_to == [MAX_DT]

    # Empty source is a no-op.
    @test isempty(entities(load!(MemoryStore{Int, Int}(), NamedTuple[]; key = :k, value = :v, valid_from = :f, ts = :t)))
end

@testitem "load! matches a per-row correct! loop on a messy table" tags = [:unit] begin
    using BiTemporalData
    using SQLite, DuckDB
    using Dates

    # Deterministic pseudo-random table: 5 keys, overlapping ranges, out-of-order
    # and duplicate ts. load! (fetch-once, in-memory believed set) must produce
    # byte-identical history to applying correct! per row in stable ts order.
    table = NamedTuple[]
    for i in 1:200
        k = "k$(mod1(i * 7, 5))"
        vf = Date(2024, mod1(i * 13, 11), mod1(i * 17, 28))
        vt = vf + Day(mod1(i * 11, 120))
        tsd = DateTime(2024, 1, 1) + Day(mod1(i * 5, 40))   # duplicates + out of order
        push!(table, (key = k, value = float(mod1(i * 3, 100)), vf = vf, vt = vt, ts = tsd))
    end

    function histset(s, k)
        h = history(s, k)
        return sort(
            [
                (h.value[i], h.valid_from[i], h.valid_to[i], h.tx_from[i], h.tx_to[i])
                    for i in eachindex(h.value)
            ]
        )
    end

    backends = (
        () -> MemoryStore{String, Float64}(),
        () -> ColumnarStore{String, Float64}(),
        () -> SQLiteStore{String, Float64}(":memory:"),
        () -> DuckDBStore{String, Float64}(":memory:"),
    )
    for make in backends
        loaded = make()
        load!(loaded, table; key = :key, value = :value, valid_from = :vf, valid_to = :vt, ts = :ts)

        ref = make()
        for r in sort(table; by = r -> r.ts, alg = Base.Sort.MergeSort)
            correct!(ref, r.key, r.value; valid_from = r.vf, valid_to = r.vt, ts = r.ts)
        end

        for k in ["k1", "k2", "k3", "k4", "k5"]
            @test histset(loaded, k) == histset(ref, k)
        end
    end
end
