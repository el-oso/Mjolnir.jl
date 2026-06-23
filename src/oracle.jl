# Pluggable differential oracle: Octave and MATLAB engines + IP-free divergence reports.
#
# Engine detection uses Sys.which as a fast pre-check, then a smoke test (run a trivial
# command and verify the output) to confirm the engine is actually runnable.  An installed
# but unlicensed MATLAB prints a license error and exits non-zero — the smoke test catches
# that and returns false.  Results are cached per process (run at most once each).
#
# Both engines speak the same harvest protocol:
#   fprintf(1, '@@VAR %s %s\n', name, jsonencode(eval(name)))
# (fprintf works in both; printf is Octave-only). JSON is already a main dep.
#
# Moved from test/octave_oracle.jl (where they were test-only helpers):
#   julia_eval, values_match, _flatrm, _flatrm_oct
# They are now shared oracle utilities.

# ── Engine detection ──────────────────────────────────────────────────────────────────────────────

# Cache: nothing = not yet tested, true/false = result.
const _octave_available_cache = Ref{Union{Nothing, Bool}}(nothing)
const _matlab_available_cache = Ref{Union{Nothing, Bool}}(nothing)

"""
    octave_available() -> Bool

Return `true` if `octave` is on `PATH` **and** can actually execute a trivial command
(`octave --eval "disp(1)"` exits 0 and prints `"1"`).  An installed but broken or absent
binary returns `false`.  The result is cached for the lifetime of the process.
"""
function octave_available()
    if _octave_available_cache[] !== nothing
        return _octave_available_cache[]::Bool
    end
    result = _smoke_test_engine(:octave)
    _octave_available_cache[] = result
    return result
end

"""
    matlab_available() -> Bool

Return `true` if `matlab` is on `PATH` **and** can actually execute a trivial command
(`matlab -batch "disp(1)"` exits 0 and prints `"1"`).  An installed but unlicensed MATLAB
prints a license error and exits non-zero — this returns `false` in that case.  The result
is cached for the lifetime of the process.
"""
function matlab_available()
    if _matlab_available_cache[] !== nothing
        return _matlab_available_cache[]::Bool
    end
    result = _smoke_test_engine(:matlab)
    _matlab_available_cache[] = result
    return result
end

# Run a trivial engine command and check that it exits 0 and prints "1".
# Returns false on any failure (binary absent, non-zero exit, wrong output, timeout, etc.).
function _smoke_test_engine(engine::Symbol)
    bin = if engine === :octave
        Sys.which("octave")
    elseif engine === :matlab
        Sys.which("matlab")
    else
        return false
    end
    bin === nothing && return false
    cmd = if engine === :octave
        `$bin --no-gui -q --eval "disp(1)"`
    else  # :matlab
        `$bin -batch "disp(1)"`
    end
    try
        out = read(pipeline(cmd; stderr = devnull), String)
        # The output should contain "1" (possibly with whitespace/newlines).
        return occursin(r"^\s*1\s*$"m, out)
    catch
        return false
    end
end

"""
    available_engines() -> Vector{Symbol}

Return the list of differential-oracle engines that are installed **and runnable** on the
current system.  Each element is one of `:octave`, `:matlab`.  An installed but unlicensed
MATLAB (or any engine that fails the smoke test) is excluded.
"""
function available_engines()
    out = Symbol[]
    octave_available() && push!(out, :octave)
    matlab_available() && push!(out, :matlab)
    return out
end

# ── Low-level engine runner ────────────────────────────────────────────────────────────────────────

"""
    _engine_eval(engine, script, vars; extra_files=Dict()) -> Dict{String,Any}

Write `script` to a temp `snippet.m` (plus any `extra_files`) and run it via
`engine` (`:octave` or `:matlab`). After the user script a harvest loop dumps each
requested variable as `@@VAR name <json>` on stdout using `fprintf` (works in both
Octave and MATLAB). Return a `Dict` mapping variable name → parsed JSON value.

If the engine process errors, or a requested variable is missing from the output, the
result contains `"__engine_error__"` with a brief explanation string.
"""
function _engine_eval(
        engine::Symbol,
        script::AbstractString,
        vars::Vector{String};
        extra_files::AbstractDict = Dict{String, String}(),
    )
    engine in (:octave, :matlab) ||
        throw(ArgumentError("unknown engine $engine; must be :octave or :matlab"))
    return mktempdir() do dir
        for (fn, src) in extra_files
            write(joinpath(dir, fn), src)
        end
        mpath = joinpath(dir, "snippet.m")
        keys_expr = join(("\"$v\"" for v in vars), ", ")
        open(mpath, "w") do io
            print(io, script)
            print(io, "\n__tlk = {", keys_expr, "};\n")
            print(
                io, "for __i = 1:numel(__tlk)\n",
                "  fprintf(1, '@@VAR %s %s\\n', __tlk{__i}, jsonencode(eval(__tlk{__i})));\n",
                "end\n",
            )
        end
        cmd = if engine === :octave
            Cmd(`$(Sys.which("octave")) --no-gui -q snippet.m`; dir = dir)
        else  # :matlab
            Cmd(`$(Sys.which("matlab")) -batch snippet`; dir = dir)
        end
        out = ""
        err_msg = ""
        try
            out = read(cmd, String)
        catch e
            err_msg = sprint(showerror, e)
        end
        result = Dict{String, Any}()
        for line in eachline(IOBuffer(out))
            startswith(line, "@@VAR ") || continue
            rest = line[7:end]
            sp = findfirst(' ', rest)
            sp === nothing && continue
            name = rest[1:(sp - 1)]
            try
                result[name] = JSON.parse(rest[(sp + 1):end])
            catch
                result[name] = "__json_parse_error__"
            end
        end
        if !isempty(err_msg)
            result["__engine_error__"] = err_msg
        end
        missing_vars = setdiff(vars, keys(result))
        if !isempty(missing_vars)
            missing_msg = "missing variable(s): " * join(missing_vars, ", ")
            result["__engine_error__"] = get(result, "__engine_error__", missing_msg)
        end
        return result
    end
end

# ── Julia-side eval (moved from test/octave_oracle.jl) ───────────────────────────────────────────

"""
Run Julia `code` in a fresh module; return `Dict(varname => value)` for each name in `vars`.

`using`/`import` lines are hoisted to module scope; the remaining body is wrapped in a
function to give loop variables a shared local scope (matching MATLAB's flat workspace and
avoiding Julia's soft-scope rule). `prelude` (type/function definitions) is evaluated at
top level before the body wrapper.
"""
function julia_eval(code::AbstractString, vars::Vector{String}; prelude::AbstractString = "")
    m = Module(:MjolnirSandbox)
    isempty(strip(prelude)) || Base.include_string(m, prelude)
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

# ── Flat-row comparison helpers (moved from test/octave_oracle.jl) ────────────────────────────────

# Flatten to a row-major Float64 vector so Julia (column-major) and engine (row-major JSON)
# compare in the same traversal order; also tolerates row/column-vector orientation differences.
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

"""
    values_match(julia_val, engine_val; atol=1e-9, rtol=1e-7) -> Bool

Compare a Julia value to the JSON-decoded engine value (from `_engine_eval`).
Handles structs (JSON objects ↔ NamedTuple), string arrays, and numeric arrays.
"""
function values_match(j, o; atol = 1.0e-9, rtol = 1.0e-7)
    if o isa AbstractDict                      # engine struct → JSON object; j is a NamedTuple
        for (k, v) in o
            hasproperty(j, Symbol(k)) || return false
            values_match(getproperty(j, Symbol(k)), v; atol, rtol) || return false
        end
        return true
    end
    if j isa AbstractString || o isa AbstractString
        return string(j) == string(o)
    end
    if o isa AbstractVector && any(x -> x isa AbstractString, o)   # e.g. fieldnames → cell of strings
        jc = collect(j)
        length(jc) == length(o) || return false
        return all(string(x) == string(y) for (x, y) in zip(jc, o))
    end
    jv, ov = _flatrm(j), _flatrm_oct(o)
    length(jv) == length(ov) || return false
    return isempty(jv) || isapprox(jv, ov; atol, rtol)
end

# ── IP-free divergence summary helper ────────────────────────────────────────────────────────────

# Summarise the difference between a Julia value and the engine value without exposing raw data.
# Returns a Dict with keys: julia_type, julia_size, engine_type, engine_size,
# first_diff_index (1-based, or nothing if sizes differ), diff_magnitude (or nothing).
function _divergence_summary(j, o)
    jtype = string(typeof(j))
    otype = _engine_type_name(o)
    jsize = _value_size(j)
    osize = _engine_value_size(o)
    d = Dict{String, Any}(
        "julia_type" => jtype,
        "julia_size" => jsize,
        "engine_type" => otype,
        "engine_size" => osize,
    )
    # Only attempt element-level comparison when both sides are numeric and same length.
    try
        jv = _flatrm(j)
        ov = _flatrm_oct(o)
        if length(jv) == length(ov) && !isempty(jv)
            idx = findfirst(i -> !isapprox(jv[i], ov[i]; atol = 1.0e-9, rtol = 1.0e-7), 1:length(jv))
            if idx !== nothing
                d["first_diff_index"] = idx
                d["diff_magnitude"] = abs(jv[idx] - ov[idx])
            end
        end
    catch
    end
    return d
end

_engine_type_name(o::AbstractDict) = "struct"
_engine_type_name(o::AbstractVector) =
    isempty(o) ? "empty_array" : (o[1] isa AbstractVector ? "matrix" : "vector")
_engine_type_name(o::AbstractString) = "string"
_engine_type_name(o::Number) = "scalar"
_engine_type_name(o) = "unknown"

_value_size(x::Number) = [1]
_value_size(x::AbstractVector) = [length(x)]
_value_size(x::AbstractMatrix) = collect(size(x))
_value_size(x::AbstractArray) = collect(size(x))
_value_size(x) = Int[]

_engine_value_size(o::Number) = [1]
_engine_value_size(o::AbstractString) = Int[]
function _engine_value_size(o::Vector)
    isempty(o) && return [0]
    return o[1] isa Vector ? [length(o), length(o[1])] : [length(o)]
end
_engine_value_size(o::AbstractDict) = Int[]
_engine_value_size(o) = Int[]

# Anonymize a snippet of Julia source using the _Anon machinery from report.jl.
function _anon_julia(src::AbstractString, a::_Anon)
    # Replace any user-name that ended up in the placeholder map.
    out = String(src)
    for name in sort(collect(keys(a.map)); by = length, rev = true)
        out = replace(out, Regex("\\b\\Q" * name * "\\E\\b") => a.map[name])
    end
    # Strip numeric literals: replace sequences of digits (including decimal, e+N) with <num>.
    out = replace(out, r"\b\d+(\.\d+)?([eE][+-]?\d+)?\b" => "<num>")
    # Strip string literals: replace "..." and '...' content with placeholders.
    out = replace(out, r"\"[^\"]*\"" => "\"<str>\"")
    out = replace(out, r"'[^']*'" => "'<str>'")
    return out
end

# ── Public API ─────────────────────────────────────────────────────────────────────────────────────

"""
    differential_report(matlab_src, vars; engine=:auto, anonymize=true) -> Dict

Convert `matlab_src` to Julia, run the same snippet through the selected engine and through
Julia, compare the listed `vars`, and return an IP-free (by default) divergence report.

Engine selection:
- `:auto` — use MATLAB if available, otherwise Octave.
- `:octave` / `:matlab` — force a specific engine (error if not available).

Report keys:
- `engine` — the engine symbol used (as a `String`).
- `mismatched` — variable names where **the engine ran and produced a value that disagrees
  with Julia**.  Variables that were never produced because the engine crashed are NOT listed
  here; they appear in `engine_no_value` instead.
- `matched` — variable names that agree.
- `divergences` — for each mismatched variable: a summary with `julia_type`, `julia_size`,
  `engine_type`, `engine_size`, `first_diff_index`, `diff_magnitude` (no raw values).
- `converted_julia` — the emitted Julia source (anonymized when `anonymize=true`).
- `skeleton` — IP-free node-kind s-expression of the MATLAB source (from `conversion_report`).
- `todos` — scrubbed conversion todos.
- `engine_error` — error string if the engine subprocess failed (absent when clean).
- `engine_no_value` — variables absent from engine output due to an engine crash (absent
  when the engine ran cleanly).

With `anonymize=true` (the default) no user variable/function names or raw numeric/string
literals appear anywhere in the output — only structure, types, shapes, and diff magnitudes.
Set `anonymize=false` for full local detail.

See also [`differential_report_json`](@ref).
"""
function differential_report(
        matlab_src::AbstractString,
        vars::Vector{String};
        engine::Symbol = :auto,
        anonymize::Bool = true,
    )
    chosen = if engine === :auto
        if matlab_available()
            :matlab
        elseif octave_available()
            :octave
        else
            error("no differential-oracle engine found (install octave or matlab)")
        end
    else
        engine
    end

    # Build the structural report first (also populates the _Anon placeholder map).
    crep = conversion_report(matlab_src)
    converted_jl = convert_matlab(matlab_src; wrap_script = false).julia

    # Determine the anonymizer state from the conversion_report CST walk.
    cst = parse_matlab(matlab_src)
    known = _known_names()
    a = _Anon()
    _anon_sexpr(cst, cst.root, a, known)   # populate a.map

    # Run both sides.
    eng_result = _engine_eval(chosen, matlab_src, vars)
    jl_result = try
        julia_eval(converted_jl, vars)
    catch e
        Dict{String, Any}("__julia_error__" => sprint(showerror, e))
    end

    # Compare.
    # `mismatched` means "engine ran and produced a value that disagrees with Julia".
    # When the engine errored (has __engine_error__) and a variable is absent from eng_result,
    # that absence is due to the engine failing — not a genuine value disagreement.  Those
    # vars are recorded in engine_no_value (surfaced via engine_error key) and excluded from
    # mismatched so callers don't see false divergences.
    engine_failed = haskey(eng_result, "__engine_error__")
    matched = String[]
    mismatched = String[]
    engine_no_value = String[]
    divergences = Dict{String, Any}()
    for v in vars
        eng_has = haskey(eng_result, v)
        jl_has = haskey(jl_result, v)
        if eng_has && jl_has
            # Both sides produced a value — compare them.
            if values_match(jl_result[v], eng_result[v])
                push!(matched, v)
            else
                push!(mismatched, v)
                divergences[anonymize ? get(a.map, v, v) : v] =
                    _divergence_summary(jl_result[v], eng_result[v])
            end
        elseif !eng_has && engine_failed
            # Engine errored before producing this variable — not a value divergence.
            push!(engine_no_value, v)
        else
            # Variable not produced by one or both sides (script-level issue, not engine crash).
            push!(mismatched, v)
            divergences[anonymize ? get(a.map, v, v) : v] =
                Dict{String, Any}("reason" => "variable not produced by one or both sides")
        end
    end

    rep = Dict{String, Any}(
        "engine" => string(chosen),
        "mismatched" => anonymize ? [get(a.map, v, v) for v in mismatched] : mismatched,
        "matched" => anonymize ? [get(a.map, v, v) for v in matched] : matched,
        "divergences" => divergences,
        "converted_julia" => anonymize ? _anon_julia(converted_jl, a) : converted_jl,
        "skeleton" => crep["skeleton"],
        "todos" => crep["todos"],
    )
    if haskey(eng_result, "__engine_error__")
        rep["engine_error"] = eng_result["__engine_error__"]
    end
    if !isempty(engine_no_value)
        rep["engine_no_value"] = engine_no_value
    end
    if haskey(jl_result, "__julia_error__")
        rep["julia_error"] = jl_result["__julia_error__"]
    end
    return rep
end

"""
    differential_report_json(matlab_src, vars; engine=:auto, anonymize=true) -> String

[`differential_report`](@ref) serialized to JSON. IP-free by default.
"""
differential_report_json(
    matlab_src::AbstractString,
    vars::Vector{String};
    engine::Symbol = :auto,
    anonymize::Bool = true,
) = JSON.json(differential_report(matlab_src, vars; engine, anonymize))
