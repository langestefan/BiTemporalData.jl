# The backend-agnostic semantic contract. Every backend's test file calls
# `SemanticSuite.run_semantic_suite(make_store)` with its own constructor; all
# must pass the same nine scenarios. Timestamps are passed explicitly via `asserted_at=`
# for determinism; no `sleep`, no clock races.
@testmodule SemanticSuite begin
    using BiTemporalData
    using Dates
    using Tables
    using Test

    # Fixed, strictly increasing assertive timestamps.
    const T1 = DateTime(2024, 1, 1, 9)
    const T2 = DateTime(2024, 1, 2, 9)
    const T3 = DateTime(2024, 1, 3, 9)

    """
        run_semantic_suite(make_store)

    `make_store` is a zero-argument constructor returning a fresh, empty
    `BitemporalStore{String,Float64}`.
    """
    function run_semantic_suite(make_store)
        @testset "1. Empty store" begin
            s = make_store()
            @test as_of(s, "X") === nothing
            @test isempty(collect(entities(s)))
            h = history(s, "X")
            @test length(h.value) == 0
            @test length(snapshot(s).entity) == 0
        end

        @testset "2. Insert and read back" begin
            s = make_store()
            insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = T1)
            @test as_of(s, "A"; effective_at = Date(2024, 6, 1), assertive_at = T1) == 1.0
            # Before the valid range there is no value.
            @test as_of(s, "A"; effective_at = Date(2023, 1, 1), assertive_at = T1) === nothing
            # Before the assertive time there is no value either.
            @test as_of(s, "A"; effective_at = Date(2024, 6, 1), assertive_at = T1 - Day(1)) === nothing
        end

        @testset "3. Correction preserves history" begin
            s = make_store()
            insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = T1)
            correct!(s, "A", 2.0; effective_from = Date(2024, 1, 1), asserted_at = T2)
            # Current assertion is the corrected value...
            @test as_of(s, "A"; effective_at = Date(2024, 6, 1), assertive_at = T2) == 2.0
            # ...but the earlier assertion is still reproducible.
            @test as_of(s, "A"; effective_at = Date(2024, 6, 1), assertive_at = T1) == 1.0
            @test length(history(s, "A").value) == 2
        end

        @testset "4. Amendment splits the timeline" begin
            s = make_store()
            insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = T1)
            amend!(s, "A", 2.0; effective = Date(2024, 6, 1), asserted_at = T2)
            # After the amendment: old value before `effective`, new value after.
            @test as_of(s, "A"; effective_at = Date(2024, 3, 1), assertive_at = T2) == 1.0
            @test as_of(s, "A"; effective_at = Date(2024, 9, 1), assertive_at = T2) == 2.0
            # Before the amendment we asserted 1.0 held over the whole range.
            @test as_of(s, "A"; effective_at = Date(2024, 9, 1), assertive_at = T1) == 1.0
        end

        @testset "5. Correction after amendment" begin
            s = make_store()
            insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = T1)
            amend!(s, "A", 2.0; effective = Date(2024, 6, 1), asserted_at = T2)
            correct!(s, "A", 3.0; effective_from = Date(2024, 6, 1), asserted_at = T3)
            # The corrected later chapter...
            @test as_of(s, "A"; effective_at = Date(2024, 9, 1), assertive_at = T3) == 3.0
            # ...leaves the early chapter untouched...
            @test as_of(s, "A"; effective_at = Date(2024, 3, 1), assertive_at = T3) == 1.0
            # ...and the pre-correction assertion is still reproducible.
            @test as_of(s, "A"; effective_at = Date(2024, 9, 1), assertive_at = T2) == 2.0
        end

        @testset "6. Non-overlapping inserts coexist" begin
            s = make_store()
            insert!(
                s, "A", 1.0;
                effective_from = Date(2024, 1, 1), effective_to = Date(2024, 6, 1), asserted_at = T1,
            )
            insert!(s, "A", 2.0; effective_from = Date(2024, 6, 1), asserted_at = T1)
            @test as_of(s, "A"; effective_at = Date(2024, 3, 1), assertive_at = T1) == 1.0
            @test as_of(s, "A"; effective_at = Date(2024, 9, 1), assertive_at = T1) == 2.0
            @test length(history(s, "A").value) == 2
        end

        @testset "7. Argument validation" begin
            s = make_store()
            # Inverted / empty valid ranges are rejected.
            @test_throws ArgumentError insert!(
                s, "A", 1.0; effective_from = Date(2024, 6, 1), effective_to = Date(2024, 1, 1),
            )
            @test_throws ArgumentError insert!(
                s, "A", 1.0; effective_from = Date(2024, 1, 1), effective_to = Date(2024, 1, 1),
            )
            @test_throws ArgumentError correct!(
                s, "A", 1.0; effective_from = Date(2024, 6, 1), effective_to = Date(2024, 1, 1),
            )
            # Amending an entity with no covering chapter is an error.
            @test_throws ArgumentError amend!(s, "Z", 1.0; effective = Date(2024, 1, 1))
        end

        @testset "8. History audit" begin
            s = make_store()
            insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = T1)
            h1 = history(s, "A")
            correct!(s, "A", 2.0; effective_from = Date(2024, 1, 1), asserted_at = T2)
            h2 = history(s, "A")
            # The original record's value/effective_from/assertive_from are write-once.
            @test h2.value[1] == h1.value[1] == 1.0
            @test h2.effective_from[1] == h1.effective_from[1]
            @test h2.assertive_from[1] == h1.assertive_from[1]
            # Only mutation: assertive_to closed from the open sentinel to the correction time.
            @test h1.assertive_to[1] == MAX_DT
            @test h2.assertive_to[1] == T2
            # The correction appended a new, currently-asserted record.
            @test h2.value[2] == 2.0
            @test h2.assertive_to[2] == MAX_DT
        end

        @testset "9. Tables.jl round-trip" begin
            s = make_store()
            insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = T1)
            insert!(s, "B", 2.0; effective_from = Date(2024, 1, 1), asserted_at = T1)

            h = history(s, "A")
            @test Tables.istable(h)
            @test length(Tables.rowtable(h)) == 1

            snap = snapshot(s; assertive_at = T1)
            @test Tables.istable(snap)
            @test length(Tables.rowtable(snap)) == 2

            cross = snapshot(s; effective_at = Date(2024, 6, 1), assertive_at = T1)
            @test Tables.istable(cross)
            @test Set(Tables.columnnames(cross)) == Set((:entity, :value))
            @test length(Tables.rowtable(cross)) == 2
        end

        @testset "10. Correction of a subrange preserves surrounding assertion" begin
            s = make_store()
            insert!(s, "A", 100.0; effective_from = Date(2024, 1, 1), asserted_at = T1)   # [Jan 1, ∞)
            correct!(s, "A", 110.0; effective_from = Date(2024, 3, 1), asserted_at = T2)  # [Mar 1, ∞)
            # The assertion before the corrected subrange is preserved (the bug this fixes)...
            @test as_of(s, "A"; effective_at = Date(2024, 2, 1), assertive_at = T2) == 100.0
            # ...and the corrected subrange holds the new value.
            @test as_of(s, "A"; effective_at = Date(2024, 4, 1), assertive_at = T2) == 110.0
            # The pre-correction assertion is unchanged at the earlier assertive time.
            @test as_of(s, "A"; effective_at = Date(2024, 2, 1), assertive_at = T1) == 100.0
            @test as_of(s, "A"; effective_at = Date(2024, 4, 1), assertive_at = T1) == 100.0

            # A correction strictly inside a bounded record preserves both slivers.
            s2 = make_store()
            insert!(
                s2, "B", 1.0;
                effective_from = Date(2024, 1, 1), effective_to = Date(2024, 12, 1), asserted_at = T1,
            )
            correct!(
                s2, "B", 2.0;
                effective_from = Date(2024, 4, 1), effective_to = Date(2024, 7, 1), asserted_at = T2,
            )
            @test as_of(s2, "B"; effective_at = Date(2024, 2, 1), assertive_at = T2) == 1.0   # left sliver
            @test as_of(s2, "B"; effective_at = Date(2024, 5, 1), assertive_at = T2) == 2.0   # corrected
            @test as_of(s2, "B"; effective_at = Date(2024, 9, 1), assertive_at = T2) == 1.0   # right sliver
        end

        @testset "11. Retraction removes assertion but keeps history" begin
            s = make_store()
            insert!(
                s, "A", 100.0;
                effective_from = Date(2024, 1, 1), effective_to = Date(2024, 12, 1), asserted_at = T1,
            )
            # Subrange retraction: the middle is gone, the surrounding slivers remain.
            slivers = retract!(s, "A"; effective_from = Date(2024, 3, 1), effective_to = Date(2024, 6, 1), asserted_at = T2)
            @test length(slivers) == 2
            @test as_of(s, "A"; effective_at = Date(2024, 4, 1), assertive_at = T2) === nothing
            @test as_of(s, "A"; effective_at = Date(2024, 2, 1), assertive_at = T2) == 100.0
            @test as_of(s, "A"; effective_at = Date(2024, 7, 1), assertive_at = T2) == 100.0
            # The prior assertion is still reproducible at the earlier assertive time.
            @test as_of(s, "A"; effective_at = Date(2024, 4, 1), assertive_at = T1) == 100.0

            # Full retraction leaves nothing asserted and inserts no slivers.
            @test isempty(retract!(s, "A"; effective_from = Date(2024, 1, 1), effective_to = Date(2024, 12, 1), asserted_at = T3))
            @test as_of(s, "A"; effective_at = Date(2024, 2, 1), assertive_at = T3) === nothing
            @test as_of(s, "A"; effective_at = Date(2024, 7, 1), assertive_at = T3) === nothing
            @test as_of(s, "A"; effective_at = Date(2024, 2, 1), assertive_at = T1) == 100.0
        end

        @testset "12. Assertive time cannot go backwards on close" begin
            s = make_store()
            insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = T2)
            # A close with asserted_at earlier than the record's assertive_from is rejected.
            @test_throws ArgumentError correct!(s, "A", 2.0; effective_from = Date(2024, 1, 1), asserted_at = T1)
            @test_throws ArgumentError retract!(s, "A"; effective_from = Date(2024, 1, 1), asserted_at = T1)
            @test_throws ArgumentError amend!(s, "A", 2.0; effective = Date(2024, 6, 1), asserted_at = T1)
            # Each rejected write left the store untouched.
            @test as_of(s, "A"; effective_at = Date(2024, 6, 1), assertive_at = T2) == 1.0
            @test length(history(s, "A").value) == 1
        end

        @testset "13. Ties on assertive_from resolve to the later write" begin
            s = make_store()
            insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), asserted_at = T1)
            insert!(s, "A", 2.0; effective_from = Date(2024, 1, 1), asserted_at = T1)   # same asserted_at, overlaps
            # The later write at the same assertive_from wins (append order).
            @test as_of(s, "A"; effective_at = Date(2024, 6, 1), assertive_at = T1) == 2.0
            # The same rule through the (possibly native) snapshot cross-section.
            cross = snapshot(s; effective_at = Date(2024, 6, 1), assertive_at = T1)
            i = findfirst(==("A"), cross.entity)
            @test cross.value[i] == 2.0
        end

        @testset "14. insert! check_overlap rejects an overlapping range" begin
            s = make_store()
            insert!(s, "A", 1.0; effective_from = Date(2024, 1, 1), effective_to = Date(2024, 6, 1), asserted_at = T1)
            # With the opt-in check, an overlapping insert is rejected.
            @test_throws ArgumentError insert!(
                s, "A", 2.0; effective_from = Date(2024, 3, 1), asserted_at = T2, check_overlap = true,
            )
            # A non-overlapping insert passes the check.
            insert!(s, "A", 3.0; effective_from = Date(2024, 6, 1), asserted_at = T2, check_overlap = true)
            @test as_of(s, "A"; effective_at = Date(2024, 7, 1), assertive_at = T2) == 3.0
            # The default (no check) still allows an overlap.
            insert!(s, "A", 9.0; effective_from = Date(2024, 1, 1), asserted_at = T3)
            @test length(history(s, "A").value) == 3
        end
    end
end
