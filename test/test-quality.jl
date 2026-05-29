@testitem "Aqua quality assurance" tags = [:quality] begin
    using BiTemporalData
    using Aqua

    Aqua.test_all(BiTemporalData)
end

@testitem "JET static analysis" tags = [:quality] begin
    using BiTemporalData
    using JET

    # JET's results depend on Julia internals, so only assert on stable releases
    # to avoid false positives on nightly / pre-release builds.
    if isempty(VERSION.prerelease)
        JET.test_package(BiTemporalData; target_defined_modules = true)
    end
end
