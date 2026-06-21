# The MATLAB→Julia idiom registry — single source of truth for humans, agents, and Mjolnir.
#
# `IDIOMS` is structured data. From it we generate:
#   * the human doc  `docs/matlab_julia_idioms.md`  (via `idioms_markdown`)
#   * the agent file  `docs/idioms.json`             (via `idioms_json`)
# and Mjolnir/agents can query it directly (`idioms(...)`). A test cross-checks every
# function-mapping entry against the real builtin maps (`idiom_builtin_gaps`) so the registry
# can never silently drift from the converter.

import JSON

"""
    Idiom(category, matlab, julia; status=:ok, builtin=nothing, notes="")

One MATLAB→Julia mapping. `status` ∈ (`:ok`, `:partial`, `:todo`). `builtin` is the MATLAB
function name (a `Symbol`) when the row maps a concrete builtin — used for the code cross-check.
"""
struct Idiom
    category::String
    matlab::String
    julia::String
    status::Symbol
    builtin::Union{Symbol, Nothing}
    notes::String
end
Idiom(category, matlab, julia; status = :ok, builtin = nothing, notes = "") =
    Idiom(category, matlab, julia, status, builtin, notes)

const _CATEGORY_ORDER = [
    "Literals & types", "Operators", "Indexing", "Shapes & reductions",
    "Constructors & builtins", "Linear algebra & arrays", "Strings, conversions & maps",
    "Control flow & functions", "Scripts vs functions", "classdef",
]

const IDIOMS = Idiom[
    # --- Literals & types ---
    Idiom("Literals & types", "42 / 2.5 / 1e3", "42 / 2.5 / 1e3", notes = "integer literals stay Int"),
    Idiom("Literals & types", "[1 2 3] (row)", "[1 2 3] (1×N Matrix)", notes = "MATLAB-faithful: size(x,2), transpose, x*y, and [A b] concatenation all work"),
    Idiom("Literals & types", "[1;2;3] (column)", "[1, 2, 3] (Vector)"),
    Idiom("Literals & types", "[1 2; 3 4]", "[1 2; 3 4] (Matrix)"),
    Idiom("Literals & types", "[A b] / [A; b]", "hcat / vcat (concatenation)"),
    Idiom("Literals & types", "0x1F", "0x1f -> Int"),
    Idiom("Literals & types", "3i", "3.0im"),
    Idiom("Literals & types", "'text' (char array)", "\"text\"", status = :partial, notes = "char-array semantics approximated by String"),
    Idiom("Literals & types", "\"text\"", "\"text\""),
    Idiom("Literals & types", "true / false", "true / false"),
    Idiom("Literals & types", "pi / Inf / NaN / eps / i,j", "pi / Inf / NaN / eps() / im", notes = "only when not shadowed by a variable"),

    # --- Operators ---
    Idiom("Operators", "+  -", ".+  .-", notes = "MATLAB implicit expansion; de-broadcast to +/- when both operands are scalar"),
    Idiom("Operators", "*  /  \\  ^", "*  /  \\  ^", notes = "matrix operators"),
    Idiom("Operators", ".*  ./  .^  .\\", ".*  ./  .^  .\\"),
    Idiom("Operators", "== ~= < > <= >=", ".== .!= .< .> .<= .>=", notes = "broadcast; de-broadcast when scalar"),
    Idiom("Operators", "&  |", ".&  .|"),
    Idiom("Operators", "&&  ||", "&&  ||"),
    Idiom("Operators", "~x", ".!x"),
    Idiom("Operators", "x'", "x'", notes = "adjoint"),
    Idiom("Operators", "x.'", "transpose(x)"),
    Idiom("Operators", "a:b / a:s:b", "a:b / a:s:b"),

    # --- Indexing ---
    Idiom("Indexing", "x(i), x(i,j)", "x[i], x[i,j]", notes = "only when x is a known variable (scope pre-pass)"),
    Idiom("Indexing", "f(a,b) (f not a variable)", "f(a, b)", notes = "resolved as a call"),
    Idiom("Indexing", "x(end), x(2:end)", "x[end], x[2:end]"),
    Idiom("Indexing", "x(:), A(2,:)", "x[:], A[2, :]"),
    Idiom("Indexing", "x(i) = v", "x[i] = v"),
    Idiom("Indexing", "s.field", "s.field"),

    # --- Shapes & reductions ---
    Idiom("Shapes & reductions", "numel(x)", "length(x)", builtin = :numel),
    Idiom("Shapes & reductions", "length(x)", "maximum(size(x))", builtin = :length, notes = "MATLAB length = longest dim; errors on a scalar"),
    Idiom("Shapes & reductions", "size(x,d)", "size(x, d)"),
    Idiom("Shapes & reductions", "sum(A)/prod(A) on a matrix", "sum(A, dims=1)/prod(A, dims=1)", builtin = :sum, notes = "first-dim reduction when A is provably a matrix; vectors stay scalar"),
    Idiom("Shapes & reductions", "max(A)/min(A) on a matrix", "maximum(A, dims=1)/minimum(A, dims=1)", builtin = :max),
    Idiom("Shapes & reductions", "max(a,b)/min(a,b)", "max.(a, b)/min.(a, b)"),

    # --- Constructors & builtins ---
    Idiom("Constructors & builtins", "zeros(n)/ones(n)/rand(n)", "zeros(n,n)/...", builtin = :zeros, notes = "MATLAB zeros(n) is n×n"),
    Idiom("Constructors & builtins", "eye(n)", "Matrix{Float64}(LinearAlgebra.I, n, n)", builtin = :eye),
    Idiom("Constructors & builtins", "inv(A)", "inv(A)", builtin = :inv),
    Idiom("Constructors & builtins", "linspace(a,b,n)", "range(a, b, length=n)", builtin = :linspace),
    Idiom("Constructors & builtins", "repmat(A,m,n)", "repeat(A, m, n)", builtin = :repmat),
    Idiom("Constructors & builtins", "find(x)", "findall(!iszero, x)", builtin = :find),
    Idiom("Constructors & builtins", "disp(x)", "println(x)", builtin = :disp, status = :partial),
    Idiom("Constructors & builtins", "sqrt/abs/exp/log/sin/.../mod/rem/fix", "f.(args) (broadcast)", builtin = :sqrt, notes = "element-wise math; de-broadcast when scalar"),
    Idiom("Constructors & builtins", "isnan/isinf/isfinite", "isnan.(x)/isinf.(x)/isfinite.(x)", builtin = :isnan),
    Idiom("Constructors & builtins", "fieldnames(s)", "collect(string.(keys(s)))", builtin = :fieldnames),
    Idiom("Constructors & builtins", "isfield(s,'a')", "haskey(s, Symbol(\"a\"))", builtin = :isfield),
    Idiom("Constructors & builtins", "rmfield(s,'a')", "Base.structdiff(s, (a = nothing,))", builtin = :rmfield, status = :partial, notes = "literal field name only"),
    Idiom("Constructors & builtins", "warning(msg)", "@warn msg", builtin = :warning),
    Idiom("Constructors & builtins", "s.(f) (dynamic field)", "getproperty(s, Symbol(f)) / merge(...)", notes = "read + write"),
    Idiom("Constructors & builtins", "s(i).field (struct array)", "s[i] = merge(s[i], (field=v,)) / s[i].field", status = :partial, notes = "read works; build-from-scratch needs a preallocated Vector"),
    Idiom("Constructors & builtins", "anything unmapped", "name(args...) + todos entry"),

    # --- Linear algebra & arrays ---
    Idiom("Linear algebra & arrays", "norm/dot/cross/det/diag", "norm/dot/cross/det/diag", builtin = :norm, notes = "LinearAlgebra"),
    Idiom("Linear algebra & arrays", "trace(A)", "tr(A)", builtin = :trace, notes = "LinearAlgebra; renamed"),
    Idiom("Linear algebra & arrays", "transpose(x)", "transpose(x)", builtin = :transpose),
    Idiom("Linear algebra & arrays", "reshape(A,m,n)", "reshape(A, m, n)", builtin = :reshape, notes = "column-major in both; `[]` dim -> `:`"),
    Idiom("Linear algebra & arrays", "fliplr/flipud/flip", "reverse(…, dims=2/1)/reverse", builtin = :fliplr),
    Idiom("Linear algebra & arrays", "sort(x)/cumsum/cumprod", "ndims-dispatched (dims=first non-singleton for ≥2-D)", builtin = :sort, notes = "works for vectors and 1×N rows"),
    Idiom("Linear algebra & arrays", "unique(x)", "sort(unique(x))", builtin = :unique, notes = "MATLAB unique is sorted"),
    Idiom("Linear algebra & arrays", "cumsum/cumprod", "cumsum/cumprod", builtin = :cumsum, status = :partial, notes = "vectors; matrix needs dims"),
    Idiom("Linear algebra & arrays", "any(x)/all(x)", "any(x)/all(x)", builtin = :any, status = :partial, notes = "vectors; matrix reduces per-column in MATLAB"),
    Idiom("Linear algebra & arrays", "mean/median/std/var", "mean/median/std/var", builtin = :mean, status = :partial, notes = "Statistics; matrix reduces per-column in MATLAB"),
    Idiom("Linear algebra & arrays", "gcd/lcm/factorial", "gcd.(…)/lcm.(…)/factorial.(…)", builtin = :gcd),
    Idiom("Linear algebra & arrays", "nchoosek(n,k)", "binomial(n, k)", builtin = :nchoosek),
    Idiom("Linear algebra & arrays", "kron(A,B)", "kron(A, B)", builtin = :kron, notes = "LinearAlgebra"),
    Idiom("Linear algebra & arrays", "intersect/union/setdiff", "sort(intersect/union/setdiff(…))", builtin = :intersect, notes = "MATLAB set ops are sorted"),
    Idiom("Linear algebra & arrays", "ismember(a,b)", "in.(a, Ref(b))", builtin = :ismember),
    Idiom("Control flow & functions", "preallocated index loop", "comprehension  y = [rhs for i in r]", notes = "recognized when body is y(i)=rhs, i the loop var, rhs independent of y"),
    Idiom("Control flow & functions", "@(x) expr  /  @name", "x -> expr  /  name", notes = "anonymous functions; lambda params are scoped so x(i) inside is indexing"),
    Idiom("Control flow & functions", "function-handle parameter f(x)", "f(x) (kept a call, not f[x])", status = :partial, notes = "heuristic: a param used only as a call-like callee; a read-only array param sized only by indexing may misclassify (loud error, not silent)"),
    Idiom("Control flow & functions", "command syntax (clc, format …)", "dropped (no Julia equivalent)", status = :partial, notes = "recorded as a todo"),
    Idiom("Constructors & builtins", "size(x)", "size(x)", builtin = :size, notes = "tuple vs vector; indexing compatible"),
    Idiom("Constructors & builtins", "error(msg)", "error(msg)", builtin = :error),
    Idiom("Constructors & builtins", "cell(n)", "Array{Any}(undef, n, n)", builtin = :cell),
    Idiom("Linear algebra & arrays", "tril/triu", "tril/triu", builtin = :tril, notes = "LinearAlgebra"),
    Idiom("Linear algebra & arrays", "fft/ifft/fftshift/ifftshift", "fft/ifft/fftshift/ifftshift", builtin = :fft, notes = "FFTW; names match"),
    Idiom("Linear algebra & arrays", "eig(A)", "eigvals(A)", builtin = :eig, status = :partial, notes = "LinearAlgebra; [V,D]=eig needs eigen()"),
    Idiom("Constructors & builtins", "plot/stem/bar/scatter/xlabel/...", "Plots.plot/sticks/bar/.../xlabel!/...", status = :partial, notes = "Plots.jl; stateful subplot/figure/hold/legend semantics are best-effort (subplot/figure still pass through)"),
    Idiom("Constructors & builtins", "fminsearch/fminunc", "Optim.minimizer(Optim.optimize(f, x0))", builtin = :fminsearch, status = :partial, notes = "Optim.jl (unconstrained); use JuMP/Convex/MathOptInterface for constrained (linprog/quadprog) — TODO"),
    Idiom("Constructors & builtins", "conv/filter/butter/freqz (DSP toolbox)", "—", status = :todo, notes = "map to DSP.jl in a future batch"),
    Idiom("Constructors & builtins", "syms / symbolic math", "—", status = :todo, notes = "Symbolic Toolbox; would need Symbolics.jl"),
    Idiom("Literals & types", "... (line continuation)", "(transparent)", notes = "ignored, as in MATLAB"),

    # --- Strings, conversions & maps ---
    Idiom("Strings, conversions & maps", "strcmp(a,b)", "a == b", builtin = :strcmp),
    Idiom("Strings, conversions & maps", "strcmpi(a,b)", "lowercase(a) == lowercase(b)", builtin = :strcmpi),
    Idiom("Strings, conversions & maps", "upper/lower/strtrim", "uppercase/lowercase/strip", builtin = :upper),
    Idiom("Strings, conversions & maps", "strrep(s,a,b)", "replace(s, a => b)", builtin = :strrep),
    Idiom("Strings, conversions & maps", "strcat(a,b,…)", "string(a, b, …)", builtin = :strcat, status = :partial, notes = "MATLAB trims trailing whitespace of char args"),
    Idiom("Strings, conversions & maps", "num2str(x)", "string(x)", builtin = :num2str, status = :partial, notes = "formatting/precision differs"),
    Idiom("Strings, conversions & maps", "str2double/str2num", "parse(Float64, x)", builtin = :str2double),
    Idiom("Strings, conversions & maps", "contains(s,p)", "occursin(p, s)", builtin = :contains, notes = "arg order swapped; Octave lacks contains -> not oracle-tested"),
    Idiom("Strings, conversions & maps", "startsWith/endsWith", "startswith/endswith", builtin = :startsWith),
    Idiom("Strings, conversions & maps", "sprintf/fprintf", "Printf.@sprintf / Printf.@printf", builtin = :sprintf, status = :partial, notes = "escape/format edge cases not fully modeled"),
    Idiom("Strings, conversions & maps", "containers.Map(kc,vc)", "Dict(zip(kc, vc))", notes = "Map()->Dict(); Map(k,v)->Dict(k=>v); type-param form->Dict()+TODO"),
    Idiom("Strings, conversions & maps", "m(k) / m(k)=v (Map)", "m[k] / m[k]=v"),
    Idiom("Strings, conversions & maps", "keys(m)/values(m)", "collect(keys(m))/collect(values(m))", builtin = :keys, status = :partial, notes = "MATLAB order (sorted) vs Julia (unordered)"),
    Idiom("Strings, conversions & maps", "isKey(m,k)/remove(m,k)", "haskey(m,k)/delete!(m,k)", builtin = :isKey),
    Idiom("Strings, conversions & maps", "obj.method(args)", "method(obj, args...)", notes = "method-call syntax"),

    # --- Control flow & functions ---
    Idiom("Control flow & functions", "if/elseif/else/end", "if/elseif/else/end"),
    Idiom("Control flow & functions", "for v = expr ... end", "for v in expr ... end"),
    Idiom("Control flow & functions", "while c ... end", "while c ... end"),
    Idiom("Control flow & functions", "break / continue / return", "break / continue / return", notes = "early `return` carries the function's outputs"),
    Idiom("Control flow & functions", "switch/case/otherwise", "if/elseif/else", notes = "`case {a,b}` -> `sv == a || sv == b`"),
    Idiom("Control flow & functions", "try/catch e", "try/catch e"),
    Idiom("Control flow & functions", "function y = f(a,b)", "function f(a, b) ... return y end"),
    Idiom("Control flow & functions", "function [u,v] = f(...)", "... return (u, v) end"),
    Idiom("Control flow & functions", "varargin / varargin{i}", "varargin... / varargin[i]"),
    Idiom("Control flow & functions", "nargin", "computed prologue + optional params"),
    Idiom("Control flow & functions", "nargout", "nargout = <#declared outputs>", status = :partial, notes = "assumes all outputs requested (Julia has no caller arity)"),
    Idiom("Control flow & functions", "single-line ;-separated control flow", "—", status = :partial, notes = "grammar emits ERROR; use newlines (flagged via has_error)"),

    # --- Scripts vs functions ---
    Idiom("Scripts vs functions", "script with a top-level loop", "body wrapped in let ... end", notes = "Julia soft-scope rule"),
    Idiom("Scripts vs functions", "function file", "top-level functions (hoisted ahead of script code)"),

    # --- classdef ---
    Idiom("classdef", "classdef C", "abstract type AbstractC + mutable struct C <: AbstractC"),
    Idiom("classdef", "properties", "struct fields", notes = "defaults applied in the constructor"),
    Idiom("classdef", "constructor function obj = C(...)", "inner constructor using new()"),
    Idiom("classdef", "method function r = m(obj,...)", "function m(obj::C, ...)"),
    Idiom("classdef", "classdef C < S", "abstract type AbstractC <: AbstractS", status = :partial, notes = "inheritance only when S converted in the same unit"),
    Idiom("classdef", "struct arrays / events / Access= attrs", "—", status = :todo),
]

# ---------------------------------------------------------------------------------------
# Query API (for Mjolnir and agents)
# ---------------------------------------------------------------------------------------

"""
    idioms(; category=nothing, status=nothing, builtin=nothing) -> Vector{Idiom}

Filtered view of the registry. E.g. `idioms(category="Strings, conversions & maps")` or
`idioms(status=:todo)`.
"""
function idioms(; category = nothing, status = nothing, builtin = nothing)
    out = IDIOMS
    category === nothing || (out = filter(i -> i.category == category, out))
    status === nothing || (out = filter(i -> i.status === status, out))
    builtin === nothing || (out = filter(i -> i.builtin === builtin, out))
    return out
end

# ---------------------------------------------------------------------------------------
# Code cross-check: registry must reflect what the converter actually implements
# ---------------------------------------------------------------------------------------

"All MATLAB builtin names the converter actually maps (elementwise + special + constants)."
implemented_builtins() = union(keys(ELEMENTWISE), keys(SPECIAL), keys(IDENT_MAP))

"""
    idiom_builtin_gaps() -> (; undocumented, unimplemented)

`unimplemented`: registry rows flagged `:ok`/`:partial` whose `builtin` is NOT in the code maps
(the doc would be lying). `undocumented`: implemented builtins with no registry row. A healthy
registry has an empty `unimplemented`.
"""
function idiom_builtin_gaps()
    impl = implemented_builtins()
    documented = Set(i.builtin for i in IDIOMS if i.builtin !== nothing)
    unimplemented = sort!(
        [
            string(i.builtin) for i in IDIOMS
                if i.builtin !== nothing && i.status !== :todo && !(i.builtin in impl)
        ]
    )
    undocumented = sort!([string(b) for b in impl if !(b in documented)])
    return (; undocumented, unimplemented)
end

# ---------------------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------------------

_badge(s::Symbol) = s === :ok ? "✅" : s === :partial ? "🟡" : "⬜"

"Render the registry as grouped Markdown tables."
function idioms_markdown()
    io = IOBuffer()
    println(io, "<!-- GENERATED from src/idioms.jl by Mjolnir.write_idioms — do not edit by hand. -->")
    println(io, "# MATLAB → Julia idiom mapping\n")
    println(io, "Normative MATLAB→Julia mappings. `✅` implemented · `🟡` partial/divergence · `⬜` planned.")
    println(io, "Canonical source: `src/idioms.jl`. Machine-readable mirror: `docs/idioms.json`.\n")
    for cat in _CATEGORY_ORDER
        rows = idioms(category = cat)
        isempty(rows) && continue
        println(io, "## ", cat, "\n")
        println(io, "| | MATLAB | Julia | Notes |")
        println(io, "|---|---|---|---|")
        for i in rows
            println(io, "| ", _badge(i.status), " | `", i.matlab, "` | `", i.julia, "` | ", i.notes, " |")
        end
        println(io)
    end
    return String(take!(io))
end

"Render the registry as a JSON array (for agents/tooling)."
function idioms_json()
    return JSON.json(
        [
            Dict(
                    "category" => i.category, "matlab" => i.matlab, "julia" => i.julia,
                    "status" => string(i.status),
                    "builtin" => i.builtin === nothing ? nothing : string(i.builtin),
                    "notes" => i.notes
                ) for i in IDIOMS
        ]
    )
end

"""
    write_idioms(pkgdir = pkgdir(Mjolnir))

(Re)generate `docs/matlab_julia_idioms.md` and `docs/idioms.json` from the registry.
"""
function write_idioms(pkgdir::AbstractString = pkgdir(@__MODULE__))
    docs = joinpath(pkgdir, "docs")
    mkpath(docs)
    write(joinpath(docs, "matlab_julia_idioms.md"), idioms_markdown())
    write(joinpath(docs, "idioms.json"), idioms_json())
    return docs
end
