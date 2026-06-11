@testitem "MemoryStore semantics" tags = [:unit] setup = [SemanticSuite] begin
    using BiTemporalData

    SemanticSuite.run_semantic_suite(() -> MemoryStore{String, Float64}())
end

@testitem "MemoryStore record id is self-locating" tags = [:unit] begin
    using BiTemporalData
    using Dates

    s = MemoryStore{String, Float64}()
    r = insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 1))
    @test r.id == ("A", 1)
    @test r.assertive_to == MAX_DT
end
