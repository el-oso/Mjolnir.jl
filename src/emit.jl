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

function _validate(src::AbstractString)
    try
        JuliaSyntax.parseall(Expr, src; filename = "mjolnir-emitted.jl")
    catch e
        error("Mjolnir: emitter produced invalid Julia:\n", src, "\n\n", e)
    end
    return nothing
end

"""
    convert_matlab(src; modulename=nothing) -> ConvertResult

Convert MATLAB source text to Julia. With `modulename`, the output is wrapped in a
`module`. The result prints as the emitted Julia source.
"""
function convert_matlab(src::AbstractString; modulename = nothing, idiomatic = true, wrap_script = true)
    cst = parse_matlab(src)
    ctx = Ctx(cst, collect_vars(cst), String[], Set{Symbol}(), collect_classes(cst), Ref(false), Set{Symbol}())
    if cst.has_error
        push!(ctx.todos, "parse error: input contains MATLAB syntax the grammar could not parse (output may be incomplete)")
    end
    stmts = lower_unit(ctx)
    stmts = run_semantic(stmts)                       # always-on correctness fixups
    idiomatic && (stmts = run_idiomatic(stmts; wrap_script))
    out = _render(stmts, ctx; modulename)
    _validate(out)
    return ConvertResult(out, sort!(collect(ctx.imports)), ctx.todos, cst.has_error)
end

"""
    convert_file(path; modulename=nothing) -> ConvertResult

Convert a MATLAB `.m` file to Julia.
"""
convert_file(path::AbstractString; kwargs...) =
    convert_matlab(read(path, String); kwargs...)
