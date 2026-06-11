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

@testitem "ThreadSafe entities is safe to iterate under a concurrent writer" tags = [:unit] begin
    using BiTemporalData
    using Dates

    # Strongest under `julia -t auto`. A writer grows the key set while we iterate
    # the `entities` snapshot and read each. If `entities` leaked the live KeySet,
    # iterating it after the lock released would throw on concurrent mutation.
    s = ThreadSafe(MemoryStore{Int, Int}())
    insert!(s, 0, 0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
    writer = Threads.@spawn for i in 1:2000
        insert!(s, i, i; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
    end
    for _ in 1:5000
        for k in entities(s)
            as_of(s, k; valid_at = Date(2024, 6, 1), tx_at = DateTime(2024, 1, 1))
        end
        istaskdone(writer) && break
        yield()
    end
    wait(writer)
    @test length(collect(entities(s))) == 2001
end
