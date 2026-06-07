@testitem "SQLiteStore passes the semantic suite" tags = [:unit] setup = [SemanticSuite] begin
    using BiTemporalData
    using SQLite

    SemanticSuite.run_semantic_suite(() -> SQLiteStore{String, Float64}(":memory:"))
end

@testitem "SQLiteStore persists across reopen" tags = [:unit] begin
    using BiTemporalData
    using SQLite
    using Dates

    mktempdir() do dir
        path = joinpath(dir, "store.db")

        s = SQLiteStore{String, Float64}(path)
        insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1, 9))
        correct!(s, "A", 2.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 2, 9))
        DBInterface.close!(s.db)

        # Reopen the same file: data and the bitemporal history survive.
        s2 = SQLiteStore{String, Float64}(path)
        @test as_of(s2, "A"; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 2, 9)) == 2.0
        @test as_of(s2, "A"; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 1, 9)) == 1.0
        h = history(s2, "A")
        @test h.value == [1.0, 2.0]
        @test h.tx_to[1] == DateTime(2024, 1, 2, 9)
        @test h.tx_to[2] == MAX_DT
        DBInterface.close!(s2.db)
    end
end

@testitem "SQLiteStore normalizes the key type" tags = [:unit] begin
    using BiTemporalData
    using SQLite
    using Dates

    # The key blob must be type-stable: a key passed as a `SubString` (or any
    # type that converts to `K`) must match one stored as a `String`.
    s = SQLiteStore{String, Float64}(":memory:")
    insert!(s, "Amsterdam", 1.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
    sub = SubString("xAmsterdamx", 2, 10)   # == "Amsterdam", but not a String
    @test sub isa SubString
    @test as_of(s, sub; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 2, 1)) == 1.0
    @test collect(entities(s)) == ["Amsterdam"]
    @test eltype(entities(s)) == String
end

@testitem "SQLiteStore needs a path or connection" tags = [:unit] begin
    using BiTemporalData
    using SQLite

    # No path/DB matches no extension constructor, so the core stub fires.
    @test_throws ErrorException SQLiteStore{String, Float64}()
end

@testitem "ThreadSafe over SQLiteStore passes the semantic suite" tags = [:unit] setup = [SemanticSuite] begin
    using BiTemporalData
    using SQLite

    SemanticSuite.run_semantic_suite(() -> ThreadSafe(SQLiteStore{String, Float64}(":memory:")))
end
