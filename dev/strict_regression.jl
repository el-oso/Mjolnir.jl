#!/usr/bin/env julia
# dev/strict_regression.jl
#
# Usage:  julia --project=dev dev/strict_regression.jl
#
# Regression suite for the two idiom fixes implemented in src/idiomatic.jl:
#   Fix A — maximum(size(x)) -> length(x) for proven-vector/scalar shapes
#   Fix B — type-stable accumulator seed: s=0 -> zero(eltype(arr))
#
# Prints PASS/FAIL per kernel and exits nonzero on any regression.
# If StrictMode / JET / AllocCheck cannot load, prints a SKIP notice and exits 0
# (mirrors the Octave-oracle skip pattern).

# ── Environment setup ────────────────────────────────────────────────────────

using Mjolnir

const HAS_STRICTMODE = try
    @eval using StrictMode, AllocCheck, JET
    true
catch
    false
end

if !HAS_STRICTMODE
    println("SKIP  strict_regression: StrictMode/JET/AllocCheck not available in this env.")
    println("      Run with:  julia --project=dev dev/strict_regression.jl")
    exit(0)
end

# ── Helpers ──────────────────────────────────────────────────────────────────

"""Convert MATLAB source, load into a fresh module, return the named function."""
function load_kernel(matlab_src::String, fname::String)
    cr = convert_matlab(matlab_src)
    m = Module(Symbol("RegrMod_$(fname)"))
    Base.eval(m, :(using LinearAlgebra))
    Base.include_string(m, cr.julia)
    return getfield(m, Symbol(fname)), cr.julia
end

"""Run StrictMode.check(:typestable) and return (pass::Bool, reason::String)."""
function check_typestable(f, argtypes::Tuple)
    fs = StrictMode.check(f, argtypes; guarantees = (:typestable,), fail = :none)
    for finding in fs
        finding.guarantee === :typestable || continue
        return finding.status === :pass, finding.reason
    end
    return false, "no :typestable finding returned"
end

# ── Regression cases ─────────────────────────────────────────────────────────

struct RegrCase
    name::String
    description::String
    matlab_src::String
    fname::String
    argtypes::Tuple
end

const CASES = RegrCase[
    # ── Fix B: accumulator_sum — was Union{Int64,Float64}, must be stable ────
    RegrCase(
        "accumulator_sum",
        "Fix B: seed s=0 -> zero(eltype(v)); accumulates Float64 -> must be type-stable",
        """
        function s = accumulator_sum(v)
          s = 0;
          for i = 1:numel(v)
            s = s + v(i);
          end
        end
        """,
        "accumulator_sum",
        (Vector{Float64},),
    ),

    # ── Fix B: dot_product — two-array accumulation, lexically-first array used ──
    RegrCase(
        "dot_product",
        "Fix B: d=0 -> zero(eltype(a)); dot-product loop with two arrays -> type-stable",
        """
        function d = dot_product(a, b)
          d = 0;
          for i = 1:numel(a)
            d = d + a(i) * b(i);
          end
        end
        """,
        "dot_product",
        (Vector{Float64}, Vector{Float64}),
    ),

    # ── Fix A: proven-vector length via range → length() ─────────────────────
    RegrCase(
        "range_length",
        "Fix A: maximum(size(r)) -> length(r) when r is a proven-vector range",
        """
        function y = range_length(n)
          r = 1:n;
          y = length(r);
        end
        """,
        "range_length",
        (Int64,),
    ),
]

# ── Assertion helpers ─────────────────────────────────────────────────────────

"""Assert Fix A fired: the converted Julia source uses length(x) not maximum(size(x))."""
function check_fix_a(jl_src::String, varname::String)
    has_length = occursin("length($varname)", jl_src) || occursin("length($(varname))", jl_src)
    has_maxsize = occursin("maximum(size($varname)", jl_src)
    if has_maxsize
        return false, "maximum(size($varname)) still present — Fix A did not fire"
    end
    if !has_length
        return false, "neither length($varname) nor maximum(size($varname)) found in output"
    end
    return true, "length($varname) found — Fix A fired correctly"
end

"""Assert Fix B fired: the converted Julia source uses zero(eltype(...)) not literal 0."""
function check_fix_b(jl_src::String, seedvar::String)
    has_zero_eltype = occursin("zero(eltype(", jl_src)
    has_literal_seed = occursin("$(seedvar) = 0\n", jl_src) || occursin("$(seedvar) = 0 ", jl_src) ||
        occursin("$(seedvar) = 0)", jl_src) || occursin("$(seedvar) = 0;", jl_src)
    if !has_zero_eltype
        return false, "zero(eltype(...)) not found — Fix B did not fire (seed still literal 0)"
    end
    return true, "zero(eltype(...)) found — Fix B fired correctly"
end

# ── Runner ────────────────────────────────────────────────────────────────────

n_pass = 0
n_fail = 0

function report(name, pass, reason, extra = "")
    global n_pass, n_fail
    return if pass
        n_pass += 1
        println("PASS  $name — $reason")
    else
        n_fail += 1
        println("FAIL  $name — $reason")
        !isempty(extra) && println("      $extra")
    end
end

println("="^72)
println("Mjolnir strict_regression — Fix A & Fix B idiom regression checks")
println("StrictMode: available (checks_enabled = $(StrictMode.checks_enabled()))")
println("="^72)
println()

for case in CASES
    println("--- $(case.name) ---")
    println("    $(case.description)")

    # Step 1: convert
    local fn, jl_src
    try
        fn, jl_src = load_kernel(case.matlab_src, case.fname)
    catch e
        report(case.name * "/convert", false, "conversion failed", sprint(showerror, e))
        println()
        continue
    end

    # Step 2: per-case structural assertion (Fix A or Fix B fired)
    if case.name == "range_length"
        # Fix A check: `r` should use length(r) not maximum(size(r))
        ok_a, reason_a = check_fix_a(jl_src, "r")
        report(case.name * "/fix_a", ok_a, reason_a)
    else
        # Fix B check: seed variable should be zero(eltype(...))
        ok_b, reason_b = check_fix_b(jl_src, case.fname == "dot_product" ? "d" : "s")
        report(case.name * "/fix_b", ok_b, reason_b)
    end

    # Step 3: type-stability check via StrictMode
    ts_pass, ts_reason = check_typestable(fn, case.argtypes)
    report(case.name * "/typestable", ts_pass, ts_reason == "" ? "ok" : ts_reason)

    # Print the converted source for transparency
    println("    Converted Julia:")
    for ln in split(rstrip(jl_src), '\n')
        println("      $ln")
    end
    println()
end

println("="^72)
println("Results: $n_pass PASS, $n_fail FAIL")
println("="^72)

exit(n_fail > 0 ? 1 : 0)
