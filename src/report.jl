# IP-free conversion reports.
#
# When a conversion hits problems, `conversion_report` dumps everything needed to fix Mjolnir
# WITHOUT the failing source: the CST is rendered as an s-expression of node *kinds* (grammar
# vocabulary, not IP), user variable/function names become `idN` placeholders, string and number
# literals are stripped, and free text (exception messages, todos) is scrubbed of user names.
# MATLAB keywords/builtins are kept verbatim — they are MATLAB's public API, not the user's IP.

# MATLAB names Mjolnir already recognizes (kept verbatim; everything else is anonymized).
_known_names() = union(Set(keys(ELEMENTWISE)), Set(keys(SPECIAL)), Set(keys(IDENT_MAP)), BASE_OK)

mutable struct _Anon
    map::Dict{String, String}
    n::Int
end
_Anon() = _Anon(Dict{String, String}(), 0)

_ph!(a::_Anon, name::AbstractString) = get!(a.map, name) do
    a.n += 1
    return "id$(a.n)"
end

# Render a node as an IP-free s-expression. Identifiers -> verbatim (if a known builtin/keyword)
# or `idN`; strings/numbers stripped; comments/continuations dropped.
function _anon_sexpr(io::IO, cst::MatlabCST, n::CSTNode, a::_Anon, known)
    k = n.kind
    if k === :comment || k === :line_continuation
        return
    elseif k === :identifier
        t = nodetext(cst, n)
        print(io, Symbol(t) in known ? t : _ph!(a, t))
        return
    elseif k === :string || k === :string_content
        print(io, "\"<str>\"")
        return
    elseif k === :number
        print(io, "<num>")
        return
    end
    kids = filter(c -> c.named && c.kind !== :line_continuation && c.kind !== :comment, n.children)
    if isempty(kids)
        print(io, "(", k, ")")
    else
        print(io, "(", k)
        for c in kids
            print(io, " ")
            _anon_sexpr(io, cst, c, a, known)
        end
        print(io, ")")
    end
    return
end
function _anon_sexpr(cst::MatlabCST, n::CSTNode, a::_Anon, known)
    io = IOBuffer()
    _anon_sexpr(io, cst, n, a, known)
    return String(take!(io))
end

# Replace any anonymized user name with its placeholder in free text (longest first, so a name
# that is a prefix of another doesn't partially match).
function _scrub(text::AbstractString, a::_Anon)
    out = String(text)
    for name in sort(collect(keys(a.map)); by = length, rev = true)
        out = replace(out, Regex("\\b\\Q" * name * "\\E\\b") => a.map[name])   # whole-word only
    end
    return out
end

# Try to load the emitted Julia in a throwaway module and capture an IP-free, scrubbed first line of
# any error. This is what catches "the output didn't compile" — the syntax gate only checks parsing;
# this surfaces UndefVarErrors (e.g. an unmapped function), missing imports, struct/method errors, …
# NOTE: it *executes* the generated top-level code (function/struct defs are harmless; a converted
# *script* runs its statements), so it is opt-in.
function _load_status(src::AbstractString, a::_Anon)
    out = convert_matlab(src).julia
    try
        Base.include_string(Module(:MjolnirLoadProbe), out)
        return Dict{String, Any}("loads" => true)
    catch e
        msg = first(split(sprint(showerror, e), '\n'))
        return Dict{String, Any}("loads" => false, "error" => _scrub(msg, a))
    end
end

"""
    conversion_report(src::AbstractString; check_load=false) -> Dict

Build an **IP-free** report of everything that went wrong converting MATLAB `src`, suitable for
filing a Mjolnir bug without sharing the source. Conversion is resilient (it does not stop at the
first error), so one report captures every problem.

The report anonymizes user variable/function names to `idN` placeholders, strips string and number
literals, drops comments, and scrubs the same names out of exception messages and todos. MATLAB
keywords and recognized builtins are kept verbatim (they are MATLAB's public API). Keys:

- `summary` — counts (statements, parse error, lowering exceptions, todos, placeholders)
- `problems` — parse errors and caught lowering exceptions, each with an anonymized `context`
- `todos` — scrubbed conversion todos (unhandled nodes, unmapped calls, …)
- `skeleton` — the whole unit as an anonymized node-kind s-expression
- `load` — *(only with `check_load=true`)* whether the emitted Julia loads, and a scrubbed
  first-line error if not. **`check_load` executes the generated top-level code** (safe for
  function/`classdef` files; a converted *script* runs its statements), so it is off by default.

See also [`conversion_report_json`](@ref).
"""
function conversion_report(src::AbstractString; check_load::Bool = false)
    cst = parse_matlab(src)
    ctx = Ctx(
        cst, collect_vars(cst), String[], Set{Symbol}(), collect_classes(cst),
        Ref(false), Set{Symbol}(), collect_callables(cst), Set{Symbol}(), Any[]
    )
    cst.has_error && push!(ctx.todos, "parse error: input contains MATLAB the grammar could not parse")
    lower_unit(ctx)                       # resilient: fills ctx.todos and ctx.errors, never throws out
    known = _known_names()
    a = _Anon()
    skeleton = _anon_sexpr(cst, cst.root, a, known)    # also populates the placeholder map

    problems = Any[]
    for e in ctx.errors
        push!(
            problems, Dict(
                "type" => "lowering_exception",
                "node_kind" => string(e.kind),
                "exception" => _scrub(e.exception, a),
                "context" => _anon_sexpr(cst, e.node, a, known),
            )
        )
    end
    for er in findkind(cst, :ERROR)
        push!(
            problems, Dict(
                "type" => "parse_error", "node_kind" => "ERROR",
                "context" => _anon_sexpr(cst, er, a, known),
            )
        )
    end

    reproducer = let io = IOBuffer()
        _repro(io, cst, cst.root, a, known)     # reuse `a` -> placeholders match the skeleton
        strip(String(take!(io)))
    end

    report = Dict{String, Any}(
        "report_version" => 1,
        "reproducer" => reproducer,
        "summary" => Dict(
            "statements" => length(filter(c -> c.named && c.kind !== :comment, cst.root.children)),
            "parse_has_error" => cst.has_error,
            "lowering_exceptions" => length(ctx.errors),
            "problems" => length(problems),
            "todos" => length(ctx.todos),
            "placeholders" => length(a.map),
        ),
        "problems" => problems,
        "todos" => [_scrub(t, a) for t in ctx.todos],
        "skeleton" => skeleton,
    )
    check_load && (report["load"] = _load_status(src, a))
    return report
end

"""
    conversion_report_json(src::AbstractString) -> String

[`conversion_report`](@ref) serialized to JSON (IP-free) for sharing.
"""
conversion_report_json(src::AbstractString; check_load::Bool = false) =
    JSON.json(conversion_report(src; check_load))

# --- reproducer: un-parse the (anonymized) CST back to synthetic MATLAB ---------------------------
# Best-effort: covers the common node kinds; identifiers become placeholders, literals become
# dummies, operators/keywords are kept. Lets a maintainer reproduce a reported bug locally without
# the original source. Unknown kinds fall back to emitting their named children.

_repro_op(cst::MatlabCST, n::CSTNode) = begin
    for c in n.children
        c.named || return nodetext(cst, c)
    end
    "?"
end

_repro_kids(n::CSTNode) = filter(c -> c.named && c.kind !== :comment && c.kind !== :line_continuation, n.children)

function _repro(io::IO, cst::MatlabCST, n::CSTNode, a::_Anon, known)
    k = n.kind
    kids = _repro_kids(n)
    if k === :source_file
        for c in kids
            _repro(io, cst, c, a, known)
            println(io)
        end
    elseif k === :identifier
        t = nodetext(cst, n)
        print(io, Symbol(t) in known ? t : _ph!(a, t))
    elseif k === :number
        print(io, "1")
    elseif k === :string || k === :string_content
        print(io, "'s'")
    elseif k === :boolean || k === :end_keyword || k === :spread_operator
        print(io, nodetext(cst, n))
    elseif k === :assignment
        l = _field(n, :left)
        r = _field(n, :right)
        l === nothing || _repro(io, cst, l, a, known)
        print(io, " = ")
        r === nothing || _repro(io, cst, r, a, known)
        print(io, ";")
    elseif k === :binary_operator || k === :comparison_operator || k === :boolean_operator
        _repro(io, cst, kids[1], a, known)
        print(io, " ", _repro_op(cst, n), " ")
        _repro(io, cst, kids[2], a, known)
    elseif k === :unary_operator
        print(io, _repro_op(cst, n))
        _repro(io, cst, kids[1], a, known)
    elseif k === :postfix_operator
        _repro(io, cst, kids[1], a, known)
        print(io, _repro_op(cst, n))
    elseif k === :parenthesis
        print(io, "(")
        isempty(kids) || _repro(io, cst, kids[1], a, known)
        print(io, ")")
    elseif k === :range
        for (i, c) in enumerate(kids)
            i > 1 && print(io, ":")
            _repro(io, cst, c, a, known)
        end
    elseif k === :function_call
        brace = any(c -> c.kind === Symbol("{"), n.children)
        nmn = _field(n, :name)
        argn = _childkind(n, :arguments)
        nmn === nothing || _repro(io, cst, nmn, a, known)
        print(io, brace ? "{" : "(")
        _repro_args(io, cst, argn, a, known)
        print(io, brace ? "}" : ")")
    elseif k === :field_expression
        o = _field(n, :object)
        f = _field(n, :field)
        o === nothing || _repro(io, cst, o, a, known)
        print(io, ".")
        f === nothing || _repro(io, cst, f, a, known)
    elseif k === :matrix || k === :cell
        op, cl = k === :matrix ? ("[", "]") : ("{", "}")
        print(io, op)
        rows = _childrenkind(n, :row)
        for (ri, row) in enumerate(rows)
            ri > 1 && print(io, "; ")
            els = filter(c -> c.named, row.children)
            for (i, c) in enumerate(els)
                i > 1 && print(io, ", ")
                _repro(io, cst, c, a, known)
            end
        end
        print(io, cl)
    elseif k === :function_definition
        outn = _childkind(n, :function_output)
        nmn = _field(n, :name)
        argn = _childkind(n, :function_arguments)
        blk = _childkind(n, :block)
        print(io, "function ")
        if outn !== nothing
            ids = _childrenkind(outn, :identifier)
            isempty(ids) || (_repro(io, cst, ids[1], a, known); print(io, " = "))
        end
        nmn === nothing || _repro(io, cst, nmn, a, known)
        print(io, "(")
        if argn !== nothing
            ids = _childrenkind(argn, :identifier)
            for (i, c) in enumerate(ids)
                i > 1 && print(io, ", ")
                _repro(io, cst, c, a, known)
            end
        end
        println(io, ")")
        _repro_block(io, cst, blk, a, known)
        print(io, "end")
    elseif k === :if_statement || k === :for_statement || k === :while_statement
        kw = k === :if_statement ? "if" : (k === :for_statement ? "for" : "while")
        cond = k === :for_statement ? _childkind(n, :iterator) : _field(n, :condition)
        print(io, kw, " ")
        cond === nothing || _repro(io, cst, cond, a, known)
        println(io)
        _repro_block(io, cst, _childkind(n, :block), a, known)
        print(io, "end")
    elseif k === :iterator
        id = _childkind(n, :identifier)
        rng = filter(c -> c.named && c.kind !== :identifier, n.children)
        id === nothing || _repro(io, cst, id, a, known)
        print(io, " = ")
        isempty(rng) || _repro(io, cst, rng[1], a, known)
    else
        # Unknown kind: emit its named children space-separated (keeps output mostly parseable).
        for (i, c) in enumerate(kids)
            i > 1 && print(io, " ")
            _repro(io, cst, c, a, known)
        end
        isempty(kids) && print(io, "id0")
    end
    return
end

function _repro_args(io::IO, cst::MatlabCST, argn, a::_Anon, known)
    argn === nothing && return
    args = filter(c -> c.named && c.kind !== :comment, argn.children)
    for (i, c) in enumerate(args)
        i > 1 && print(io, ", ")
        _repro(io, cst, c, a, known)
    end
    return
end

function _repro_block(io::IO, cst::MatlabCST, blk, a::_Anon, known)
    blk === nothing && return
    for c in _repro_kids(blk)
        print(io, "    ")
        _repro(io, cst, c, a, known)
        println(io)
    end
    return
end

"""
    replay_report(report::AbstractDict) -> Dict

Reconstruct a synthetic, IP-free MATLAB reproducer from a [`conversion_report`](@ref) and re-run
the conversion on it, returning a fresh report. This lets a maintainer reproduce a reported problem
locally **without the original source** — identifiers are placeholders, literals are dummies, only
node structure and MATLAB keywords/builtins are preserved. The reconstructed source is in
`report["reproducer"]`; `replay_report` runs `conversion_report` on it.

Best-effort: the reproducer covers the common node kinds and may not re-trigger issues that depend
on specific literal values or rare constructs.
"""
replay_report(report::AbstractDict) = conversion_report(String(report["reproducer"]))
