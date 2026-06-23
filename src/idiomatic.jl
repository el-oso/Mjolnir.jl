# Idiomatic rewrite passes: Julia AST -> more idiomatic Julia AST.
#
# Stage 4 of the pipeline. Deterministic, behavior-preserving cleanups applied after lowering
# and before emit. Every pass is conservative; the Octave differential oracle gates them.
#
#   * de-broadcast   — lowering broadcasts MATLAB `+ - == ~= & | ...` for safety; where a
#                      lightweight scalar-shape inference proves both operands scalar, rewrite
#                      `.+`/`.==`/`sqrt.(x)` back to `+`/`==`/`sqrt(x)`.
#   * de-colon       — `A[Colon()]` -> `A[:]`.
#   * script wrapper — wrap a loop-bearing script body in `let ... end` so top-level loop
#                      assignments work (Julia's soft-scope rule errors otherwise).

# ---------------------------------------------------------------------------------------
# Shape inference  (lattice: :scalar, :vector, :matrix, :unknown)
# ---------------------------------------------------------------------------------------
#
# Conservative and cheap. Drives two things: de-broadcasting (only when both operands are
# :scalar) and matrix-reduction fixups (only when an argument is provably :matrix).

const _ARITH = Set([:+, :-, :*, :/, :^, :.+, :.-, :.*, :./, :.^])
const _CMP = Set([:.==, :.!=, :.<, :.>, :.<=, :.>=, :(==), :!=, :<, :>, :<=, :>=])

shape_of(::Number, env) = :scalar
shape_of(::Bool, env) = :scalar
shape_of(s::Symbol, env) = get(env, s, :unknown)
shape_of(::AbstractString, env) = :unknown
shape_of(::Any, env) = :unknown

function _combine(shapes)
    any(==(:matrix), shapes) && return :matrix
    all(==(:scalar), shapes) && return :scalar
    any(==(:vector), shapes) && return :vector
    return :unknown
end

function shape_of(e::Expr, env)
    h = e.head
    if h === :call
        f = e.args[1]
        as = @view e.args[2:end]
        f === :(:) && return :vector
        (f === :length || f === :numel) && return :scalar
        f in (:sum, :prod, :maximum, :minimum) && return length(as) == 1 ? :scalar : :unknown
        f === :size && return length(as) >= 2 ? :scalar : :vector
        f in (:zeros, :ones, :rand, :randn) && return length(as) >= 2 ? :matrix : :vector
        f === :eye && return :matrix
        (f in _ARITH || f in _CMP) && return _combine(map(a -> shape_of(a, env), as))
        return :unknown
    elseif h === :ref
        return all(a -> shape_of(a, env) === :scalar, @view e.args[2:end]) ? :scalar : :unknown
    elseif h === :vcat
        return any(a -> a isa Expr && a.head === :row, e.args) ? :matrix : :vector
    elseif h === :vect || h === :hcat
        return :vector
    elseif h === Symbol("'")
        return shape_of(e.args[1], env)
    elseif h === :.
        if length(e.args) == 2 && e.args[2] isa Expr && e.args[2].head === :tuple
            return _combine(map(a -> shape_of(a, env), e.args[2].args))
        end
        return :unknown
    elseif h === :&& || h === :||
        return :scalar
    end
    return :unknown
end

is_scalar(e, env) = shape_of(e, env) === :scalar
is_matrix(e, env) = shape_of(e, env) === :matrix

# Collect definitions for the fixpoint: var -> list of RHS exprs; `forced` are surely non-scalar
# (indexed/tuple targets, loops over non-ranges). Recurses control flow, not nested functions.
function _collect_defs!(defs, forced, e)
    e isa Expr || return
    h = e.head
    if h === :(=)
        lhs = e.args[1]
        if lhs isa Symbol
            push!(get!(defs, lhs, Any[]), e.args[2])
        elseif lhs isa Expr && lhs.head === :ref
            lhs.args[1] isa Symbol && push!(forced, lhs.args[1])
        elseif lhs isa Expr && lhs.head === :tuple
            for t in lhs.args
                t isa Symbol && push!(forced, t)
            end
        end
    elseif h === :for
        it = e.args[1]
        if it isa Expr && it.head === :(=)
            v, iter = it.args[1], it.args[2]
            if iter isa Expr && iter.head === :call && iter.args[1] === :(:)
                push!(get!(defs, v, Any[]), 0)        # range element -> scalar
            elseif v isa Symbol
                push!(forced, v)
            end
        end
        _collect_defs!(defs, forced, e.args[2])
    elseif h === :while
        _collect_defs!(defs, forced, e.args[2])
    elseif h === :if || h === :elseif
        for a in @view e.args[2:end]
            _collect_defs!(defs, forced, a)
        end
    elseif h === :block
        for a in e.args
            _collect_defs!(defs, forced, a)
        end
    end
    # note: :function is intentionally not recursed (separate scope)
    return
end

function shape_env(stmts)
    defs = Dict{Symbol, Vector{Any}}()
    forced = Set{Symbol}()
    for s in stmts
        _collect_defs!(defs, forced, s)
    end
    # Optimistic start (:scalar) so self-referential accumulators (`acc = acc + x`) resolve to
    # :scalar; concretely-shaped right-hand sides override it on the first pass.
    env = Dict{Symbol, Symbol}(v => :scalar for v in keys(defs))
    for _ in 1:16                                   # fixpoint (bounded; converges quickly)
        changed = false
        for (v, rhss) in defs
            v in forced && continue
            sh = :bottom
            for r in rhss
                rs = shape_of(r, env)
                sh = sh === :bottom ? rs : (sh === rs ? sh : :unknown)
            end
            sh === :bottom && (sh = :unknown)
            if env[v] !== sh
                env[v] = sh
                changed = true
            end
        end
        changed || break
    end
    for v in forced
        env[v] = :unknown
    end
    return env
end

# ---------------------------------------------------------------------------------------
# Rewrites
# ---------------------------------------------------------------------------------------

const _DEBCAST = Dict{Symbol, Symbol}(
    :.+ => :+, :.- => :-, :.* => :*, :./ => :/, :.^ => :^,
    :.== => :(==), :.!= => :!=, :.< => :<, :.> => :>, :.<= => :<=, :.>= => :>=,
    :.& => :&, :.| => :|,
)

decolon(e) = e
function decolon(e::Expr)
    if e.head === :call && length(e.args) == 1 && e.args[1] === :Colon
        return Symbol(":")
    end
    return Expr(e.head, map(decolon, e.args)...)
end

debroadcast(e, scal) = e
function debroadcast(e::Expr, scal)
    if e.head === :call
        f = e.args[1]
        nargs = map(a -> debroadcast(a, scal), @view e.args[2:end])
        if haskey(_DEBCAST, f) && all(a -> is_scalar(a, scal), @view e.args[2:end])
            return Expr(:call, _DEBCAST[f], nargs...)
        elseif f === :.! && length(nargs) == 1 && is_scalar(e.args[2], scal)
            return Expr(:call, :!, nargs...)
        end
        return Expr(:call, f, nargs...)
    elseif e.head === :. && length(e.args) == 2 && e.args[2] isa Expr && e.args[2].head === :tuple
        targs = e.args[2].args
        nt = map(a -> debroadcast(a, scal), targs)
        if all(a -> is_scalar(a, scal), targs)
            return Expr(:call, e.args[1], nt...)       # sqrt.(x) -> sqrt(x)
        end
        return Expr(:., e.args[1], Expr(:tuple, nt...))
    end
    return Expr(e.head, map(a -> debroadcast(a, scal), e.args)...)
end

_rewrite(e, env) = debroadcast(decolon(e), env)

# ---------------------------------------------------------------------------------------
# Always-on semantic fix: MATLAB reductions over a matrix collapse the first dimension
# (a row vector), whereas Julia's `sum`/`prod`/`maximum`/`minimum` collapse to a scalar.
# Add `dims=1` only when the argument is provably a matrix; vectors stay scalar (correct).
# ---------------------------------------------------------------------------------------

_fixred(e, env) = e
function _fixred(e::Expr, env)
    if e.head === :call && length(e.args) == 2 && e.args[1] in (:sum, :prod, :maximum, :minimum)
        arg = _fixred(e.args[2], env)
        return is_matrix(e.args[2], env) ?
            Expr(:call, e.args[1], arg, Expr(:kw, :dims, 1)) :
            Expr(:call, e.args[1], arg)
    end
    return Expr(e.head, map(a -> _fixred(a, env), e.args)...)
end

# ---------------------------------------------------------------------------------------
# Loop-scope hoisting: MATLAB functions share one flat scope, but a Julia `for`/`while` body
# is its own scope. A variable first assigned inside a loop and used after it would be
# UndefVarError. Declare such variables `local` at the top of the enclosing scope.
# ---------------------------------------------------------------------------------------

function _walk_assigns(f, e, inloop)
    e isa Expr || return
    h = e.head
    if h === :(=)
        lhs = e.args[1]
        if lhs isa Symbol
            f(lhs, inloop)
        elseif lhs isa Expr && lhs.head === :tuple
            for t in lhs.args
                t isa Symbol && f(t, inloop)
            end
        end
    elseif h === :for || h === :while
        _walk_assigns(f, e.args[end], true)
    elseif h === :if || h === :elseif || h === :block || h === :let
        for a in @view e.args[(2 - (h === :block || h === :let)):end]
            _walk_assigns(f, a, inloop)
        end
    end
    # :function / :-> are separate scopes — not descended
    return
end

function _loop_index_vars(stmts)
    idx = Set{Symbol}()
    walkfor(e) = begin
        e isa Expr || return
        if e.head === :for && e.args[1] isa Expr && e.args[1].head === :(=) && e.args[1].args[1] isa Symbol
            push!(idx, e.args[1].args[1])
        end
        (e.head === :function || e.head === :->) && return
        foreach(walkfor, e.args)
    end
    foreach(walkfor, stmts)
    return idx
end

# `local` declarations needed so loop-assigned variables survive the loop. Parameters (already
# in scope) and loop-index variables are excluded.
function _loop_locals(stmts; exclude = Set{Symbol}())
    outside = Set{Symbol}()
    inloop = Set{Symbol}()
    _walk_assigns((v, il) -> push!(il ? inloop : outside, v), Expr(:block, stmts...), false)
    esc = setdiff(inloop, outside, _loop_index_vars(stmts), exclude)
    return sort!(collect(esc); by = string)
end

function _hoist_locals(bodyargs::Vector; exclude = Set{Symbol}())
    locs = _loop_locals(bodyargs; exclude)
    return isempty(locs) ? bodyargs : Any[Expr(:local, locs...), bodyargs...]
end

# Identifiers used outside any loop body (loop ranges/conditions count as outside).
function _outer_uses(stmts)
    s = Set{Symbol}()
    rec(e::Symbol) = push!(s, e)
    function rec(e)
        e isa Expr || return
        if e.head === :for
            rec(e.args[1].args[2])               # range only, not the body
        elseif e.head === :while
            rec(e.args[1])                        # condition only
        elseif !(e.head in (:function, :->))
            foreach(rec, e.args)
        end
        return
    end
    foreach(rec, stmts)
    return s
end

# A Julia `for` index never escapes the loop; MATLAB's does (keeps its last value). When the
# index is used after the loop, rename the loop variable and copy it into an outer variable.
function _capture(e, capset)
    e isa Expr || return e
    if e.head === :for && e.args[1] isa Expr && e.args[1].head === :(=) && e.args[1].args[1] in capset
        v = e.args[1].args[1]
        vnew = Symbol(v, "_i")
        body = _capture(e.args[2], capset)
        return Expr(
            :for, Expr(:(=), vnew, e.args[1].args[2]),
            Expr(:block, Expr(:(=), v, vnew), body.args...)
        )
    elseif e.head in (:function, :->)
        return e
    end
    return Expr(e.head, map(x -> _capture(x, capset), e.args)...)
end

# Make a statement list survive Julia's loop scoping: capture escaping loop indices, then
# declare loop-assigned-used-after variables `local`.
function _scope_fix(stmts; exclude = Set{Symbol}())
    capset = intersect(_loop_index_vars(stmts), _outer_uses(stmts))
    captured = Any[_capture(s, capset) for s in stmts]
    return _hoist_locals(captured; exclude)
end

function _param_name(p)
    p isa Symbol && return p
    p isa Expr && p.head in (:kw, :(::), :...) && return _param_name(p.args[1])
    return nothing
end

function _fixred_function(f::Expr)
    body = f.args[2]
    params = Set{Symbol}(filter(!isnothing, map(_param_name, f.args[1].args[2:end])))
    fixed = _fixred(body, shape_env(body.args))     # fixed is a :block
    return Expr(:function, f.args[1], Expr(:block, _scope_fix(fixed.args; exclude = params)...))
end

function run_semantic(stmts)
    tlenv = shape_env(filter(s -> !_isdef(s), stmts))
    return map(stmts) do s
        if s isa Expr && s.head === :function
            _fixred_function(s)
        elseif s isa Expr && s.head === :struct
            block = s.args[end]
            newargs = map(a -> (a isa Expr && a.head === :function) ? _fixred_function(a) : a, block.args)
            Expr(:struct, s.args[1:(end - 1)]..., Expr(:block, newargs...))
        elseif _isdef(s)
            s
        else
            _fixred(s, tlenv)
        end
    end
end

# ---------------------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------------------

# Collapse the MATLAB-ism `out = expr; return out` (single trailing assignment immediately returned)
# into `return expr`. Safe: `expr` is evaluated and returned either way, and we keep every earlier
# statement, so an accumulator (`s = 0; for …; s = s + …; end; return s`) — whose last assignment is
# inside the loop, not right before the return — is left untouched.
function _collapse_return(f::Expr)
    body = f.args[2]
    (body isa Expr && body.head === :block && length(body.args) >= 2) || return f
    last, pen = body.args[end], body.args[end - 1]
    if last isa Expr && last.head === :return && length(last.args) == 1 && last.args[1] isa Symbol &&
            pen isa Expr && pen.head === :(=) && pen.args[1] === last.args[1]
        newargs = Any[body.args[1:(end - 2)]...; Expr(:return, pen.args[2])]
        return Expr(:function, f.args[1], Expr(:block, newargs...))
    end
    return f
end

function _process_function(f::Expr)
    sig, body = f.args[1], f.args[2]
    env = shape_env(body.args)
    newbody = Expr(:block, map(s -> _rewrite(s, env), body.args)...)
    return _collapse_return(Expr(:function, sig, newbody))
end

# A `mutable struct` may carry inner constructors; de-broadcast those like any function.
function _process_struct(s::Expr)
    block = s.args[end]
    newargs = map(block.args) do a
        a isa Expr && a.head === :function ? _process_function(a) : a
    end
    return Expr(:struct, s.args[1:(end - 1)]..., Expr(:block, newargs...))
end

_isdef(s) = s isa Expr && (s.head === :function || s.head === :struct || s.head === :abstract)

function _process_def(s)
    s isa Expr || return s
    s.head === :function && return _process_function(s)
    s.head === :struct && return _process_struct(s)
    return s   # abstract type: nothing to rewrite
end

# ---------------------------------------------------------------------------------------
# loop -> comprehension:  [y = prealloc;] for i in r; y[i] = rhs(i); end  =>  y = [rhs for i in r]
# Conservative: single-statement body assigning y[i] with i the loop var, rhs independent of y.
# ---------------------------------------------------------------------------------------

const _PREALLOC = Set([:zeros, :ones, :fill, :similar, :Array, :Vector])

function _match_index_loop(s)
    (s isa Expr && s.head === :for) || return nothing
    itr = s.args[1]
    (itr isa Expr && itr.head === :(=) && itr.args[1] isa Symbol) || return nothing
    v, r = itr.args[1], itr.args[2]
    body = s.args[2]
    (body isa Expr && body.head === :block) || return nothing
    real = filter(x -> !(x isa LineNumberNode), body.args)
    length(real) == 1 || return nothing
    a = real[1]
    (a isa Expr && a.head === :(=)) || return nothing
    lhs, rhs = a.args[1], a.args[2]
    (lhs isa Expr && lhs.head === :ref && length(lhs.args) == 2 && lhs.args[2] === v) || return nothing
    y = lhs.args[1]
    (y isa Symbol && y !== v) || return nothing
    _uses_sym(rhs, y) && return nothing                 # depends on prior elements -> not pure
    return (y, v, r, rhs)
end

_is_prealloc(s, y) = s isa Expr && s.head === :(=) && s.args[1] === y &&
    (
    s.args[2] isa Expr && (
        (s.args[2].head === :call && s.args[2].args[1] in _PREALLOC) ||
            s.args[2].head === :vect
    )
)

function _comprehensions(stmts)
    out = Any[]
    for s in stmts
        m = _match_index_loop(s)
        if m !== nothing
            y, v, r, rhs = m
            !isempty(out) && _is_prealloc(out[end], y) && pop!(out)   # drop the preallocation
            push!(out, Expr(:(=), y, Expr(:comprehension, Expr(:generator, rhs, Expr(:(=), v, r)))))
        else
            push!(out, _recurse_comprehensions(s))
        end
    end
    return out
end

_cblock(b) = (b isa Expr && b.head === :block) ? Expr(:block, _comprehensions(b.args)...) : b
function _recurse_comprehensions(s)
    s isa Expr || return s
    if s.head === :function || s.head === :for || s.head === :while || s.head === :let
        return Expr(s.head, s.args[1], _cblock(s.args[end]))
    elseif s.head === :if || s.head === :elseif
        return Expr(
            s.head, s.args[1], (
                a isa Expr && a.head === :block ? _cblock(a) :
                    _recurse_comprehensions(a) for a in s.args[2:end]
            )...
        )
    elseif s.head === :block
        return _cblock(s)
    end
    return s
end

_has_loop(stmts) = any(s -> s isa Expr && (s.head === :for || s.head === :while), stmts)

"""
    run_idiomatic(stmts; wrap_script=true) -> Vector

Apply the deterministic idiomatic passes to lowered top-level statements. Definitions
(abstract types, structs, functions) are hoisted ahead of loose script statements, keeping
their relative order (so a struct precedes its methods); a loop-bearing script body is then
wrapped in `let ... end` when `wrap_script` is set.
"""
# Narrow a homogeneous cell literal `Any[1, 2, 3]` to a plain typed array `[1, 2, 3]` (drops the
# needless `Any`). Conservative: only when every element is a literal of one kind (all numbers or
# all strings), and never when the cell is bound to a variable that is element-assigned somewhere
# (e.g. `c{2} = 'x'`) — cells are heterogeneous by definition, so correctness wins.
_homog(es) = !isempty(es) && (all(e -> e isa Number, es) || all(e -> e isa AbstractString, es))
_iscelllit(e) = e isa Expr && e.head === :ref && e.args[1] === :Any && length(e.args) >= 2

function _narrow_cells(stmts)
    mutated = Set{Symbol}()
    collect_mut(e) = begin
        if e isa Expr
            if e.head === :(=) && e.args[1] isa Expr && e.args[1].head === :ref && e.args[1].args[1] isa Symbol
                push!(mutated, e.args[1].args[1])
            end
            foreach(collect_mut, e.args)
        end
    end
    foreach(collect_mut, stmts)

    narrow(e) = e
    narrow(e::Expr) = begin
        if e.head === :(=) && e.args[1] isa Symbol && e.args[1] in mutated && _iscelllit(e.args[2])
            Expr(:(=), e.args[1], Expr(:ref, :Any, map(narrow, e.args[2].args[2:end])...))   # keep cell
        elseif _iscelllit(e) && _homog(@view e.args[2:end])
            Expr(:vect, map(narrow, @view e.args[2:end])...)
        else
            Expr(e.head, map(narrow, e.args)...)
        end
    end
    return map(narrow, stmts)
end

function run_idiomatic(stmts; wrap_script::Bool = true)
    stmts = _comprehensions(stmts)        # recognize preallocated loops -> comprehensions first
    defs = Any[]
    script = Any[]
    for s in stmts
        _isdef(s) ? push!(defs, _process_def(s)) : push!(script, s)
    end
    env = shape_env(script)
    script = map(s -> _rewrite(s, env), script)
    if wrap_script && _has_loop(script)
        script = Any[Expr(:let, Expr(:block), Expr(:block, _scope_fix(script)...))]
    end
    return _narrow_cells(vcat(defs, script))
end
