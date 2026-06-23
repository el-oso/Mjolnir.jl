# Octave differential oracle (test-only adapter).
#
# Thin layer over the shipped Mjolnir.oracle helpers. The heavy lifting
# (engine runner, julia_eval, values_match, _flatrm*) now lives in src/oracle.jl
# and is re-exported by the Mjolnir module so tests pick it up via `using Mjolnir`.
#
# Engine selection is controlled by the MJOLNIR_ORACLE env var:
#   unset / "octave" → Octave only   (default; matches prior CI behaviour)
#   "matlab"         → MATLAB only
#   "both"           → both Octave and MATLAB (run tests against each available engine)
#
# The test-set is skipped only when NO selected+available engine exists.

using JSON  # needed for idiom-registry tests that also live in runtests.jl

# Re-export the shipped helpers under the names the oracle tests use.
# (They are already in the Mjolnir namespace via `using Mjolnir`.)

"""
Return the set of engines to run oracle tests against, based on MJOLNIR_ORACLE env var.
The set is filtered to only include engines that are actually installed.
"""
function _oracle_engines()
    sel = get(ENV, "MJOLNIR_ORACLE", "octave")
    want = if sel == "both"
        [:octave, :matlab]
    elseif sel == "matlab"
        [:matlab]
    else
        [:octave]
    end
    return filter(e -> (e === :octave ? octave_available() : matlab_available()), want)
end

"""
Thin wrapper: run `script` via Octave using the shipped engine runner.
`extra_files` is an `AbstractDict` of filename→contents written alongside `snippet.m`.
"""
function octave_eval(
        script::AbstractString, vars::Vector{String};
        extra_files::AbstractDict = Dict{String, String}(),
    )
    return Mjolnir._engine_eval(:octave, script, vars; extra_files)
end

"""
    oracle_check(matlab, vars; atol, rtol) -> (ok::Bool, info)

Convert `matlab`, run it in both the selected engine(s) and Julia, and compare `vars`.
`info` is a NamedTuple with the emitted Julia, engine results Dict, Julia result Dict, and
any mismatching variable names (from the last checked engine).
"""
function oracle_check(matlab::AbstractString, vars::Vector{String}; atol = 1.0e-9, rtol = 1.0e-7)
    r = convert_matlab(matlab; wrap_script = false)
    jl = Mjolnir.julia_eval(r.julia, vars)
    overall_ok = true
    last_bad = String[]
    last_eng_result = Dict{String, Any}()
    for eng in _oracle_engines()
        eng_result = Mjolnir._engine_eval(eng, matlab, vars)
        bad = String[]
        for v in vars
            if !Mjolnir.values_match(jl[v], eng_result[v]; atol, rtol)
                push!(bad, v)
            end
        end
        if !isempty(bad)
            overall_ok = false
            last_bad = bad
            last_eng_result = eng_result
        end
    end
    return (
        overall_ok,
        (
            julia = r.julia,
            octave = last_eng_result,
            jlvals = jl,
            mismatched = last_bad,
        ),
    )
end

"""
    oracle_check_class(classes, driver, vars; atol, rtol) -> (ok::Bool, info)

Differential check for classdef. `classes` is a `Vector` of `(ClassName, matlab_src)`.
The `driver` script is run via each selected+available engine with the class `.m` files
on the path, and in Julia with the converted class definitions as a top-level prelude.
"""
function oracle_check_class(
        classes::Vector, driver::AbstractString, vars::Vector{String};
        atol = 1.0e-9, rtol = 1.0e-7,
    )
    extra = Dict{String, String}(string(name, ".m") => src for (name, src) in classes)
    prelude = join((convert_matlab(src).julia for (_, src) in classes), "\n")
    code = convert_matlab(driver; wrap_script = false).julia
    jl = Mjolnir.julia_eval(code, vars; prelude)
    overall_ok = true
    last_bad = String[]
    last_eng_result = Dict{String, Any}()
    for eng in _oracle_engines()
        eng_result = Mjolnir._engine_eval(eng, driver, vars; extra_files = extra)
        bad = filter(v -> !Mjolnir.values_match(jl[v], eng_result[v]; atol, rtol), vars)
        if !isempty(bad)
            overall_ok = false
            last_bad = bad
            last_eng_result = eng_result
        end
    end
    return (
        overall_ok,
        (
            julia = prelude * "\n# --- driver ---\n" * code,
            octave = last_eng_result,
            jlvals = jl,
            mismatched = last_bad,
        ),
    )
end
