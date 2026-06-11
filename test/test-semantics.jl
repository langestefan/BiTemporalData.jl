# The backend-agnostic semantic contract. Every backend's test file calls
# `SemanticSuite.run_semantic_suite(make_store)` with its own constructor; all
# must pass the same nine scenarios. Timestamps are passed explicitly via `ts=`
# for determinism; no `sleep`, no clock races.
@testmodule SemanticSuite begin
    using BiTemporalData
    using Dates
    using Tables
    using Test

    # Fixed, strictly increasing transaction timestamps.
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
            insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = T1)
            @test as_of(s, "A"; valid_at = Date(2024, 6, 1), tx_at = T1) == 1.0
            # Before the valid range there is no value.
            @test as_of(s, "A"; valid_at = Date(2023, 1, 1), tx_at = T1) === nothing
            # Before the transaction time there is no value either.
            @test as_of(s, "A"; valid_at = Date(2024, 6, 1), tx_at = T1 - Day(1)) === nothing
        end

        @testset "3. Correction preserves history" begin
            s = make_store()
            insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = T1)
            correct!(s, "A", 2.0; valid_from = Date(2024, 1, 1), ts = T2)
            # Current belief is the corrected value...
            @test as_of(s, "A"; valid_at = Date(2024, 6, 1), tx_at = T2) == 2.0
            # ...but the earlier belief is still reproducible.
            @test as_of(s, "A"; valid_at = Date(2024, 6, 1), tx_at = T1) == 1.0
            @test length(history(s, "A").value) == 2
        end

        @testset "4. Amendment splits the timeline" begin
            s = make_store()
            insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = T1)
            amend!(s, "A", 2.0; effective = Date(2024, 6, 1), ts = T2)
            # After the amendment: old value before `effective`, new value after.
            @test as_of(s, "A"; valid_at = Date(2024, 3, 1), tx_at = T2) == 1.0
            @test as_of(s, "A"; valid_at = Date(2024, 9, 1), tx_at = T2) == 2.0
            # Before the amendment we believed 1.0 held over the whole range.
            @test as_of(s, "A"; valid_at = Date(2024, 9, 1), tx_at = T1) == 1.0
        end

        @testset "5. Correction after amendment" begin
            s = make_store()
            insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = T1)
            amend!(s, "A", 2.0; effective = Date(2024, 6, 1), ts = T2)
            correct!(s, "A", 3.0; valid_from = Date(2024, 6, 1), ts = T3)
            # The corrected later chapter...
            @test as_of(s, "A"; valid_at = Date(2024, 9, 1), tx_at = T3) == 3.0
            # ...leaves the early chapter untouched...
            @test as_of(s, "A"; valid_at = Date(2024, 3, 1), tx_at = T3) == 1.0
            # ...and the pre-correction belief is still reproducible.
            @test as_of(s, "A"; valid_at = Date(2024, 9, 1), tx_at = T2) == 2.0
        end

        @testset "6. Non-overlapping inserts coexist" begin
            s = make_store()
            insert!(
                s, "A", 1.0;
                valid_from = Date(2024, 1, 1), valid_to = Date(2024, 6, 1), ts = T1,
            )
            insert!(s, "A", 2.0; valid_from = Date(2024, 6, 1), ts = T1)
            @test as_of(s, "A"; valid_at = Date(2024, 3, 1), tx_at = T1) == 1.0
            @test as_of(s, "A"; valid_at = Date(2024, 9, 1), tx_at = T1) == 2.0
            @test length(history(s, "A").value) == 2
        end

        @testset "7. Argument validation" begin
            s = make_store()
            # Inverted / empty valid ranges are rejected.
            @test_throws ArgumentError insert!(
                s, "A", 1.0; valid_from = Date(2024, 6, 1), valid_to = Date(2024, 1, 1),
            )
            @test_throws ArgumentError insert!(
                s, "A", 1.0; valid_from = Date(2024, 1, 1), valid_to = Date(2024, 1, 1),
            )
            @test_throws ArgumentError correct!(
                s, "A", 1.0; valid_from = Date(2024, 6, 1), valid_to = Date(2024, 1, 1),
            )
            # Amending an entity with no covering chapter is an error.
            @test_throws ArgumentError amend!(s, "Z", 1.0; effective = Date(2024, 1, 1))
        end

        @testset "8. History audit" begin
            s = make_store()
            insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = T1)
            h1 = history(s, "A")
            correct!(s, "A", 2.0; valid_from = Date(2024, 1, 1), ts = T2)
            h2 = history(s, "A")
            # The original record's value/valid_from/tx_from are write-once.
            @test h2.value[1] == h1.value[1] == 1.0
            @test h2.valid_from[1] == h1.valid_from[1]
            @test h2.tx_from[1] == h1.tx_from[1]
            # Only mutation: tx_to closed from the open sentinel to the correction time.
            @test h1.tx_to[1] == MAX_DT
            @test h2.tx_to[1] == T2
            # The correction appended a new, currently-believed record.
            @test h2.value[2] == 2.0
            @test h2.tx_to[2] == MAX_DT
        end

        @testset "9. Tables.jl round-trip" begin
            s = make_store()
            insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = T1)
            insert!(s, "B", 2.0; valid_from = Date(2024, 1, 1), ts = T1)

            h = history(s, "A")
            @test Tables.istable(h)
            @test length(Tables.rowtable(h)) == 1

            snap = snapshot(s; tx_at = T1)
            @test Tables.istable(snap)
            @test length(Tables.rowtable(snap)) == 2

            cross = snapshot(s; valid_at = Date(2024, 6, 1), tx_at = T1)
            @test Tables.istable(cross)
            @test Set(Tables.columnnames(cross)) == Set((:entity, :value))
            @test length(Tables.rowtable(cross)) == 2
        end

        @testset "10. Correction of a subrange preserves surrounding belief" begin
            s = make_store()
            insert!(s, "A", 100.0; valid_from = Date(2024, 1, 1), ts = T1)   # [Jan 1, ∞)
            correct!(s, "A", 110.0; valid_from = Date(2024, 3, 1), ts = T2)  # [Mar 1, ∞)
            # The belief before the corrected subrange is preserved (the bug this fixes)...
            @test as_of(s, "A"; valid_at = Date(2024, 2, 1), tx_at = T2) == 100.0
            # ...and the corrected subrange holds the new value.
            @test as_of(s, "A"; valid_at = Date(2024, 4, 1), tx_at = T2) == 110.0
            # The pre-correction belief is unchanged at the earlier tx time.
            @test as_of(s, "A"; valid_at = Date(2024, 2, 1), tx_at = T1) == 100.0
            @test as_of(s, "A"; valid_at = Date(2024, 4, 1), tx_at = T1) == 100.0

            # A correction strictly inside a bounded record preserves both slivers.
            s2 = make_store()
            insert!(
                s2, "B", 1.0;
                valid_from = Date(2024, 1, 1), valid_to = Date(2024, 12, 1), ts = T1,
            )
            correct!(
                s2, "B", 2.0;
                valid_from = Date(2024, 4, 1), valid_to = Date(2024, 7, 1), ts = T2,
            )
            @test as_of(s2, "B"; valid_at = Date(2024, 2, 1), tx_at = T2) == 1.0   # left sliver
            @test as_of(s2, "B"; valid_at = Date(2024, 5, 1), tx_at = T2) == 2.0   # corrected
            @test as_of(s2, "B"; valid_at = Date(2024, 9, 1), tx_at = T2) == 1.0   # right sliver
        end

        @testset "11. Retraction removes belief but keeps history" begin
            s = make_store()
            insert!(
                s, "A", 100.0;
                valid_from = Date(2024, 1, 1), valid_to = Date(2024, 12, 1), ts = T1,
            )
            # Subrange retraction: the middle is gone, the surrounding slivers remain.
            slivers = retract!(s, "A"; valid_from = Date(2024, 3, 1), valid_to = Date(2024, 6, 1), ts = T2)
            @test length(slivers) == 2
            @test as_of(s, "A"; valid_at = Date(2024, 4, 1), tx_at = T2) === nothing
            @test as_of(s, "A"; valid_at = Date(2024, 2, 1), tx_at = T2) == 100.0
            @test as_of(s, "A"; valid_at = Date(2024, 7, 1), tx_at = T2) == 100.0
            # The prior belief is still reproducible at the earlier tx time.
            @test as_of(s, "A"; valid_at = Date(2024, 4, 1), tx_at = T1) == 100.0

            # Full retraction leaves nothing believed and inserts no slivers.
            @test isempty(retract!(s, "A"; valid_from = Date(2024, 1, 1), valid_to = Date(2024, 12, 1), ts = T3))
            @test as_of(s, "A"; valid_at = Date(2024, 2, 1), tx_at = T3) === nothing
            @test as_of(s, "A"; valid_at = Date(2024, 7, 1), tx_at = T3) === nothing
            @test as_of(s, "A"; valid_at = Date(2024, 2, 1), tx_at = T1) == 100.0
        end

        @testset "12. Transaction time cannot go backwards on close" begin
            s = make_store()
            insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = T2)
            # A close with ts earlier than the record's tx_from is rejected.
            @test_throws ArgumentError correct!(s, "A", 2.0; valid_from = Date(2024, 1, 1), ts = T1)
            @test_throws ArgumentError retract!(s, "A"; valid_from = Date(2024, 1, 1), ts = T1)
            @test_throws ArgumentError amend!(s, "A", 2.0; effective = Date(2024, 6, 1), ts = T1)
            # Each rejected write left the store untouched.
            @test as_of(s, "A"; valid_at = Date(2024, 6, 1), tx_at = T2) == 1.0
            @test length(history(s, "A").value) == 1
        end

        @testset "13. Ties on tx_from resolve to the later write" begin
            s = make_store()
            insert!(s, "A", 1.0; valid_from = Date(2024, 1, 1), ts = T1)
            insert!(s, "A", 2.0; valid_from = Date(2024, 1, 1), ts = T1)   # same ts, overlaps
            # The later write at the same tx_from wins (append order).
            @test as_of(s, "A"; valid_at = Date(2024, 6, 1), tx_at = T1) == 2.0
            # The same rule through the (possibly native) snapshot cross-section.
            cross = snapshot(s; valid_at = Date(2024, 6, 1), tx_at = T1)
            i = findfirst(==("A"), cross.entity)
            @test cross.value[i] == 2.0
        end
    end
end
