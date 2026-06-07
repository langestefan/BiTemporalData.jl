@testitem "ColumnarStore passes the semantic suite" tags = [:unit] setup = [SemanticSuite] begin
    using BiTemporalData

    SemanticSuite.run_semantic_suite(() -> ColumnarStore{String, Float64}())
end

@testitem "ColumnarStore native snapshot matches MemoryStore" tags = [:unit] begin
    using BiTemporalData
    using Dates

    function build(make)
        s = make()
        insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
        insert!(s, "B", 5.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
        correct!(s, "A", 2.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 3))
        amend!(s, "A", 9.0; effective = Date(2024, 7, 1), ts = DateTime(2024, 1, 4))
        return s
    end
    mem = build(() -> MemoryStore{String, Float64}())
    col = build(() -> ColumnarStore{String, Float64}())

    rowset(nt) = Set(Tuple(c[i] for c in values(nt)) for i in eachindex(first(nt)))

    for txa in (DateTime(2024, 1, 2), DateTime(2024, 1, 5))
        @test rowset(snapshot(col; tx_at = txa)) == rowset(snapshot(mem; tx_at = txa))
        for va in (Date(2024, 3, 1), Date(2024, 9, 1))
            @test rowset(snapshot(col; valid_at = va, tx_at = txa)) ==
                rowset(snapshot(mem; valid_at = va, tx_at = txa))
        end
    end

    # The value column is a plain contiguous `Vector{V}` (the ML/GPU read path).
    v = snapshot(col; tx_at = DateTime(2024, 1, 5)).value
    @test v isa Vector{Float64}
end

@testitem "ColumnarStore normalizes the key type" tags = [:unit] begin
    using BiTemporalData
    using Dates

    s = ColumnarStore{String, Float64}()
    insert!(s, "Amsterdam", 1.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
    sub = SubString("xAmsterdamx", 2, 10)
    @test as_of(s, sub; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 2, 1)) == 1.0
    @test eltype(collect(entities(s))) == String
end

@testitem "ThreadSafe over ColumnarStore passes the semantic suite" tags = [:unit] setup = [SemanticSuite] begin
    using BiTemporalData

    SemanticSuite.run_semantic_suite(() -> ThreadSafe(ColumnarStore{String, Float64}()))
end
