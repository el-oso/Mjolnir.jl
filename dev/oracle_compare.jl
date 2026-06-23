# dev/oracle_compare.jl -- Compare MATLAB harness results against Mjolnir-converted Julia.
#
# Usage:
#   julia --project=. dev/oracle_compare.jl <workdir>
#
# Reads <workdir>/matlab_results.json (written by oracle_harness.m via run-command).
# For each case, converts the MATLAB source via Mjolnir, evaluates it in Julia,
# and compares each variable against the MATLAB result using Mjolnir.values_match.
#
# Prints a differential_report-style anonymized summary for each mismatch.
# Exits 1 if any real divergence is found; exits 0 otherwise.
#
# If matlab_results.json is missing (local dry-run before CI), prints a clear
# message and exits 0 -- so the script is sane before MATLAB runs.

length(ARGS) == 1 || error("Usage: julia --project=. dev/oracle_compare.jl <workdir>")
workdir = ARGS[1]

results_path = joinpath(workdir, "matlab_results.json")

if !isfile(results_path)
    println(
        """
        oracle_compare: no MATLAB results found at $(results_path)
        Run the MATLAB harness first (oracle_harness.m via matlab-actions/run-command),
        then re-run this script to compare.
        """,
    )
    exit(0)
end

using Mjolnir
using JSON

# Load the shared case list.
include(joinpath(@__DIR__, "..", "test", "oracle_cases.jl"))

# Read MATLAB results.
matlab_results = JSON.parsefile(results_path)  # Dict{String,Any}: id -> {var -> value}

println("oracle_compare: loaded $(length(matlab_results)) MATLAB results from $(results_path)")

# Reconstruct the manifest (same id generation as oracle_export.jl).
function make_id(name::String, idx::Int)
    safe = replace(name, r"[^a-zA-Z0-9]" => "_")
    safe = replace(safe, r"_+" => "_")
    safe = strip(safe, '_')
    return "case_$(lpad(idx, 3, '0'))_$(safe)"
end

# Build a list of (id, mlab_src, vars, prelude) for all cases.
function build_all_cases()
    cases = Tuple{String, String, Vector{String}, String}[]
    for (idx, (name, mlab_src, vars)) in enumerate(ORACLE_CASES)
        id = make_id(name, idx)
        push!(cases, (id, mlab_src, vars, ""))
    end
    base_idx = length(ORACLE_CASES)
    for (idx, (classes, driver, vars)) in enumerate(ORACLE_CLASS_CASES)
        id = make_id("class_$(idx)", base_idx + idx)
        prelude = join((Mjolnir.convert_matlab(src).julia for (_, src) in classes), "\n")
        push!(cases, (id, driver, vars, prelude))
    end
    return cases
end

all_cases = build_all_cases()

# ── Compare -----------------------------------------------------------------------

function run_compare(all_cases, matlab_results)
    n_compared = 0
    n_skipped = 0   # no MATLAB result (harness error for this case)
    n_agreed = 0
    n_diverged = 0
    divergences = Tuple{String, String, Any, Any}[]   # (id, varname, julia_val, matlab_val)

    for (id, mlab_src, vars, prelude) in all_cases
        if !haskey(matlab_results, id)
            println("  SKIP  $id  (no MATLAB result)")
            n_skipped += 1
            continue
        end
        mres = matlab_results[id]

        # Check for per-case harness error (field name "run_error" in the harness output).
        if haskey(mres, "run_error")
            println("  ERROR $id  MATLAB harness: $(mres["run_error"])")
            n_skipped += 1
            continue
        end

        # Convert and evaluate in Julia.
        jl_src = Mjolnir.convert_matlab(mlab_src; wrap_script = false).julia
        jl_vals = try
            Mjolnir.julia_eval(jl_src, vars; prelude = prelude)
        catch e
            println("  ERROR $id  Julia eval: $(sprint(showerror, e))")
            n_skipped += 1
            continue
        end

        case_ok = true
        for v in vars
            if !haskey(mres, v)
                println("  MISS  $id  var=$v  (MATLAB did not produce this variable)")
                case_ok = false
                n_diverged += 1
                continue
            end
            matlab_val = mres[v]
            julia_val = get(jl_vals, v, nothing)
            if julia_val === nothing
                println("  MISS  $id  var=$v  (Julia did not produce this variable)")
                case_ok = false
                n_diverged += 1
                continue
            end
            if !Mjolnir.values_match(julia_val, matlab_val)
                case_ok = false
                n_diverged += 1
                push!(divergences, (id, v, julia_val, matlab_val))
            end
        end
        if case_ok
            n_agreed += 1
        end
        n_compared += 1
    end

    return (n_compared, n_agreed, n_diverged, n_skipped, divergences)
end

n_compared, n_agreed, n_diverged, n_skipped, divergences = run_compare(all_cases, matlab_results)

println()
println(
    "oracle_compare: $(n_compared) cases compared, $(n_agreed) agreed, $(n_diverged) diverged, $(n_skipped) skipped",
)

if !isempty(divergences)
    println()
    println("DIVERGENCES ($(length(divergences)) variable(s)):")
    for (id, varname, jval, mval) in divergences
        summary = Mjolnir._divergence_summary(jval, mval)
        println("  $id  var=$varname")
        println("    julia_type=$(summary["julia_type"])  julia_size=$(summary["julia_size"])")
        println("    matlab_type=$(summary["engine_type"])  matlab_size=$(summary["engine_size"])")
        if haskey(summary, "first_diff_index")
            println(
                "    first_diff_index=$(summary["first_diff_index"])  diff_magnitude=$(summary["diff_magnitude"])",
            )
        end
    end
    println()
    println("oracle_compare: FAILED -- $(length(divergences)) divergence(s) found")
    exit(1)
else
    println("oracle_compare: PASSED -- Julia and MATLAB agree on all $(n_agreed) compared cases")
    exit(0)
end
