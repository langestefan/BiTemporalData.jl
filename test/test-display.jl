@testitem "show summarises any store via the abstract fallback" tags = [:unit] begin
    using Dates

    s = MemoryStore{String, Float64}()
    insert!(s, "a", 1.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 1))
    correct!(s, "a", 2.0; valid_from = Date(2024, 1, 1), ts = DateTime(2024, 1, 2))
    insert!(s, "b", 3.0; valid_from = Date(2024, 2, 1), ts = DateTime(2024, 1, 3))

    long = sprint(show, MIME("text/plain"), s)
    @test occursin("MemoryStore{String, Float64}", long)
    @test occursin("2 entities", long)
    @test occursin("3 records", long)
    @test occursin("2 currently believed", long)   # the surviving "a" plus "b"
    @test occursin("2024-01-01T00:00:00 to 2024-02-01T00:00:00", long)

    @test sprint(show, s) == "MemoryStore{String, Float64}(2 entities, 3 records)"

    # The fallback applies to any backend, e.g. the ThreadSafe wrapper.
    @test occursin("ThreadSafe{String, Float64}", sprint(show, MIME("text/plain"), ThreadSafe(s)))

    # Empty store does not error.
    empty = sprint(show, MIME("text/plain"), MemoryStore{Int, Int}())
    @test occursin("0 entities, 0 records", empty)
end
