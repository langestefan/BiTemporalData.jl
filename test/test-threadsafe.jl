@testitem "ThreadSafe passes the semantic suite" tags = [:unit] setup = [SemanticSuite] begin
    using BiTemporalData

    SemanticSuite.run_semantic_suite(() -> ThreadSafe(MemoryStore{String, Float64}()))
end

@testitem "ThreadSafe serializes concurrent writes" tags = [:unit] begin
    using BiTemporalData
    using Dates

    # Strongest under `julia -t auto`; correct (serialized) on a single thread too.
    n = 200
    same = ThreadSafe(MemoryStore{String, Int}())
    @sync for i in 1:n
        Threads.@spawn insert!(same, "k", i; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
    end
    # No append lost to a race on the index.
    @test length(history(same, "k").value) == n

    distinct = ThreadSafe(MemoryStore{Int, Int}())
    @sync for i in 1:n
        Threads.@spawn insert!(distinct, i, i; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
    end
    @test length(collect(entities(distinct))) == n
end
