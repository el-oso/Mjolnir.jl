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

# MATLAB class-name strings -> Julia types, for `isa(x,'type')`.
const _MATLAB_TYPES = Dict{String, Any}(
    "double" => :Float64, "single" => :Float32, "char" => :AbstractString, "string" => :AbstractString,
    "logical" => :Bool, "cell" => :(Vector{Any}), "struct" => :NamedTuple, "numeric" => :Number,
    "function_handle" => :Function,
    "int8" => :Int8, "int16" => :Int16, "int32" => :Int32, "int64" => :Int64,
    "uint8" => :UInt8, "uint16" => :UInt16, "uint32" => :UInt32, "uint64" => :UInt64,
)

# Bare-identifier constants: MATLAB name -> Julia expression.
const IDENT_MAP = Dict{Symbol, Any}(
    :pi => :pi, :Inf => :Inf, :inf => :Inf, :NaN => :NaN, :nan => :NaN,
    Symbol("true") => true, Symbol("false") => false,
    :eps => :(eps()), :i => :im, :j => :im,
)

_bcast(f::Symbol, args) = Expr(:., f, Expr(:tuple, args...))

# Map a MATLAB toolbox function to `Mod.fn(args...)` and record the package as a needed import.
# Qualified (not bare) to avoid clashing with Base names like `step`/`filter`.
_pkg(mod::Symbol, fn::Symbol) =
    (ctx, a) -> (push!(ctx.imports, mod); Expr(:call, Expr(:., mod, QuoteNode(fn)), a...))

# MATLAB interprets backslash escapes inside (s/f)printf format strings; Julia's @printf takes a
# real string literal, so turn `\n`/`\t`/… into the actual characters in the (literal) format arg.
_unescape_printf(s::AbstractString) =
    replace(s, "\\n" => "\n", "\\t" => "\t", "\\r" => "\r", "\\\\" => "\\")
_unescape_printf(x) = x
_printf_args(a) = isempty(a) ? a : Any[_unescape_printf(a[1]), a[2:end]...]

# First non-singleton dimension of x, defaulting to 1 — matches MATLAB's default reduction dim.
_fnsd(x) = Expr(:call, :something, Expr(:call, :findfirst, Expr(:call, :>, 1), Expr(:call, :size, x)), 1)
# `f(x)` for a 1-D vector (no dims allowed), `f(x; dims=first-non-singleton)` for ≥2-D (e.g. 1×N).
_dimsafe(f::Symbol, x) = Expr(
    :if, Expr(:call, :(==), Expr(:call, :ndims, x), 1),
    Expr(:call, f, x), Expr(:call, f, x, Expr(:kw, :dims, _fnsd(x)))
)

"""
    lower_builtin(ctx, name, args) -> Expr

Map a MATLAB function call `name(args...)` (args already lowered) to a Julia expression.
Returns `nothing` if `name` is not a recognized builtin (caller emits a plain call).
"""
# Base/stdlib functions whose MATLAB call maps unchanged — emit the call, no TODO.
const BASE_OK = Set([:isempty, :ndims, :rethrow, :isreal, :circshift])

function lower_builtin(ctx, name::Symbol, args)
    if haskey(ELEMENTWISE, name)
        return _bcast(ELEMENTWISE[name], args)
    end
    h = get(SPECIAL, name, nothing)
    if h !== nothing
        # Handlers assume MATLAB's usual arity; an unusual call shouldn't crash the file.
        try
            return h(ctx, args)
        catch e
            e isa BoundsError || rethrow()
            push!(ctx.todos, "builtin `$name` called with unexpected arity; emitted a plain call")
            return Expr(:call, name, args...)
        end
    end
    name in BASE_OK && return Expr(:call, name, args...)
    return nothing
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
    :strsplit => (ctx, a) -> Expr(:call, :split, a...),
    :strjoin => (ctx, a) -> Expr(:call, :join, a...),
    :deblank => (ctx, a) -> Expr(:call, :rstrip, a...),
    :fileread => (ctx, a) -> Expr(:call, :read, a[1], :String),
    :regexprep => (ctx, a) -> Expr(:call, :replace, a[1], Expr(:call, :(=>), Expr(:call, :Regex, a[2]), a[3])),
    :char => (ctx, a) -> Expr(:., :Char, Expr(:tuple, a...)),       # best-effort (char is overloaded)
    :class => (ctx, a) -> Expr(:call, :string, Expr(:call, :typeof, a[1])),
    :isequaln => (ctx, a) -> Expr(:call, :isequal, a...),
    :typecast => (ctx, a) -> Expr(:call, :reinterpret, get(_MATLAB_TYPES, a[2] isa AbstractString ? a[2] : "", :UInt8), a[1]),
    # --- type predicates (approximate; MATLAB's type system != Julia's) ---
    :ischar => (ctx, a) -> Expr(:call, :isa, a[1], :AbstractString),
    :isnumeric => (ctx, a) -> Expr(:call, :<:, Expr(:call, :eltype, a[1]), :Number),
    :islogical => (ctx, a) -> Expr(:call, :<:, Expr(:call, :eltype, a[1]), :Bool),
    :isstruct => (ctx, a) -> Expr(:call, :isa, a[1], :NamedTuple),
    :iscell => (ctx, a) -> Expr(:call, :isa, a[1], :(Vector{Any})),
    :isa => (ctx, a) -> begin
        ty = (length(a) >= 2 && a[2] isa AbstractString) ? get(_MATLAB_TYPES, a[2], nothing) : nothing
        ty === nothing ? Expr(:call, :isa, a...) : Expr(:call, :isa, a[1], ty)
    end,
    # --- functional iteration ---
    :cellfun => (ctx, a) -> begin                         # drop trailing 'UniformOutput',false etc.
        stop = findfirst(x -> x isa AbstractString, a)
        Expr(:call, :map, (stop === nothing ? a : a[1:(stop - 1)])...)
    end,
    :arrayfun => (ctx, a) -> begin
        stop = findfirst(x -> x isa AbstractString, a)
        Expr(:call, :map, (stop === nothing ? a : a[1:(stop - 1)])...)
    end,
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
    # MATLAB diag(v) builds a diagonal matrix; diag(M) extracts the diagonal. Dispatch by ndims.
    :diag => (ctx, a) -> begin
        push!(ctx.imports, :LinearAlgebra)
        length(a) == 1 ?
            Expr(
                :if, Expr(:call, :(==), Expr(:call, :ndims, a[1]), 1),
                Expr(:call, :diagm, a[1]), Expr(:call, :diag, a[1])
            ) :
            Expr(:call, :diagm, a...)
    end,
    :eig => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :eigvals, a...)),  # [V,D]=eig needs eigen
    :transpose => (ctx, a) -> Expr(:call, :transpose, a...),
    :kron => (ctx, a) -> (push!(ctx.imports, :LinearAlgebra); Expr(:call, :kron, a...)),
    # --- FFT (FFTW; names match MATLAB) ---
    :fft => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :fft, a...)),
    :ifft => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :ifft, a...)),
    :fftshift => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :fftshift, a...)),
    :ifftshift => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :ifftshift, a...)),
    # --- DSP toolbox -> DSP.jl ---
    :conv => _pkg(:DSP, :conv), :conv2 => _pkg(:DSP, :conv),
    :filter => _pkg(:DSP, :filt), :freqz => _pkg(:DSP, :freqz), :xcorr => _pkg(:DSP, :xcorr),
    # butter(n, Wn) -> lowpass Butterworth filter object. NOTE: band/high types and the [b,a]
    # coefficient output form need manual adjustment (DSP returns a filter, not [b,a]).
    :butter => (ctx, a) -> begin
        push!(ctx.imports, :DSP)
        n = a[1]
        wn = length(a) >= 2 ? a[2] : a[1]
        Expr(
            :call, Expr(:., :DSP, QuoteNode(:digitalfilter)),
            Expr(:call, Expr(:., :DSP, QuoteNode(:Lowpass)), wn),
            Expr(:call, Expr(:., :DSP, QuoteNode(:Butterworth)), n)
        )
    end,
    # --- interpolation -> Interpolations.jl ---
    :interp1 => (ctx, a) -> begin
        push!(ctx.imports, :Interpolations)
        meth = (length(a) >= 4 && a[4] isa AbstractString && a[4] in ("spline", "cubic", "pchip")) ?
            :cubic_spline_interpolation : :linear_interpolation
        Expr(:., Expr(:call, Expr(:., :Interpolations, QuoteNode(meth)), a[1], a[2]), Expr(:tuple, a[3]))
    end,
    :interp2 => (ctx, a) -> begin
        push!(ctx.imports, :Interpolations)   # interp2(X,Y,Z,xq,yq); X,Y must be coordinate vectors
        Expr(
            :., Expr(
                :call, Expr(:., :Interpolations, QuoteNode(:linear_interpolation)),
                Expr(:tuple, a[1], a[2]), a[3]
            ), Expr(:tuple, a[4], a[5])
        )
    end,
    :fft2 => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :fft, a...)),
    :ifft2 => (ctx, a) -> (push!(ctx.imports, :FFTW); Expr(:call, :ifft, a...)),
    # --- functional comparisons & type conversions ---
    :ge => (ctx, a) -> Expr(:call, :.>=, a...), :le => (ctx, a) -> Expr(:call, :.<=, a...),
    :gt => (ctx, a) -> Expr(:call, :.>, a...), :lt => (ctx, a) -> Expr(:call, :.<, a...),
    :eq => (ctx, a) -> Expr(:call, :.==, a...), :ne => (ctx, a) -> Expr(:call, :.!=, a...),
    :double => (ctx, a) -> Expr(:., :Float64, Expr(:tuple, a...)),
    :single => (ctx, a) -> Expr(:., :Float32, Expr(:tuple, a...)),
    :logical => (ctx, a) -> Expr(:., :Bool, Expr(:tuple, a...)),
    # uint8 saturates to [0,255] and rounds
    :uint8 => (ctx, a) -> Expr(:., :round, Expr(:tuple, :UInt8, Expr(:., :clamp, Expr(:tuple, a[1], 0, 255)))),
    :uint16 => (ctx, a) -> Expr(:., :round, Expr(:tuple, :UInt16, Expr(:., :clamp, Expr(:tuple, a[1], 0, 65535)))),
    :atan2 => (ctx, a) -> _bcast(:atan, a),
    :rot90 => (ctx, a) -> Expr(:call, :rotl90, a...),
    :hex2dec => (ctx, a) -> Expr(:call, :parse, :Int, a[1], Expr(:kw, :base, 16)),
    :diff => (ctx, a) -> length(a) == 1 ? _dimsafe(:diff, a[1]) : Expr(:call, :diff, a...),
    :isprime => _pkg(:Primes, :isprime),
    :meshgrid => (ctx, a) -> begin
        x = a[1]
        y = length(a) >= 2 ? a[2] : a[1]
        co = Expr(:call, :Colon)
        X = Expr(:call, :repeat, Expr(:call, :reshape, x, 1, co), Expr(:call, :length, y), 1)
        Y = Expr(:call, :repeat, Expr(:call, :reshape, y, co, 1), 1, Expr(:call, :length, x))
        Expr(:tuple, X, Y)
    end,
    # --- image processing -> Images.jl ecosystem ---
    :imread => _pkg(:Images, :load),
    :imwrite => (ctx, a) -> (push!(ctx.imports, :Images); Expr(:call, Expr(:., :Images, QuoteNode(:save)), a[2], a[1])),
    :rgb2gray => (ctx, a) -> (push!(ctx.imports, :Images); Expr(:., Expr(:., :Images, QuoteNode(:Gray)), Expr(:tuple, a...))),
    :im2double => (ctx, a) -> Expr(:., :Float64, Expr(:tuple, a...)),
    :imresize => _pkg(:Images, :imresize),
    :imrotate => _pkg(:ImageTransformations, :imrotate),
    :imfilter => _pkg(:ImageFiltering, :imfilter),
    :imagesc => _pkg(:Plots, :heatmap),
    # --- sparse arrays -> SparseArrays (stdlib) ---
    :sparse => _pkg(:SparseArrays, :sparse),
    :nonzeros => _pkg(:SparseArrays, :nonzeros),
    :full => (ctx, a) -> Expr(:call, :Matrix, a...),
    :nnz => (ctx, a) -> Expr(:call, :count, Expr(:call, :!, :iszero), a[1]),   # works dense & sparse
    :spy => _pkg(:Plots, :spy),
    :speye => (ctx, a) -> begin
        push!(ctx.imports, :SparseArrays)
        push!(ctx.imports, :LinearAlgebra)
        n = length(a) == 1 ? (a[1], a[1]) : (a[1], a[2])
        Expr(:call, Expr(:., :SparseArrays, QuoteNode(:sparse)), :(LinearAlgebra.I), n...)
    end,
    :uint32 => (ctx, a) -> Expr(:., :round, Expr(:tuple, :UInt32, a[1])),
    :int32 => (ctx, a) -> Expr(:., :round, Expr(:tuple, :Int32, a[1])),
    # GPU transfers are no-ops on the CPU target (results identical, just not offloaded)
    :gpuArray => (ctx, a) -> a[1],
    :gather => (ctx, a) -> a[1],
    # --- Bioinformatics toolbox -> BioJulia (BioSequences.jl). Inputs are BioSequences, so a
    # char-string arg needs wrapping (e.g. LongDNA{4}(s)) -> partial. ---
    :seqcomplement => _pkg(:BioSequences, :complement),
    :seqrcomplement => _pkg(:BioSequences, :reverse_complement),
    :nt2aa => _pkg(:BioSequences, :translate),
    :randseq => _pkg(:BioSequences, :randdnaseq),
    # --- Control System toolbox -> ControlSystems.jl (APIs differ in places -> partial) ---
    :tf => _pkg(:ControlSystems, :tf), :ss => _pkg(:ControlSystems, :ss),
    :step => _pkg(:ControlSystems, :step), :impulse => _pkg(:ControlSystems, :impulse),
    :bode => _pkg(:ControlSystems, :bode), :nyquist => _pkg(:ControlSystems, :nyquist),
    :lsim => _pkg(:ControlSystems, :lsim), :c2d => _pkg(:ControlSystems, :c2d),
    :feedback => _pkg(:ControlSystems, :feedback), :pole => _pkg(:ControlSystems, :poles),
    :dcgain => _pkg(:ControlSystems, :dcgain),
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
    # sort/cumsum/cumprod need a dims for ≥2-D; MATLAB acts along the first non-singleton dim.
    # `_fnsd(x)` = something(findfirst(>(1), size(x)), 1) reproduces that for vectors & 1×N rows.
    :sort => (ctx, a) -> length(a) == 1 ? _dimsafe(:sort, a[1]) : Expr(:call, :sort, a...),
    :unique => (ctx, a) -> Expr(:call, :sort, Expr(:call, :unique, a[1])),  # MATLAB unique is sorted
    :cumsum => (ctx, a) -> length(a) == 1 ? _dimsafe(:cumsum, a[1]) : Expr(:call, :cumsum, a...),
    :cumprod => (ctx, a) -> length(a) == 1 ? _dimsafe(:cumprod, a[1]) : Expr(:call, :cumprod, a...),
    # MATLAB any/all treat nonzero as true; Julia needs a Bool array -> use `x .!= 0`.
    :any => (ctx, a) -> length(a) == 1 ? Expr(:call, :any, Expr(:call, :.!=, a[1], 0)) :
        Expr(:call, :any, Expr(:call, :.!=, a[1], 0), Expr(:kw, :dims, a[2])),
    :all => (ctx, a) -> length(a) == 1 ? Expr(:call, :all, Expr(:call, :.!=, a[1], 0)) :
        Expr(:call, :all, Expr(:call, :.!=, a[1], 0), Expr(:kw, :dims, a[2])),
    # --- plotting (Plots.jl; best-effort — MATLAB's stateful figure/subplot/hold model differs) ---
    :plot => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :plot, a...)),
    :plot3 => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :plot, a...)),
    :stem => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :plot, a..., Expr(:kw, :seriestype, QuoteNode(:sticks)))),
    :bar => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :bar, a...)),
    :scatter => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :scatter, a...)),
    :hist => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :histogram, a...)),
    :histogram => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :histogram, a...)),
    :xlabel => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, Symbol("xlabel!"), a...)),
    :ylabel => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, Symbol("ylabel!"), a...)),
    :zlabel => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, Symbol("zlabel!"), a...)),
    :title => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, Symbol("title!"), a...)),
    :xlim => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, Symbol("xlims!"), a...)),
    :ylim => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, Symbol("ylims!"), a...)),
    :legend => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, Symbol("plot!"), Expr(:kw, :legend, true))),
    :contour => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :contour, a...)),
    :surf => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :surface, a...)),
    :mesh => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, :surface, a...)),
    :sgtitle => (ctx, a) -> (push!(ctx.imports, :Plots); Expr(:call, Symbol("title!"), a...)),
    # --- optimization (Optim.jl for unconstrained; JuMP/Convex for constrained — see docs) ---
    :fminsearch => (ctx, a) -> (
        push!(ctx.imports, :Optim);
        Expr(:call, Expr(:., :Optim, QuoteNode(:minimizer)), Expr(:call, Expr(:., :Optim, QuoteNode(:optimize)), a...))
    ),
    :fminunc => (ctx, a) -> (
        push!(ctx.imports, :Optim);
        Expr(:call, Expr(:., :Optim, QuoteNode(:minimizer)), Expr(:call, Expr(:., :Optim, QuoteNode(:optimize)), a...))
    ),
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
