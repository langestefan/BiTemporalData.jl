@testitem "asof_join inner-joins two stores at a point" tags = [:unit] begin
    using BiTemporalData
    using Dates

    t = DateTime(2024, 1, 1)
    a = MemoryStore{String, Float64}()
    insert!(a, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = t)
    insert!(a, "B", 2.0; effective_from = Date(2024, 1, 1), asserted_at = t)

    b = MemoryStore{String, Int}()
    insert!(b, "A", 10; effective_from = Date(2024, 1, 1), asserted_at = t)
    insert!(b, "C", 30; effective_from = Date(2024, 1, 1), asserted_at = t)

    j = asof_join(a, b; effective_at = Date(2024, 6, 1), assertive_at = t)
    # Only "A" is present in both stores.
    @test j.entity == ["A"]
    @test j.a == [1.0]
    @test j.b == [10]
end

@testitem "diff classifies corrections and insertions" tags = [:unit] begin
    using BiTemporalData
    using Dates

    t1 = DateTime(2024, 1, 1)
    t3 = DateTime(2024, 1, 3)
    s = MemoryStore{String, Float64}()
    insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = t1)
    correct!(s, "A", 2.0; effective_from = Date(2024, 1, 1), asserted_at = t3)
    insert!(s, "B", 5.0; effective_from = Date(2024, 1, 1), asserted_at = t3)

    d = diff(s; assertive_at_old = DateTime(2024, 1, 2), assertive_at_new = DateTime(2024, 1, 4))
    by = Dict(
        d.entity[i] => (d.kind[i], d.old_value[i], d.new_value[i]) for i in eachindex(d.entity)
    )
    @test length(d.entity) == 2
    @test by["A"] == (:corrected, 1.0, 2.0)
    @test by["B"] == (:inserted, nothing, 5.0)
end

@testitem "diff reports retractions from an amendment" tags = [:unit] begin
    using BiTemporalData
    using Dates

    s = MemoryStore{String, Float64}()
    insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = DateTime(2024, 1, 1))
    amend!(s, "A", 2.0; effective = Date(2024, 6, 1), asserted_at = DateTime(2024, 1, 3))

    d = diff(s; assertive_at_old = DateTime(2024, 1, 2), assertive_at_new = DateTime(2024, 1, 4))
    kinds = sort(collect(d.kind); by = string)
    # The original open-ended chapter is retracted; two trimmed chapters inserted.
    @test count(==(:retracted), d.kind) == 1
    @test count(==(:inserted), d.kind) == 2
    @test kinds == [:inserted, :inserted, :retracted]
end

@testitem "as_of_batch matches broadcast as_of" tags = [:unit] begin
    using BiTemporalData
    using Dates

    t1 = DateTime(2024, 1, 1)
    t3 = DateTime(2024, 1, 3)
    s = MemoryStore{String, Float64}()
    insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = t1)
    correct!(s, "A", 2.0; effective_from = Date(2024, 1, 1), asserted_at = t3)
    insert!(s, "B", 5.0; effective_from = Date(2024, 1, 1), asserted_at = t1)

    ks = ["A", "A", "B", "C"]
    was = fill(Date(2024, 6, 1), 4)
    tas = [DateTime(2024, 1, 2), DateTime(2024, 1, 4), DateTime(2024, 1, 4), DateTime(2024, 1, 4)]

    r = as_of_batch(s, ks, was, tas)
    @test r == [1.0, 2.0, 5.0, nothing]
    @test r == [as_of(s, ks[i]; effective_at = was[i], assertive_at = tas[i]) for i in eachindex(ks)]
    @test r isa Vector{Union{Float64, Nothing}}

    @test_throws DimensionMismatch as_of_batch(s, ["A"], [Date(2024, 1, 1)], DateTime[])
end
