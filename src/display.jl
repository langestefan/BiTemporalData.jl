# Pretty-printing for any `BitemporalStore`. Built only on the `entities` /
# `get_records` primitives, so every backend displays the same way without a
# bespoke method.

# Compact, single-line form (used inside arrays, NamedTuples, etc.).
function Base.show(io::IO, s::BitemporalStore{K, V}) where {K, V}
    ks = collect(entities(s))
    nr = sum(k -> length(get_records(s, k)), ks; init = 0)
    print(
        io, nameof(typeof(s)), "{", K, ", ", V, "}(",
        length(ks), length(ks) == 1 ? " entity, " : " entities, ",
        nr, nr == 1 ? " record)" : " records)",
    )
    return
end

# Multi-line summary (the REPL display).
function Base.show(io::IO, ::MIME"text/plain", s::BitemporalStore{K, V}) where {K, V}
    ks = sort!(collect(entities(s)); by = string)
    counts = Tuple{String, Int}[]
    total = 0
    asserted = 0
    v_lo = v_hi = nothing
    t_lo = t_hi = nothing
    for k in ks
        rs = get_records(s, k)
        push!(counts, (string(k), length(rs)))
        for r in rs
            total += 1
            _asserted(r) && (asserted += 1)
            v_lo = v_lo === nothing ? r.effective_from : min(v_lo, r.effective_from)
            v_hi = v_hi === nothing ? r.effective_from : max(v_hi, r.effective_from)
            t_lo = t_lo === nothing ? r.assertive_from : min(t_lo, r.assertive_from)
            t_hi = t_hi === nothing ? r.assertive_from : max(t_hi, r.assertive_from)
        end
    end
    print(
        io, nameof(typeof(s)), "{", K, ", ", V, "} with ",
        length(ks), length(ks) == 1 ? " entity, " : " entities, ",
        total, total == 1 ? " record (" : " records (", asserted, " currently asserted)",
    )
    total == 0 && return
    print(io, "\n  effective: ", v_lo, " to ", v_hi)
    print(io, "\n  assertive: ", t_lo, " to ", t_hi)
    width = maximum(length(first(c)) for c in counts)
    cap = 12
    for (i, (name, n)) in enumerate(counts)
        i > cap && (print(io, "\n  ... (", length(counts) - cap, " more)"); break)
        print(io, "\n  ", rpad(name, width), "  ", n, n == 1 ? " record" : " records")
    end
    return
end
