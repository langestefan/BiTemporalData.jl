@testitem "DuckDBStore passes the semantic suite" tags = [:unit] setup = [SemanticSuite] begin
    using BiTemporalData
    using DuckDB

    SemanticSuite.run_semantic_suite(() -> DuckDBStore{String, Float64}(":memory:"))
end

@testitem "DuckDBStore persists across reopen" tags = [:unit] begin
    using BiTemporalData
    using DuckDB
    using Dates

    # Fully release a DuckDB file: close the connection, then finalize the DB so
    # the OS handle is freed (Windows refuses to reopen/delete a held file).
    release(s) = (DBInterface.close!(s.db); finalize(s.db); GC.gc())

    mktempdir() do dir
        path = joinpath(dir, "store.duckdb")

        s = DuckDBStore{String, Float64}(path)
        insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 1, 9))
        correct!(s, "A", 2.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 2, 9))
        release(s)

        # Reopen the same file: data and the bitemporal history survive.
        s2 = DuckDBStore{String, Float64}(path)
        @test as_of(s2, "A"; effective_at = Date(2024, 6, 1), assertive_at = DateTime(2024, 1, 2, 9)) == 2.0
        @test as_of(s2, "A"; effective_at = Date(2024, 6, 1), assertive_at = DateTime(2024, 1, 1, 9)) == 1.0
        h = history(s2, "A")
        @test h.value == [1.0, 2.0]
        @test h.assertive_to[1] == DateTime(2024, 1, 2, 9)
        @test h.assertive_to[2] == MAX_DT
        release(s2)
    end
end

@testitem "DuckDBStore normalizes the key type" tags = [:unit] begin
    using BiTemporalData
    using DuckDB
    using Dates

    s = DuckDBStore{String, Float64}(":memory:")
    insert!(s, "Amsterdam", 1.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 1))
    sub = SubString("xAmsterdamx", 2, 10)   # == "Amsterdam", but not a String
    @test as_of(s, sub; effective_at = Date(2024, 6, 1), assertive_at = DateTime(2024, 2, 1)) == 1.0
    @test collect(entities(s)) == ["Amsterdam"]
end

@testitem "DuckDBStore native snapshot matches MemoryStore" tags = [:unit] begin
    using BiTemporalData
    using DuckDB
    using Dates

    # Build the same bitemporal history in both backends, then compare the native
    # DuckDB `snapshot` against the reference `MemoryStore` one (both modes).
    function build(make)
        s = make()
        insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 1))
        insert!(s, "B", 5.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 1))
        correct!(s, "A", 2.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 3))
        amend!(s, "A", 9.0; effective = Date(2024, 7, 1), asserted_at = DateTime(2024, 1, 4))
        return s
    end
    mem = build(() -> MemoryStore{String, Float64}())
    duck = build(() -> DuckDBStore{String, Float64}(":memory:"))

    # Compare as sets of rows, since entity ordering is backend-defined.
    rowset(nt) = Set(Tuple(col[i] for col in values(nt)) for i in eachindex(first(nt)))

    for txa in (DateTime(2024, 1, 2), DateTime(2024, 1, 5))
        @test rowset(snapshot(duck; assertive_at = txa)) == rowset(snapshot(mem; assertive_at = txa))
        for va in (Date(2024, 3, 1), Date(2024, 9, 1))
            @test rowset(snapshot(duck; effective_at = va, assertive_at = txa)) ==
                rowset(snapshot(mem; effective_at = va, assertive_at = txa))
        end
    end
end

@testitem "DuckDBStore needs a path or connection" tags = [:unit] begin
    using BiTemporalData
    using DuckDB

    # No path/DB matches no extension constructor, so the core stub fires.
    @test_throws ErrorException DuckDBStore{String, Float64}()
end

@testitem "ThreadSafe over DuckDBStore passes the semantic suite" tags = [:unit] setup = [SemanticSuite] begin
    using BiTemporalData
    using DuckDB

    SemanticSuite.run_semantic_suite(() -> ThreadSafe(DuckDBStore{String, Float64}(":memory:")))
end

@testitem "DuckDBStore rejects an invalid table name" tags = [:unit] begin
    using BiTemporalData
    using DuckDB

    # `table` is interpolated into SQL, so a non-identifier is rejected.
    @test_throws ArgumentError DuckDBStore{String, Float64}(":memory:"; table = "bad name")
    @test_throws ArgumentError DuckDBStore{String, Float64}(":memory:"; table = "x; DROP TABLE y")
    @test_throws ArgumentError DuckDBStore{String, Float64}(":memory:"; table = "1abc")
    # A plain identifier is accepted.
    @test DuckDBStore{String, Float64}(":memory:"; table = "my_records") isa DuckDBStore
end
