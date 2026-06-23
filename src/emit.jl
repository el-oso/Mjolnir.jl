# Emit: Julia AST (`Expr`) -> Julia source text.
#
# Stage 6 of the pipeline. Renders the lowered top-level expressions, prepends any required
# `using` lines, and runs a JuliaSyntax validity gate so a printer bug can never emit
# syntactically invalid Julia silently.

import JuliaSyntax

"""
    ConvertResult

Result of a conversion: the emitted `julia` source, the set of `imports` used, and any
`todos` (constructs that fell through to a literal / unmapped form).
"""
struct ConvertResult
    julia::String
    imports::Vector{Symbol}
    todos::Vector{String}
    has_error::Bool
end

Base.print(io::IO, r::ConvertResult) = print(io, r.julia)
Base.show(io::IO, ::MIME"text/plain", r::ConvertResult) = print(io, r.julia)

function _render(stmts, ctx::Ctx; modulename)
    io = IOBuffer()
    imps = sort!(collect(ctx.imports))
    for imp in imps
        println(io, "using ", imp)
    end
    isempty(imps) || println(io)
    body = join((string(s) for s in stmts), "\n")
    if modulename === nothing
        print(io, body)
    else
        println(io, "module ", modulename)
        isempty(imps) || nothing
        println(io, body)
        print(io, "\nend # module ", modulename)
    end
    return String(take!(io))
end

# Validity gate: parse the emitted source. Non-fatal — a problem records a todo and the
# best-effort source is still returned (so one bad construct never aborts a whole file).
function _validation_issue(src::AbstractString)
    try
        JuliaSyntax.parseall(Expr, src; filename = "mjolnir-emitted.jl")
        return nothing
    catch e
        msg = sprint(showerror, e)
        return "emitted Julia did not parse cleanly: " * first(split(msg, '\n'))
    end
end

"""
    convert_matlab(src; modulename=nothing) -> ConvertResult

Convert MATLAB source text to Julia. With `modulename`, the output is wrapped in a
`module`. The result prints as the emitted Julia source.
"""
# --- duplicate-function guard ------------------------------------------------------------------
# Two definitions with the same qualified name AND the same argument signature silently overwrite
# each other in Julia (the last one wins). MATLAB lets such collisions hide across files/subfunctions;
# we detect them by (name, per-arg-type) so genuine multiple dispatch (e.g. `Base.:+(::A,_)` vs
# `Base.:+(::B,_)`) is NOT flagged.
_signame(s::Symbol) = string(s)
_signame(e::Expr) = e.head === :. ? string(_signame(e.args[1]), ".", _qval(e.args[2])) : string(e)
_signame(x) = string(x)
_qval(q::QuoteNode) = string(q.value)
_qval(x) = string(x)

_argtype(::Symbol) = ""
function _argtype(a::Expr)
    a.head === :(::) && return string(a.args[end])
    a.head === :... && return string(_argtype(a.args[1]), "...")
    a.head === :kw && return _argtype(a.args[1])
    return ""
end
_argtype(::Any) = ""

function _func_sig(f::Expr)
    call = f.args[1]
    (call isa Expr && call.head === :call) || return nothing
    return (_signame(call.args[1]), String[_argtype(a) for a in call.args[2:end]])
end

"Names with the same signature defined more than once among `stmts` (top-level function defs)."
function _duplicate_funcs(stmts)
    seen = Dict{Tuple{String, Vector{String}}, Int}()
    for s in stmts
        (s isa Expr && s.head === :function) || continue
        sig = _func_sig(s)
        sig === nothing || (seen[sig] = get(seen, sig, 0) + 1)
    end
    return [k for (k, v) in seen if v > 1]
end

function convert_matlab(src::AbstractString; modulename = nothing, idiomatic = true, wrap_script = true)
    cst = parse_matlab(src)
    ctx = Ctx(
        cst, collect_vars(cst), String[], Set{Symbol}(), collect_classes(cst),
        Ref(false), Set{Symbol}(), collect_callables(cst), Set{Symbol}(), Any[]
    )
    if cst.has_error
        push!(ctx.todos, "parse error: input contains MATLAB syntax the grammar could not parse (output may be incomplete)")
    end
    stmts = lower_unit(ctx)
    stmts = run_semantic(stmts)                       # always-on correctness fixups
    idiomatic && (stmts = run_idiomatic(stmts; wrap_script))
    for (nm, at) in _duplicate_funcs(stmts)
        sig = join((isempty(t) ? "_" : "::$t" for t in at), ", ")
        push!(ctx.todos, "duplicate definition of `$nm($sig)` — a later definition silently overwrites the earlier one")
    end
    out = _render(stmts, ctx; modulename)
    issue = _validation_issue(out)
    issue === nothing || push!(ctx.todos, issue)
    return ConvertResult(out, sort!(collect(ctx.imports)), ctx.todos, cst.has_error)
end

"""
    convert_file(path; modulename=nothing) -> ConvertResult

Convert a MATLAB `.m` file to Julia.
"""
convert_file(path::AbstractString; kwargs...) =
    convert_matlab(read(path, String); kwargs...)
