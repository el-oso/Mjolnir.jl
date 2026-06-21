# Octave differential oracle (test-only).
#
# Runs a MATLAB snippet in Octave (an arm's-length subprocess — never linked, source never
# read) and the Mjolnir-converted Julia in a fresh module, then compares the requested
# output variables numerically. This is the empirical correctness check for Stage 2+.

using JSON

const OCTAVE = Sys.which("octave")
octave_available() = OCTAVE !== nothing

"""
Run `script` in Octave; return Dict(varname => parsed-JSON value) for `vars`.
`extra_files` (filename => contents, e.g. `"Point.m" => ...`) are written alongside and the
script runs with that directory as the working dir, so classdef files on the path are found.
"""
function octave_eval(
        script::AbstractString, vars::Vector{String};
        extra_files::AbstractDict = Dict{String, String}(),
    )
    return mktempdir() do dir
        for (fn, src) in extra_files
            write(joinpath(dir, fn), src)
        end
        mpath = joinpath(dir, "snippet.m")
        keys = join(("\"$v\"" for v in vars), ", ")
        open(mpath, "w") do io
            print(io, script)
            print(io, "\n__tlk = {", keys, "};\n")
            print(
                io, "for __i = 1:numel(__tlk)\n",
                "  printf('@@VAR %s %s\\n', __tlk{__i}, jsonencode(eval(__tlk{__i})));\n",
                "end\n"
            )
        end
        out = read(Cmd(`$OCTAVE --no-gui -q snippet.m`; dir = dir), String)
        result = Dict{String, Any}()
        for line in eachline(IOBuffer(out))
            startswith(line, "@@VAR ") || continue
            rest = line[7:end]
            sp = findfirst(' ', rest)
            name = rest[1:(sp - 1)]
            result[name] = JSON.parse(rest[(sp + 1):end])
        end
        return result
    end
end

"""
Run Julia `code` in a fresh module; return Dict(varname => value) for `vars`.

The statement body is wrapped in a function so loops share an enclosing local scope
(matching MATLAB's flat workspace, and avoiding Julia's top-level soft-scope rule); `using`
lines are hoisted to module scope. Emitting that wrapper in the converter itself is a
Phase-3 (idiomatic) item.
"""
function julia_eval(code::AbstractString, vars::Vector{String}; prelude::AbstractString = "")
    m = Module(:MjolnirSandbox)
    isempty(strip(prelude)) || Base.include_string(m, prelude)   # type/function defs at top level
    isimport(l) = (s = lstrip(l); startswith(s, "using ") || startswith(s, "import "))
    lines = split(code, '\n')
    imports = filter(isimport, lines)
    body = filter(!isimport, lines)
    isempty(imports) || Base.include_string(m, join(imports, '\n'))
    rv = join(("$v = $v" for v in vars), ", ")
    wrapped = string(
        "function __tlk_run__()\n", join(body, '\n'), "\nreturn (; ", rv, ")\nend\n__tlk_run__()",
    )
    res = Base.include_string(m, wrapped)
    return Dict(v => getfield(res, Symbol(v)) for v in vars)
end

# Flatten to a row-major Float64 vector so Julia (column-major) and Octave (row-major JSON)
# compare in the same order; tolerates row/column-vector orientation differences.
_flatrm(x::Number) = Float64[float(x)]
_flatrm(x::AbstractVector) = Float64.(collect(x))
_flatrm(x::AbstractMatrix) = Float64.(vec(permutedims(x)))
_flatrm(x::AbstractArray) = Float64.(vec(x))

_flatrm_oct(o::Number) = Float64[float(o)]
function _flatrm_oct(o::Vector)
    isempty(o) && return Float64[]
    return o[1] isa Vector ? Float64[float(x) for r in o for x in r] :
        Float64[float(x) for x in o]
end

function values_match(j, o; atol = 1.0e-9, rtol = 1.0e-7)
    if o isa AbstractDict                      # Octave struct -> JSON object; j is a NamedTuple
        for (k, v) in o
            hasproperty(j, Symbol(k)) || return false
            values_match(getproperty(j, Symbol(k)), v; atol, rtol) || return false
        end
        return true
    end
    if j isa AbstractString || o isa AbstractString
        return string(j) == string(o)
    end
    if o isa AbstractVector && any(x -> x isa AbstractString, o)   # e.g. fieldnames -> cell of strings
        jc = collect(j)
        length(jc) == length(o) || return false
        return all(string(x) == string(y) for (x, y) in zip(jc, o))
    end
    jv, ov = _flatrm(j), _flatrm_oct(o)
    length(jv) == length(ov) || return false
    return isempty(jv) || isapprox(jv, ov; atol, rtol)
end

# Differential check for classdef. `classes` is a vector of (ClassName, matlab_src). The
# `driver` script (which constructs/uses the classes) is run in Octave with the class `.m`
# files on the path, and in Julia with the converted class definitions as a top-level prelude.
function oracle_check_class(classes::Vector, driver::AbstractString, vars::Vector{String}; atol = 1.0e-9, rtol = 1.0e-7)
    extra = Dict{String, String}(string(name, ".m") => src for (name, src) in classes)
    oct = octave_eval(driver, vars; extra_files = extra)
    prelude = join((convert_matlab(src).julia for (_, src) in classes), "\n")
    code = convert_matlab(driver; wrap_script = false).julia
    jl = julia_eval(code, vars; prelude)
    bad = filter(v -> !values_match(jl[v], oct[v]; atol, rtol), vars)
    return (isempty(bad), (julia = prelude * "\n# --- driver ---\n" * code, octave = oct, jlvals = jl, mismatched = bad))
end

"""
    oracle_check(matlab, vars; atol, rtol) -> (ok::Bool, info)

Convert `matlab`, run it in both Octave and Julia, and compare `vars`. `info` is a NamedTuple
with the emitted Julia, both result Dicts, and any mismatching variable names.
"""
function oracle_check(matlab::AbstractString, vars::Vector{String}; atol = 1.0e-9, rtol = 1.0e-7)
    # wrap_script=false keeps script variables visible to julia_eval's function wrapper;
    # the idiomatic passes (de-broadcast, de-colon) are still exercised and validated here.
    r = convert_matlab(matlab; wrap_script = false)
    oct = octave_eval(matlab, vars)
    jl = julia_eval(r.julia, vars)
    bad = String[]
    for v in vars
        if !values_match(jl[v], oct[v]; atol, rtol)
            push!(bad, v)
        end
    end
    return (isempty(bad), (julia = r.julia, octave = oct, jlvals = jl, mismatched = bad))
end
