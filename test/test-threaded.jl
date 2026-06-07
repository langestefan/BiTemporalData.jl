@testitem "as_of_batch threaded matches serial across backends" tags = [:unit] begin
    using BiTemporalData
    using SQLite, DuckDB
    using Dates

    # A store with a few records per key, and a batch with repeated keys.
    function build(make)
        s = make()
        for i in 1:50
            k = "e$i"
            insert!(s, k, float(i); valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
            correct!(s, k, float(i) + 0.5; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 2))
        end
        return s
    end
    ks = ["e$(mod1(i, 60))" for i in 1:500]   # includes "e51".."e60" (absent keys)
    # `va` is DateTime: the internal `_batch_*` helpers take already-normalized
    # times (the public `as_of_batch` does the TimeType -> DateTime conversion).
    va = fill(DateTime(2024, 6, 1), 500)
    ta = [iseven(i) ? DateTime(2024, 1, 1) : DateTime(2024, 1, 3) for i in 1:500]

    inmem = [
        ("MemoryStore", build(() -> MemoryStore{String, Float64}())),
        ("ColumnarStore", build(() -> ColumnarStore{String, Float64}())),
    ]
    ondisk = [
        ("SQLiteStore", build(() -> SQLiteStore{String, Float64}(":memory:"))),
        ("DuckDBStore", build(() -> DuckDBStore{String, Float64}(":memory:"))),
    ]

    for (name, s) in inmem
        @test supports_parallel_reads(s)
    end
    for (name, s) in ondisk
        @test !supports_parallel_reads(s)
    end

    for (name, s) in vcat(inmem, ondisk)
        serial = as_of_batch(s, ks, va, ta)
        # Public API: `threaded = true` dispatches the right strategy and agrees.
        @test as_of_batch(s, ks, va, ta; threaded = true) == serial
        # The grouped serial path is the reference.
        @test BiTemporalData._batch_grouped(s, ks, va, ta) == serial
        # Prefetch (serial fetch + parallel scan) is safe on every backend.
        @test BiTemporalData._batch_prefetch(s, ks, va, ta) == serial
    end

    # The flat path reads `get_records` concurrently, so it is only valid on
    # backends that opt in via `supports_parallel_reads`.
    for (name, s) in inmem
        @test BiTemporalData._batch_flat(s, ks, va, ta) == as_of_batch(s, ks, va, ta)
    end

    # Length validation still applies with the keyword.
    @test_throws DimensionMismatch as_of_batch(
        inmem[1][2], ks, va, ta[1:(end - 1)]; threaded = true,
    )
end
