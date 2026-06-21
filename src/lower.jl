# Lower: MATLAB CST -> Julia AST (`Expr`).
#
# Stage 3 of the pipeline. Operates directly on the concrete syntax tree, using a small
# scope pre-pass to resolve MATLAB's `name(...)` ambiguity (function call vs. array index)
# and the builtin registry (builtins.jl) for function mapping. The result is a vector of
# top-level Julia expressions, rendered to source by emit.jl.

struct Ctx
    cst::MatlabCST
    vars::Set{Symbol}
    todos::Vector{String}
    imports::Set{Symbol}
    classes::Set{Symbol}
    in_method::Base.RefValue{Bool}   # true while lowering classdef method/ctor bodies
    structs_seen::Set{Symbol}        # struct vars already initialized (incremental field build)
    callables::Set{Symbol}           # vars assigned a function handle -> `f(x)` stays a call
end

# ---------------------------------------------------------------------------------------
# CST navigation helpers
# ---------------------------------------------------------------------------------------

_field(n::CSTNode, f::Symbol) = (
    for c in n.children
        c.field === f && return c
    end; nothing
)
_childkind(n::CSTNode, k::Symbol) = (
    for c in n.children
        c.kind === k && return c
    end; nothing
)
_childrenkind(n::CSTNode, k::Symbol) = filter(c -> c.kind === k, n.children)
# Named children, minus `...` line-continuations (transparent; they're not real elements).
_named(n::CSTNode) = filter(c -> c.named && c.kind !== :line_continuation, n.children)

"Text of the operator token (first anonymous child)."
function _optoken(ctx::Ctx, n::CSTNode)
    for c in n.children
        c.named || return nodetext(ctx.cst, c)
    end
    error("Mjolnir: no operator token in $(n.kind)")
end

# MATLAB identifiers that are Julia reserved words must be renamed on emit (e.g. a variable
# `const` -> `const_`). Applied consistently to every name -> Julia-symbol conversion.
const _JULIA_RESERVED = Set(
    [
        :baremodule, :begin, :break, :catch, :const, :continue, :do, :else, :elseif, :end,
        :export, :false, :finally, :for, :function, :global, :if, :import, :let, :local,
        :macro, :module, :quote, :return, :struct, :true, :try, :using, :while,
        :in, :isa, :where, :abstract, :mutable, :primitive, :type, :ccall,
    ]
)
_sanitize(s::Symbol) = s in _JULIA_RESERVED ? Symbol(s, "_") : s

_idsym(ctx::Ctx, n::CSTNode) = _sanitize(Symbol(nodetext(ctx.cst, n)))

# ---------------------------------------------------------------------------------------
# Scope pre-pass: which names are variables (so `x(i)` -> index, not call)
# ---------------------------------------------------------------------------------------

function collect_vars(cst::MatlabCST)
    vars = Set{Symbol}()
    walk(cst) do n
        if n.kind === :assignment
            _collect_lhs!(vars, cst, _field(n, :left))
        elseif n.kind === :iterator
            id = _childkind(n, :identifier)
            id === nothing || push!(vars, Symbol(nodetext(cst, id)))
        elseif n.kind === :function_arguments
            for a in _childrenkind(n, :identifier)
                push!(vars, Symbol(nodetext(cst, a)))
            end
        elseif n.kind === :function_output
            for a in _named(n)
                if a.kind === :identifier
                    push!(vars, Symbol(nodetext(cst, a)))
                elseif a.kind === :multioutput_variable
                    for id in _childrenkind(a, :identifier)
                        push!(vars, Symbol(nodetext(cst, id)))
                    end
                end
            end
        end
    end
    return vars
end

# Variables assigned a function handle (`f = @(x)…` or `f = @name`) so that later `f(x)` is
# lowered as a call, not array indexing. (Function-handle *parameters* remain ambiguous and are
# still treated as indexing — a documented limitation; MATLAB resolves call-vs-index at runtime.)
function collect_callables(cst::MatlabCST)
    callables = Set{Symbol}()
    walk(cst) do n
        if n.kind === :assignment
            left = _field(n, :left)
            right = _field(n, :right)
            if left !== nothing && left.kind === :identifier && right !== nothing &&
                    (right.kind === :lambda || right.kind === :handle_operator)
                push!(callables, Symbol(nodetext(cst, left)))
            end
        end
    end
    return callables
end

function collect_classes(cst::MatlabCST)
    classes = Set{Symbol}()
    walk(cst) do n
        if n.kind === :class_definition
            nm = _field(n, :name)
            nm === nothing || push!(classes, Symbol(nodetext(cst, nm)))
        end
    end
    return classes
end

function _collect_lhs!(vars, cst, left)
    left === nothing && return
    if left.kind === :identifier
        push!(vars, Symbol(nodetext(cst, left)))
    elseif left.kind === :multioutput_variable
        for id in _childrenkind(left, :identifier)
            push!(vars, Symbol(nodetext(cst, id)))
        end
    elseif left.kind === :function_call
        nm = _field(left, :name)
        nm === nothing || push!(vars, Symbol(nodetext(cst, nm)))
    elseif left.kind === :field_expression
        obj = _field(left, :object)
        if obj !== nothing
            if obj.kind === :identifier
                push!(vars, Symbol(nodetext(cst, obj)))
            elseif obj.kind === :function_call          # struct-array element: s(i).field = v
                nm = _field(obj, :name)
                nm === nothing || push!(vars, Symbol(nodetext(cst, nm)))
            end
        end
    end
    return
end

# ---------------------------------------------------------------------------------------
# Operator maps
# ---------------------------------------------------------------------------------------

# MATLAB `+`/`-` do implicit expansion (broadcast), so they map to `.+`/`.-` to match scalar
# ± array. `*` `/` `^` `\` stay as matrix operators (MATLAB's element-wise forms are the
# dotted variants). A Phase-3 idiomatic pass can de-broadcast where shapes are known scalar.
const OPMAP = Dict{String, Symbol}(
    "+" => :.+, "-" => :.-, "*" => :*, "/" => :/, "\\" => :\, "^" => :^,
    ".*" => :.*, "./" => :./, ".^" => :.^, ".\\" => :.\,
    "&" => :.&, "|" => :.|,
)

const CMPMAP = Dict{String, Symbol}(
    "==" => :.==, "~=" => :.!=, "!=" => :.!=,
    "<" => :.<, ">" => :.>, "<=" => :.<=, ">=" => :.>=,
)

# ---------------------------------------------------------------------------------------
# Expressions
# ---------------------------------------------------------------------------------------

function lower_expr(ctx::Ctx, n::CSTNode)
    k = n.kind
    if k === :identifier
        return lower_ident(ctx, n)
    elseif k === :number
        return lower_number(nodetext(ctx.cst, n))
    elseif k === :string
        return lower_string(ctx, n)
    elseif k === :parenthesis
        inner = _named(n)
        return isempty(inner) ? nothing : lower_expr(ctx, inner[1])
    elseif k === :binary_operator
        kids = _named(n)
        op = _optoken(ctx, n)
        sym = get(OPMAP, op, nothing)
        sym === nothing && (push!(ctx.todos, "unknown binary op $op"); sym = Symbol(op))
        return Expr(:call, sym, lower_expr(ctx, kids[1]), lower_expr(ctx, kids[2]))
    elseif k === :comparison_operator
        kids = _named(n)
        op = _optoken(ctx, n)
        sym = get(CMPMAP, op, Symbol(op))
        return Expr(:call, sym, lower_expr(ctx, kids[1]), lower_expr(ctx, kids[2]))
    elseif k === :boolean_operator
        kids = _named(n)
        op = _optoken(ctx, n)
        head = op == "||" ? :|| : :&&
        return Expr(head, lower_expr(ctx, kids[1]), lower_expr(ctx, kids[2]))
    elseif k === :unary_operator
        kids = _named(n)
        op = _optoken(ctx, n)
        e = lower_expr(ctx, kids[1])
        return op == "+" ? e : Expr(:call, Symbol(op), e)
    elseif k === :not_operator
        return Expr(:call, :.!, lower_expr(ctx, _named(n)[1]))
    elseif k === :postfix_operator
        kids = _named(n)
        op = _optoken(ctx, n)
        e = lower_expr(ctx, kids[1])
        return op == ".'" ? Expr(:call, :transpose, e) : Expr(Symbol("'"), e)
    elseif k === :range
        return lower_range(ctx, _named(n))
    elseif k === :function_call
        return lower_call_or_index(ctx, n)
    elseif k === :matrix
        return lower_matrix(ctx, n)
    elseif k === :cell
        return lower_cell(ctx, n)
    elseif k === :field_expression
        objnode = _field(n, :object)
        fldnode = _field(n, :field)
        if fldnode.kind === :indirect_access                # dynamic field read: s.(f)
            fexpr = lower_expr(ctx, _named(fldnode)[1])
            return Expr(:call, :getproperty, lower_expr(ctx, objnode), Expr(:call, :Symbol, fexpr))
        end
        if fldnode.kind === :function_call
            fname = Symbol(nodetext(ctx.cst, _field(fldnode, :name)))
            # containers.Map(...) -> Dict
            if objnode.kind === :identifier && nodetext(ctx.cst, objnode) == "containers" && fname === :Map
                return lower_containers_map(ctx, fldnode)
            end
            # method-call syntax obj.method(args) -> method(obj, args...)
            an = _childkind(fldnode, :arguments)
            margs = an === nothing ? Any[] : map(c -> lower_expr(ctx, c), _named(an))
            return Expr(:call, fname, lower_expr(ctx, objnode), margs...)
        end
        return Expr(:., lower_expr(ctx, objnode), QuoteNode(Symbol(nodetext(ctx.cst, fldnode))))
    elseif k === :lambda                                 # @(x) expr  ->  x -> expr
        argsnode = _childkind(n, :arguments)
        idnodes = argsnode === nothing ? CSTNode[] : _childrenkind(argsnode, :identifier)
        ps = [_idsym(ctx, a) for a in idnodes]
        raw = Set(Symbol(nodetext(ctx.cst, a)) for a in idnodes)   # scope params as variables
        added = setdiff(raw, ctx.vars)
        union!(ctx.vars, added)
        bodyexpr = lower_expr(ctx, _field(n, :expression))         # so `x(i)` inside indexes
        setdiff!(ctx.vars, added)
        sig = length(ps) == 1 ? ps[1] : Expr(:tuple, ps...)
        return Expr(:->, sig, bodyexpr)
    elseif k === :handle_operator                        # @name  ->  name (function reference)
        return lower_expr(ctx, _named(n)[1])
    elseif k === :end_keyword
        return Symbol("end")
    elseif k === :spread_operator
        return Expr(:call, :Colon)
    elseif k === :boolean
        return nodetext(ctx.cst, n) == "true"
    else
        push!(ctx.todos, "unhandled expr node: $k")
        return Expr(:call, :error, "TODO(mjolnir): unhandled $(k)")
    end
end

function lower_ident(ctx::Ctx, n::CSTNode)
    s = Symbol(nodetext(ctx.cst, n))
    if !(s in ctx.vars) && haskey(IDENT_MAP, s)
        return IDENT_MAP[s]
    end
    return _sanitize(s)
end

function lower_number(t::AbstractString)
    if occursin(r"^0[xX]", t)
        return parse(Int, t[3:end]; base = 16)
    end
    v = tryparse(Int, t)
    v !== nothing && return v
    f = tryparse(Float64, t)
    f !== nothing && return f
    m = match(r"^([0-9.eE+\-]+)[ij]$", t)
    m !== nothing && return Expr(:call, :*, parse(Float64, m.captures[1]), :im)
    error("Mjolnir: cannot parse number literal: $t")
end

function lower_string(ctx::Ctx, n::CSTNode)
    raw = nodetext(ctx.cst, n)
    length(raw) < 2 && return ""
    inner = chop(raw; head = 1, tail = 1)            # strip quotes (UTF-8 safe; e.g. 'ε')
    return startswith(raw, "'") ? replace(inner, "''" => "'") : replace(inner, "\"\"" => "\"")
end

function lower_range(ctx::Ctx, kids)
    parts = map(c -> lower_expr(ctx, c), kids)
    return Expr(:call, :(:), parts...)
end

function lower_call_or_index(ctx::Ctx, n::CSTNode)
    namenode = _field(n, :name)
    argsnode = _childkind(n, :arguments)
    args = argsnode === nothing ? Any[] : map(c -> lower_expr(ctx, c), _named(argsnode))
    if namenode.kind !== :identifier                  # computed callee, e.g. f{j}(x) -> (f[j])(x)
        return Expr(:call, lower_expr(ctx, namenode), args...)
    end
    name = Symbol(nodetext(ctx.cst, namenode))
    if name in ctx.callables                          # known function handle -> call
        return Expr(:call, name, args...)
    end
    if name in ctx.vars
        return Expr(:ref, name, args...)              # array indexing (1-based in both)
    end
    b = lower_builtin(ctx, name, args)
    b !== nothing && return b
    push!(ctx.todos, "unmapped function: $name")
    return Expr(:call, name, args...)
end

# containers.Map(...) -> Dict.  Map(keycell, valcell) -> Dict(zip(keys, vals)); Map() -> Dict();
# Map(k, v) -> Dict(k => v); the 'KeyType'/'ValueType' param form -> Dict() + TODO.
_is_cell(e) = e isa Expr && e.head === :ref && e.args[1] === :Any
function lower_containers_map(ctx::Ctx, fcall::CSTNode)
    an = _childkind(fcall, :arguments)
    args = an === nothing ? Any[] : map(c -> lower_expr(ctx, c), _named(an))
    if isempty(args)
        return Expr(:call, :Dict)
    elseif args[1] isa AbstractString && args[1] in ("KeyType", "ValueType", "UniformValues")
        push!(ctx.todos, "containers.Map type-parameter form not modeled -> empty Dict")
        return Expr(:call, :Dict)
    elseif length(args) >= 2 && _is_cell(args[1]) && _is_cell(args[2])
        return Expr(:call, :Dict, Expr(:call, :zip, args[1], args[2]))
    elseif length(args) >= 2
        return Expr(:call, :Dict, Expr(:call, :(=>), args[1], args[2]))
    end
    push!(ctx.todos, "containers.Map($(length(args)) args) not modeled -> empty Dict")
    return Expr(:call, :Dict)
end

# MATLAB cell array {…} -> heterogeneous Julia array `Any[…]` (`c{i}` already lowers to `c[i]`).
function lower_cell(ctx::Ctx, n::CSTNode)
    rows = _childrenkind(n, :row)
    isempty(rows) && return Expr(:ref, :Any)                       # {} -> Any[]
    rowelems = [map(c -> lower_expr(ctx, c), _named(r)) for r in rows]
    if length(rowelems) == 1
        return Expr(:ref, :Any, rowelems[1]...)                    # Any[a, b, c]
    end
    return Expr(:typed_vcat, :Any, (Expr(:row, r...) for r in rowelems)...)
end

function lower_matrix(ctx::Ctx, n::CSTNode)
    rows = _childrenkind(n, :row)
    isempty(rows) && return Expr(:vect)               # []
    rowelems = [map(c -> lower_expr(ctx, c), _named(r)) for r in rows]
    if length(rowelems) == 1
        e = rowelems[1]
        length(e) == 1 && return e[1]
        # MATLAB single-row `[...]` is a 1×N matrix (and `[A b]` is horizontal concatenation) ->
        # hcat, matching MATLAB shape/transpose/concat fidelity.
        return Expr(:hcat, e...)
    elseif all(r -> length(r) == 1, rowelems)
        return Expr(:vcat, (r[1] for r in rowelems)...)
    else
        return Expr(:vcat, (Expr(:row, r...) for r in rowelems)...)
    end
end

# ---------------------------------------------------------------------------------------
# Statements
# ---------------------------------------------------------------------------------------

function lower_stmt(ctx::Ctx, n::CSTNode)
    k = n.kind
    if k === :assignment
        return lower_assignment(ctx, n)
    elseif k === :function_call
        return lower_expr(ctx, n)
    elseif k === :if_statement
        return lower_if(ctx, n)
    elseif k === :for_statement
        return lower_for(ctx, n)
    elseif k === :while_statement
        return lower_while(ctx, n)
    elseif k === :function_definition
        return lower_function(ctx, n)
    elseif k === :class_definition
        return lower_class(ctx, n)
    elseif k === :break_statement
        return Expr(:break)
    elseif k === :continue_statement
        return Expr(:continue)
    elseif k === :return_statement
        return Expr(:return)                 # outputs are filled in by lower_function
    elseif k === :switch_statement
        return lower_switch(ctx, n)
    elseif k === :try_statement
        return lower_try(ctx, n)
    elseif k === :comment
        return nothing
    elseif k === :command
        nm = _childkind(n, :command_name)
        push!(ctx.todos, "dropped MATLAB command: $(nm === nothing ? "?" : nodetext(ctx.cst, nm))")
        return nothing                                   # clc/format/hold/... have no Julia equivalent
    else
        push!(ctx.todos, "unhandled statement node: $k")
        return nothing
    end
end

# A statement may lower to nothing (skip), one Expr, or several (e.g. a class_definition).
_append_stmt!(stmts, ::Nothing) = stmts
_append_stmt!(stmts, s) = (push!(stmts, s); stmts)
_append_stmt!(stmts, ss::Vector) = (append!(stmts, ss); stmts)

function lower_block(ctx::Ctx, blk::CSTNode)
    stmts = Any[]
    for c in _named(blk)
        _append_stmt!(stmts, lower_stmt(ctx, c))
    end
    return Expr(:block, stmts...)
end

function lower_assignment(ctx::Ctx, n::CSTNode)
    left = _field(n, :left)
    rhs = lower_expr(ctx, _field(n, :right))
    if left.kind === :identifier
        return Expr(:(=), _idsym(ctx, left), rhs)
    elseif left.kind === :multioutput_variable
        targets = [_idsym(ctx, id) for id in _childrenkind(left, :identifier)]
        return Expr(:(=), Expr(:tuple, targets...), rhs)
    elseif left.kind === :function_call
        name = _idsym(ctx, _field(left, :name))
        argsnode = _childkind(left, :arguments)
        idx = argsnode === nothing ? Any[] : map(c -> lower_expr(ctx, c), _named(argsnode))
        return Expr(:(=), Expr(:ref, name, idx...), rhs)
    elseif left.kind === :field_expression
        return lower_field_assign(ctx, left, rhs)
    else
        push!(ctx.todos, "unhandled assignment LHS: $(left.kind)")
        return Expr(:(=), :_, rhs)
    end
end

# Field-assignment LHS, covering: dynamic `s.(f)=v`, struct-array `s(i).field=v`, classdef
# in-place `obj.field=v`, and script-struct NamedTuple build `s.field=v`.
function lower_field_assign(ctx::Ctx, left::CSTNode, rhs)
    objnode = _field(left, :object)
    fldnode = _field(left, :field)

    if fldnode.kind === :indirect_access                      # s.(f) = v  (dynamic field)
        keysym = Expr(:call, :Symbol, lower_expr(ctx, _named(fldnode)[1]))
        if ctx.in_method[]
            return Expr(:call, :setproperty!, lower_expr(ctx, objnode), keysym, rhs)
        end
        nt = Expr(:call, Expr(:curly, :NamedTuple, Expr(:tuple, keysym)), Expr(:tuple, rhs))
        if objnode.kind === :identifier
            s = Symbol(nodetext(ctx.cst, objnode))
            return Expr(:(=), s, Expr(:call, :merge, s, nt))
        end
        push!(ctx.todos, "dynamic field assign on a non-identifier object")
        return Expr(:(=), :_, rhs)
    end

    fld = Symbol(nodetext(ctx.cst, fldnode))

    if objnode.kind === :function_call                        # s(i).field = v  (struct array)
        base = lower_expr(ctx, objnode)                       # s[i]
        return Expr(:(=), base, Expr(:call, :merge, base, Expr(:tuple, Expr(:(=), fld, rhs))))
    end

    if ctx.in_method[]                                        # classdef object: in-place set
        return Expr(:(=), Expr(:., lower_expr(ctx, objnode), QuoteNode(fld)), rhs)
    end

    if objnode.kind === :identifier                           # script struct: NamedTuple build
        s = Symbol(nodetext(ctx.cst, objnode))
        nt = Expr(:tuple, Expr(:(=), fld, rhs))
        if s in ctx.structs_seen
            return Expr(:(=), s, Expr(:call, :merge, s, nt))
        end
        push!(ctx.structs_seen, s)
        return Expr(:(=), s, nt)
    end

    return Expr(:(=), Expr(:., lower_expr(ctx, objnode), QuoteNode(fld)), rhs)  # nested s.a.b = v
end

function lower_if(ctx::Ctx, n::CSTNode)
    cond = lower_expr(ctx, _field(n, :condition))
    thenblk = lower_block(ctx, _childkind(n, :block))
    elseifs = _childrenkind(n, :elseif_clause)
    elsec = _childkind(n, :else_clause)
    elsepart = elsec === nothing ? nothing : lower_block(ctx, _childkind(elsec, :block))
    for ec in reverse(elseifs)
        c = lower_expr(ctx, _field(ec, :condition))
        b = lower_block(ctx, _childkind(ec, :block))
        elsepart = elsepart === nothing ? Expr(:elseif, c, b) : Expr(:elseif, c, b, elsepart)
    end
    return elsepart === nothing ? Expr(:if, cond, thenblk) : Expr(:if, cond, thenblk, elsepart)
end

function lower_for(ctx::Ctx, n::CSTNode)
    it = _childkind(n, :iterator)
    kids = _named(it)
    var = _idsym(ctx, kids[1])
    iterable = lower_expr(ctx, kids[2])
    body = lower_block(ctx, _childkind(n, :block))
    return Expr(:for, Expr(:(=), var, iterable), body)
end

function lower_while(ctx::Ctx, n::CSTNode)
    cond = lower_expr(ctx, _field(n, :condition))
    body = lower_block(ctx, _childkind(n, :block))
    return Expr(:while, cond, body)
end

# MATLAB switch/case/otherwise -> Julia if/elseif/else (Julia has no switch). A `case {a,b}`
# (cell) matches any value -> `sv == a || sv == b`.
function _case_test(ctx::Ctx, sv, condnode::CSTNode)
    if condnode.kind === :cell
        vals = [lower_expr(ctx, c) for r in _childrenkind(condnode, :row) for c in _named(r)]
        return foldl((a, b) -> Expr(:||, a, b), [Expr(:call, :(==), sv, v) for v in vals])
    end
    return Expr(:call, :(==), sv, lower_expr(ctx, condnode))
end

function lower_switch(ctx::Ctx, n::CSTNode)
    sv = lower_expr(ctx, _field(n, :condition))
    cases = _childrenkind(n, :case_clause)
    otherw = _childkind(n, :otherwise_clause)
    elsepart = otherw === nothing ? nothing : lower_block(ctx, _childkind(otherw, :block))
    isempty(cases) && return elsepart === nothing ? Expr(:block) : elsepart
    pairs = [(_case_test(ctx, sv, _field(cc, :condition)), lower_block(ctx, _childkind(cc, :block))) for cc in cases]
    for (test, blk) in reverse(pairs[2:end])
        elsepart = elsepart === nothing ? Expr(:elseif, test, blk) : Expr(:elseif, test, blk, elsepart)
    end
    t1, b1 = pairs[1]
    return elsepart === nothing ? Expr(:if, t1, b1) : Expr(:if, t1, b1, elsepart)
end

function lower_try(ctx::Ctx, n::CSTNode)
    tryblk = lower_block(ctx, _childkind(n, :block))
    cc = _childkind(n, :catch_clause)
    cc === nothing && return Expr(:try, tryblk, false, false)
    errid = _childkind(cc, :identifier)
    var = errid === nothing ? false : _idsym(ctx, errid)
    return Expr(:try, tryblk, var, lower_block(ctx, _childkind(cc, :block)))
end

# Replace a bare MATLAB `return` with one that carries the function's outputs.
_fill_returns(e, retval) = e
function _fill_returns(e::Expr, retval)
    (e.head === :function || e.head === :->) && return e
    if e.head === :return && isempty(e.args)
        return retval === nothing ? e : Expr(:return, retval)
    end
    return Expr(e.head, map(x -> _fill_returns(x, retval), e.args)...)
end

_uses_sym(e::Symbol, s) = e === s
_uses_sym(e::Expr, s) = any(a -> _uses_sym(a, s), e.args)
_uses_sym(::Any, s) = false

# Call-like args = no colon/range/end and no loop-index argument (those mark indexing).
function _calllike_args(ctx::Ctx, nd::CSTNode, loopidx)
    an = _childkind(nd, :arguments)
    an === nothing && return true
    for a in _named(an)
        a.kind in (:spread_operator, :range, :end_keyword) && return false
        a.kind === :identifier && Symbol(nodetext(ctx.cst, a)) in loopidx && return false
    end
    return true
end

# Loop-index variables introduced by `for` iterators within a block.
function _loopidx(ctx::Ctx, blk)
    idx = Set{Symbol}()
    walk(blk) do nd
        if nd.kind === :iterator
            id = _childkind(nd, :identifier)
            id === nothing || push!(idx, Symbol(nodetext(ctx.cst, id)))
        end
    end
    return idx
end

# Heuristic: a parameter that appears in the body ONLY as a call-like callee `p(...)` — never in
# arithmetic, never indexed-assigned, never with colon/range args, and never called with a loop
# index (which would be array indexing) — is a function handle, so its calls stay calls (`f(x)`,
# not `f[x]`). The loop-index exclusion avoids misclassifying read-only array params like `y(i)`.
function _callonly_params(ctx::Ctx, blk, params)
    isempty(params) && return Symbol[]
    pset = Set(params)
    loopidx = _loopidx(ctx, blk)
    total = Dict(p => 0 for p in params)
    callish = Dict(p => 0 for p in params)
    walk(blk) do nd
        if nd.kind === :identifier
            s = Symbol(nodetext(ctx.cst, nd))
            s in pset && (total[s] += 1)
        elseif nd.kind === :function_call
            nm = _field(nd, :name)
            if nm !== nothing && nm.kind === :identifier
                s = Symbol(nodetext(ctx.cst, nm))
                (s in pset && _calllike_args(ctx, nd, loopidx)) && (callish[s] += 1)
            end
        end
    end
    return [p for p in params if callish[p] >= 1 && total[p] == callish[p]]
end

function lower_function(ctx::Ctx, n::CSTNode)
    fname = _idsym(ctx, _field(n, :name))
    argsnode = _childkind(n, :function_arguments)
    params = argsnode === nothing ? Symbol[] :
        [_idsym(ctx, a) for a in _childrenkind(argsnode, :identifier)]

    # Function-handle parameters: add to callables for the duration of this body's lowering.
    blk = _childkind(n, :block)
    added = setdiff(_callonly_params(ctx, blk, params), ctx.callables)
    union!(ctx.callables, added)
    body = lower_block(ctx, blk)
    setdiff!(ctx.callables, added)

    # varargin -> a Julia varargs parameter `varargin...`
    has_vararg = !isempty(params) && params[end] === :varargin
    fixed = has_vararg ? params[1:(end - 1)] : params

    outnode = _childkind(n, :function_output)
    outs = Symbol[]
    if outnode !== nothing
        for a in _named(outnode)
            if a.kind === :identifier
                push!(outs, _idsym(ctx, a))
            elseif a.kind === :multioutput_variable
                append!(outs, (_idsym(ctx, id) for id in _childrenkind(a, :identifier)))
            end
        end
    end

    # If the body uses `nargin`, make trailing positional args optional and compute it. This
    # makes MATLAB's `if nargin < k` default-argument idiom work (idiomatic dispatch is later).
    uses_nargin = _uses_sym(body, :nargin)
    sig = Any[]
    pre = Any[]
    if uses_nargin
        for p in fixed
            push!(sig, Expr(:kw, p, :nothing))
        end
        terms = Any[Expr(:call, :!==, p, :nothing) for p in fixed]
        nexpr = isempty(terms) ? 0 : foldl((a, b) -> Expr(:call, :+, a, b), terms)
        has_vararg && (nexpr = Expr(:call, :+, nexpr, Expr(:call, :length, :varargin)))
        push!(pre, Expr(:(=), :nargin, nexpr))
    else
        append!(sig, fixed)
    end
    has_vararg && push!(sig, Expr(:..., :varargin))

    # `nargout`: Julia has no caller-arity introspection, so assume all declared outputs are
    # requested (the common case) — inject `nargout = <#outputs>` when the body uses it.
    _uses_sym(body, :nargout) && push!(pre, Expr(:(=), :nargout, length(outs)))

    retval = length(outs) == 1 ? outs[1] : (length(outs) > 1 ? Expr(:tuple, outs...) : nothing)
    bodystmts = Any[_fill_returns(s, retval) for s in body.args]   # early `return` carries outputs
    stmts = Any[pre...; bodystmts...]
    retval === nothing || push!(stmts, Expr(:return, retval))
    return Expr(:function, Expr(:call, fname, sig...), Expr(:block, stmts...))
end

# ---------------------------------------------------------------------------------------
# Unit
# ---------------------------------------------------------------------------------------

# ---------------------------------------------------------------------------------------
# classdef -> abstract type + mutable struct + methods
# ---------------------------------------------------------------------------------------

_abstractname(c::Symbol) = Symbol("Abstract", c)

function lower_class(ctx::Ctx, n::CSTNode)
    cname = _idsym(ctx, _field(n, :name))
    absname = _abstractname(cname)

    # superclasses (`handle` marks reference semantics, not a real parent)
    supers = Symbol[]
    sc = _childkind(n, :superclasses)
    if sc !== nothing
        for pn in _childrenkind(sc, :property_name)
            id = _childkind(pn, :identifier)
            id === nothing || push!(supers, Symbol(nodetext(ctx.cst, id)))
        end
    end
    realsupers = filter(s -> s !== :handle, supers)

    out = Any[]

    # abstract type: chain to a converted superclass's abstract type when available
    parentabs = nothing
    for s in realsupers
        if s in ctx.classes
            parentabs = _abstractname(s)
            break
        end
    end
    push!(
        out, parentabs === nothing ? Expr(:abstract, absname) :
            Expr(:abstract, Expr(:<:, absname, parentabs))
    )
    for s in realsupers
        s in ctx.classes ||
            push!(ctx.todos, "external superclass `$s` of `$cname`: inherited fields/methods not merged")
    end

    # properties -> fields (name, default-or-nothing)
    fields = Tuple{Symbol, Any}[]
    for pblk in _childrenkind(n, :properties)
        for p in _childrenkind(pblk, :property)
            pname = _idsym(ctx, _field(p, :name))
            dv = _childkind(p, :default_value)
            default = dv === nothing ? nothing : lower_expr(ctx, _named(dv)[1])
            push!(fields, (pname, default))
        end
    end

    # methods; the one named like the class is the constructor
    ctor = nothing
    methods = CSTNode[]
    for mblk in _childrenkind(n, :methods)
        for fdef in _childrenkind(mblk, :function_definition)
            mname = Symbol(nodetext(ctx.cst, _field(fdef, :name)))
            mname === cname ? (ctor = fdef) : push!(methods, fdef)
        end
    end

    # Inside classdef bodies, `obj.field = v` is an in-place set on the (mutable) struct.
    ctx.in_method[] = true
    try
        # struct body: fields + an inner constructor
        body = Any[f[1] for f in fields]
        push!(body, ctor === nothing ? _default_ctor(cname, fields) : _lower_ctor(ctx, ctor, cname))
        push!(out, Expr(:struct, true, Expr(:<:, cname, absname), Expr(:block, body...)))

        # methods as outer functions, dispatching on the concrete type
        for m in methods
            push!(out, _lower_method(ctx, m, cname))
        end
    finally
        ctx.in_method[] = false
    end
    return out
end

# MATLAB constructor `function obj = C(args) ... end` -> inner ctor using `new()`.
function _lower_ctor(ctx::Ctx, fdef::CSTNode, cname::Symbol)
    outnode = _childkind(fdef, :function_output)
    outvar = outnode === nothing ? :obj : _idsym(ctx, _named(outnode)[1])
    argsnode = _childkind(fdef, :function_arguments)
    params = argsnode === nothing ? Symbol[] :
        [_idsym(ctx, a) for a in _childrenkind(argsnode, :identifier)]
    stmts = Any[Expr(:(=), outvar, Expr(:call, :new))]
    for c in _named(_childkind(fdef, :block))
        _append_stmt!(stmts, lower_stmt(ctx, c))
    end
    push!(stmts, Expr(:return, outvar))
    return Expr(:function, Expr(:call, cname, params...), Expr(:block, stmts...))
end

# No MATLAB constructor: zero-arg inner ctor applying any property defaults (others left undef,
# mirroring MATLAB's empty defaults).
function _default_ctor(cname::Symbol, fields)
    stmts = Any[Expr(:(=), :obj, Expr(:call, :new))]
    for (name, default) in fields
        default === nothing || push!(stmts, Expr(:(=), Expr(:., :obj, QuoteNode(name)), default))
    end
    push!(stmts, Expr(:return, :obj))
    return Expr(:function, Expr(:call, cname), Expr(:block, stmts...))
end

function _lower_method(ctx::Ctx, fdef::CSTNode, cname::Symbol)
    f = lower_function(ctx, fdef)            # Expr(:function, Expr(:call, name, params...), body)
    call = f.args[1]
    if length(call.args) >= 2                # type the first (object) parameter
        p = call.args[2]
        call.args[2] = if p isa Expr && p.head === :kw          # optional param (nargin path)
            Expr(:kw, Expr(:(::), p.args[1], cname), p.args[2])
        elseif p isa Symbol
            Expr(:(::), p, cname)
        else
            p                                                   # e.g. varargin... — leave as is
        end
    end
    return f
end

"Lower a whole parsed unit into a vector of top-level Julia expressions."
function lower_unit(ctx::Ctx)
    stmts = Any[]
    for c in _named(ctx.cst.root)
        _append_stmt!(stmts, lower_stmt(ctx, c))
    end
    return stmts
end
