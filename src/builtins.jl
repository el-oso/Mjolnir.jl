# Builtin-function registry: MATLAB call -> Julia expression.
#
# Stage-3 (Lower) helper. Two layers:
#   * ELEMENTWISE  — MATLAB scalar functions that act element-wise on arrays. Emitted as a
#                    Julia broadcast (`f.(args)`), which matches MATLAB for both scalars and
#                    arrays (and is idiomatic Julia).
#   * SPECIAL      — functions needing a shape/name/semantics rewrite (handlers below).
# Anything unmapped passes through as `name(args...)` with a recorded TODO.

# MATLAB elementwise math -> same-named Julia function, broadcast.
const ELEMENTWISE = Dict{Symbol, Symbol}(
    :sqrt => :sqrt, :abs => :abs, :exp => :exp, :log => :log, :log2 => :log2,
    :log10 => :log10, :sin => :sin, :cos => :cos, :tan => :tan, :asin => :asin,
    :acos => :acos, :atan => :atan, :sinh => :sinh, :cosh => :cosh, :tanh => :tanh,
    :sign => :sign, :floor => :floor, :ceil => :ceil, :round => :round, :real => :real,
    :imag => :imag, :conj => :conj, :angle => :angle, :mod => :mod, :rem => :rem,
    :fix => :trunc, :power => :^,
    :isnan => :isnan, :isinf => :isinf, :isfinite => :isfinite,
    :gcd => :gcd, :lcm => :lcm, :factorial => :factorial,
)

# Bare-identifier constants: MATLAB name -> Julia expression.
const IDENT_MAP = Dict{Symbol, Any}(
    :pi => :pi, :Inf => :Inf, :inf => :Inf, :NaN => :NaN, :nan => :NaN,
    Symbol("true") => true, Symbol("false") => false,
    :eps => :(eps()), :i => :im, :j => :im,
)

_bcast(f::Symbol, args) = Expr(:., f, Expr(:tuple, args...))

# MATLAB interprets backslash escapes inside (s/f)printf format strings; Julia's @printf takes a
# real string literal, so turn `\n`/`\t`/… into the actual characters in the (literal) format arg.
_unescape_printf(s::AbstractString) =
    replace(s, "\\n" => "\n", "\\t" => "\t", "\\r" => "\r", "\\\\" => "\\")
_unescape_printf(x) = x
_printf_args(a) = isempty(a) ? a : Any[_unescape_printf(a[1]), a[2:end]...]

"""
    lower_builtin(ctx, name, args) -> Expr

Map a MATLAB function call `name(args...)` (args already lowered) to a Julia expression.
Returns `nothing` if `name` is not a recognized builtin (caller emits a plain call).
"""
function lower_builtin(ctx, name::Symbol, args)
    if haskey(ELEMENTWISE, name)
        return _bcast(ELEMENTWISE[name], args)
    end
    h = get(SPECIAL, name, nothing)
    h === nothing && return nothing
    return h(ctx, args)
end

# `n` args -> square `(n, n)` for the 1-arg matrix constructors (MATLAB `zeros(n)` is n×n).
function _square_ctor(jl::Symbol)
    return (ctx, args) -> begin
        if length(args) == 1
            return Expr(:call, jl, args[1], args[1])
        else
            return Expr(:call, jl, args...)
        end
    end
end

const SPECIAL = Dict{Symbol, Function}(
    :zeros => _square_ctor(:zeros),
    :ones => _square_ctor(:ones),
    :rand => _square_ctor(:rand),
    :randn => _square_ctor(:randn),
    # MATLAB length(x) = longest dimension (Julia `length` is the element count = MATLAB numel)
    :length => (ctx, a) -> Expr(:call, :maximum, Expr(:call, :size, a...)),
    :numel => (ctx, a) -> Expr(:call, :length, a...),
    :size => (ctx, a) -> Expr(:call, :size, a...),       # works as-is (tuple vs vector; indexing ok)
    :error => (ctx, a) -> Expr(:call, :error, a...),     # Julia has error()
    :cell => (ctx, a) -> begin                           # cell(n)->n×n, cell(m,n)->m×n
        dims = length(a) == 1 ? (a[1], a[1]) : Tuple(a)
        Expr(:call, Expr(:curly, :Array, :Any), :undef, dims...)
    end,
    :tril => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :tril, a...)),
    :triu => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :triu, a...)),
    :repmat => (ctx, a) -> Expr(:call, :repeat, a...),
    :disp => (ctx, a) -> Expr(:call, :println, a...),
    :find => (ctx, a) -> Expr(:call, :findall, Expr(:call, :!, :iszero), a...),
    :sum => (ctx, a) -> length(a) == 1 ? Expr(:call, :sum, a[1]) :
        Expr(:call, :sum, a[1], Expr(:kw, :dims, a[2])),
    :prod => (ctx, a) -> length(a) == 1 ? Expr(:call, :prod, a[1]) :
        Expr(:call, :prod, a[1], Expr(:kw, :dims, a[2])),
    :max => (ctx, a) -> length(a) == 1 ? Expr(:call, :maximum, a[1]) : _bcast(:max, a),
    :min => (ctx, a) -> length(a) == 1 ? Expr(:call, :minimum, a[1]) : _bcast(:min, a),
    # --- strings & conversions ---
    :upper => (ctx, a) -> Expr(:call, :uppercase, a...),
    :lower => (ctx, a) -> Expr(:call, :lowercase, a...),
    :strtrim => (ctx, a) -> Expr(:call, :strip, a...),
    :strcmp => (ctx, a) -> Expr(:call, :(==), a...),
    :strcmpi => (ctx, a) ->
    Expr(:call, :(==), Expr(:call, :lowercase, a[1]), Expr(:call, :lowercase, a[2])),
    :strrep => (ctx, a) -> Expr(:call, :replace, a[1], Expr(:call, :(=>), a[2], a[3])),
    :strcat => (ctx, a) -> Expr(:call, :string, a...),
    :num2str => (ctx, a) -> Expr(:call, :string, a[1]),
    :str2double => (ctx, a) -> Expr(:call, :parse, :Float64, a[1]),
    :str2num => (ctx, a) -> Expr(:call, :parse, :Float64, a[1]),
    :contains => (ctx, a) -> Expr(:call, :occursin, a[2], a[1]),   # (str,pat) -> occursin(pat,str)
    :startsWith => (ctx, a) -> Expr(:call, :startswith, a...),
    :endsWith => (ctx, a) -> Expr(:call, :endswith, a...),
    :sprintf => (ctx, a) -> begin
        push!(ctx.imports, :Printf)
        Expr(:macrocall, Expr(:., :Printf, QuoteNode(Symbol("@sprintf"))), nothing, _printf_args(a)...)
    end,
    :fprintf => (ctx, a) -> begin
        push!(ctx.imports, :Printf)
        Expr(:macrocall, Expr(:., :Printf, QuoteNode(Symbol("@printf"))), nothing, _printf_args(a)...)
    end,
    # --- struct introspection (NamedTuples) ---
    :fieldnames => (ctx, a) -> Expr(:call, :collect, Expr(:., :string, Expr(:tuple, Expr(:call, :keys, a[1])))),
    :isfield => (ctx, a) -> Expr(:call, :haskey, a[1], Expr(:call, :Symbol, a[2])),
    # rmfield(s,'a') -> structdiff with a 1-field NamedTuple; works for literal & dynamic names.
    :rmfield => (ctx, a) -> Expr(
        :call, Expr(:., :Base, QuoteNode(:structdiff)), a[1],
        Expr(
            :call, Expr(:curly, :NamedTuple, Expr(:tuple, Expr(:call, :Symbol, a[2]))),
            Expr(:tuple, :nothing)
        )
    ),
    :warning => (ctx, a) -> Expr(:macrocall, Symbol("@warn"), nothing, a...),
    # --- containers.Map methods ---
    :keys => (ctx, a) -> Expr(:call, :collect, Expr(:call, :keys, a...)),
    :values => (ctx, a) -> Expr(:call, :collect, Expr(:call, :values, a...)),
    :isKey => (ctx, a) -> Expr(:call, :haskey, a...),
    :remove => (ctx, a) -> Expr(:call, :delete!, a...),
    :eye => (ctx, a) -> begin
        push!(ctx.imports, :LinearAlgebra)
        n = length(a) == 1 ? (a[1], a[1]) : (a[1], a[2])
        Expr(:call, Expr(:curly, :Matrix, :Float64), :(LinearAlgebra.I), n...)
    end,
    :inv => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :inv, a...)),
    # --- linear algebra (LinearAlgebra) ---
    :norm => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :norm, a...)),
    :dot => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :dot, a...)),
    :cross => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :cross, a...)),
    :trace => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :tr, a...)),  # renamed
    :det => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :det, a...)),
    :diag => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :diag, a...)),
    :transpose => (ctx, a) -> Expr(:call, :transpose, a...),
    :kron => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :kron, a...)),
    # --- FFT (FFTW; names match MATLAB) ---
    :fft => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :fft, a...)),
    :ifft => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :ifft, a...)),
    :fftshift => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :fftshift, a...)),
    :ifftshift => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :ifftshift, a...)),
    :nchoosek => (ctx, a) -> Expr(:call, :binomial, a...),
    # MATLAB set ops return sorted unique results; Julia's don't sort -> wrap in sort.
    :intersect => (ctx, a) -> Expr(:call, :sort, Expr(:call, :intersect, a...)),
    :union => (ctx, a) -> Expr(:call, :sort, Expr(:call, :union, a...)),
    :setdiff => (ctx, a) -> Expr(:call, :sort, Expr(:call, :setdiff, a...)),
    :ismember => (ctx, a) -> Expr(:., :in, Expr(:tuple, a[1], Expr(:call, :Ref, a[2]))),  # in.(a, Ref(b))
    # --- array reshaping / ordering ---
    :reshape => (ctx, a) -> begin
        dims = map(a[2:end]) do x
            (x isa Expr && x.head === :vect && isempty(x.args)) ? Expr(:call, :Colon) : x
        end
        Expr(:call, :reshape, a[1], dims...)
    end,
    :fliplr => (ctx, a) -> Expr(:call, :reverse, a[1], Expr(:kw, :dims, 2)),
    :flipud => (ctx, a) -> Expr(:call, :reverse, a[1], Expr(:kw, :dims, 1)),
    :flip => (ctx, a) -> Expr(:call, :reverse, a...),
    :sort => (ctx, a) -> Expr(:call, :sort, a...),
    :unique => (ctx, a) -> Expr(:call, :sort, Expr(:call, :unique, a[1])),  # MATLAB unique is sorted
    :cumsum => (ctx, a) -> Expr(:call, :cumsum, a...),
    :cumprod => (ctx, a) -> Expr(:call, :cumprod, a...),
    # MATLAB any/all treat nonzero as true; Julia needs a Bool array -> use `x .!= 0`.
    :any => (ctx, a) -> length(a) == 1 ? Expr(:call, :any, Expr(:call, :.!=, a[1], 0)) :
        Expr(:call, :any, Expr(:call, :.!=, a[1], 0), Expr(:kw, :dims, a[2])),
    :all => (ctx, a) -> length(a) == 1 ? Expr(:call, :all, Expr(:call, :.!=, a[1], 0)) :
        Expr(:call, :all, Expr(:call, :.!=, a[1], 0), Expr(:kw, :dims, a[2])),
    # --- statistics (Statistics stdlib) ---
    :mean => (ctx, a) -> (push!(ctx.imports, :Statistics); Expr(:call, :mean, a...)),
    :median => (ctx, a) -> (push!(ctx.imports, :Statistics); Expr(:call, :median, a...)),
    :std => (ctx, a) -> (push!(ctx.imports, :Statistics); Expr(:call, :std, a...)),
    :var => (ctx, a) -> (push!(ctx.imports, :Statistics); Expr(:call, :var, a...)),
    # struct('a', v1, 'b', v2) -> NamedTuple (a = v1, b = v2)  (preferred over Dict)
    :struct => (ctx, a) -> begin
        pairs = Any[]
        i = 1
        while i + 1 <= length(a)
            key = a[i] isa AbstractString ? Symbol(a[i]) : Symbol(string(a[i]))
            push!(pairs, Expr(:(=), key, a[i + 1]))
            i += 2
        end
        Expr(:tuple, pairs...)
    end,
    :linspace => (ctx, a) -> begin
        n = length(a) >= 3 ? a[3] : 100
        Expr(:call, :range, a[1], a[2], Expr(:kw, :length, n))
    end,
)
