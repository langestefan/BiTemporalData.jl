@testitem "TimeZones extension stores zoned times as UTC instants" tags = [:unit] begin
    using BiTemporalData
    using TimeZones
    using Dates

    s = MemoryStore{String, Float64}()

    # Noon in New York is 17:00 UTC; the store keeps the instant, not wall-clock.
    insert!(
        s, "X", 1.0; effective_from = ZonedDateTime(2024, 1, 1, 12, tz"America/New_York"),
        asserted_at = DateTime(2024, 1, 1)
    )
    @test history(s, "X").effective_from[1] == DateTime(2024, 1, 1, 17)

    # A query in another zone resolves to the same instant.
    @test as_of(
        s, "X"; effective_at = ZonedDateTime(2024, 1, 1, 18, tz"Europe/Berlin"),
        assertive_at = DateTime(2024, 2, 1)
    ) == 1.0                                    # 17:00 UTC
    @test as_of(
        s, "X"; effective_at = ZonedDateTime(2024, 1, 1, 11, 59, tz"America/New_York"),
        assertive_at = DateTime(2024, 2, 1)
    ) === nothing                              # before noon NY

    # Batch reads accept a vector of zoned times too.
    @test as_of_batch(
        s, ["X"],
        [ZonedDateTime(2024, 1, 1, 13, tz"Europe/Berlin")],                    # 12:00 UTC
        [DateTime(2024, 2, 1)],
    ) == [nothing]                                                             # before 17:00 UTC
end
