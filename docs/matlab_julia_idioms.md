<!-- GENERATED from src/idioms.jl by Mjolnir.write_idioms — do not edit by hand. -->
# MATLAB → Julia idiom mapping

Normative MATLAB→Julia mappings. `✅` implemented · `🟡` partial/divergence · `⬜` planned.
Canonical source: `src/idioms.jl`. Machine-readable mirror: `docs/idioms.json`.

## Literals & types

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `42 / 2.5 / 1e3` | `42 / 2.5 / 1e3` | integer literals stay Int |
| ✅ | `[1 2 3] (row)` | `[1 2 3] (1×N Matrix)` | MATLAB-faithful: size(x,2), transpose, x*y, and [A b] concatenation all work |
| ✅ | `[1;2;3] (column)` | `[1, 2, 3] (Vector)` |  |
| ✅ | `[1 2; 3 4]` | `[1 2; 3 4] (Matrix)` |  |
| ✅ | `[A b] / [A; b]` | `hcat / vcat (concatenation)` |  |
| ✅ | `0x1F` | `0x1f -> Int` |  |
| ✅ | `3i` | `3.0im` |  |
| 🟡 | `'text' (char array)` | `"text"` | char-array semantics approximated by String |
| ✅ | `"text"` | `"text"` |  |
| ✅ | `true / false` | `true / false` |  |
| ✅ | `pi / Inf / NaN / eps / i,j` | `pi / Inf / NaN / eps() / im` | only when not shadowed by a variable |
| ✅ | `... (line continuation)` | `(transparent)` | ignored, as in MATLAB |

## Operators

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `+  -` | `.+  .-` | MATLAB implicit expansion; de-broadcast to +/- when both operands are scalar |
| ✅ | `*  /  \  ^` | `*  /  \  ^` | matrix operators |
| ✅ | `.*  ./  .^  .\` | `.*  ./  .^  .\` |  |
| ✅ | `== ~= < > <= >=` | `.== .!= .< .> .<= .>=` | broadcast; de-broadcast when scalar |
| ✅ | `&  |` | `.&  .|` |  |
| ✅ | `&&  ||` | `&&  ||` |  |
| ✅ | `~x` | `.!x` |  |
| ✅ | `x'` | `x'` | adjoint |
| ✅ | `x.'` | `transpose(x)` |  |
| ✅ | `a:b / a:s:b` | `a:b / a:s:b` |  |

## Indexing

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `x(i), x(i,j)` | `x[i], x[i,j]` | only when x is a known variable (scope pre-pass) |
| ✅ | `f(a,b) (f not a variable)` | `f(a, b)` | resolved as a call |
| ✅ | `x(end), x(2:end)` | `x[end], x[2:end]` |  |
| ✅ | `x(:), A(2,:)` | `x[:], A[2, :]` |  |
| ✅ | `x(i) = v` | `x[i] = v` |  |
| ✅ | `s.field` | `s.field` |  |

## Shapes & reductions

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `numel(x)` | `length(x)` |  |
| ✅ | `length(x)` | `maximum(size(x))` | MATLAB length = longest dim; errors on a scalar |
| ✅ | `size(x,d)` | `size(x, d)` |  |
| ✅ | `sum(A)/prod(A) on a matrix` | `sum(A, dims=1)/prod(A, dims=1)` | first-dim reduction when A is provably a matrix; vectors stay scalar |
| ✅ | `max(A)/min(A) on a matrix` | `maximum(A, dims=1)/minimum(A, dims=1)` |  |
| ✅ | `max(a,b)/min(a,b)` | `max.(a, b)/min.(a, b)` |  |

## Constructors & builtins

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `zeros(n)/ones(n)/rand(n)` | `zeros(n,n)/...` | MATLAB zeros(n) is n×n |
| ✅ | `eye(n)` | `Matrix{Float64}(LinearAlgebra.I, n, n)` |  |
| ✅ | `inv(A)` | `inv(A)` |  |
| ✅ | `linspace(a,b,n)` | `range(a, b, length=n)` |  |
| ✅ | `repmat(A,m,n)` | `repeat(A, m, n)` |  |
| ✅ | `find(x)` | `findall(!iszero, x)` |  |
| 🟡 | `disp(x)` | `println(x)` |  |
| ✅ | `sqrt/abs/exp/log/sin/.../mod/rem/fix` | `f.(args) (broadcast)` | element-wise math; de-broadcast when scalar |
| ✅ | `isnan/isinf/isfinite` | `isnan.(x)/isinf.(x)/isfinite.(x)` |  |
| ✅ | `fieldnames(s)` | `collect(string.(keys(s)))` |  |
| ✅ | `isfield(s,'a')` | `haskey(s, Symbol("a"))` |  |
| 🟡 | `rmfield(s,'a')` | `Base.structdiff(s, (a = nothing,))` | literal field name only |
| ✅ | `warning(msg)` | `@warn msg` |  |
| ✅ | `s.(f) (dynamic field)` | `getproperty(s, Symbol(f)) / merge(...)` | read + write |
| 🟡 | `s(i).field (struct array)` | `s[i] = merge(s[i], (field=v,)) / s[i].field` | read works; build-from-scratch needs a preallocated Vector |
| ✅ | `ge/le/gt/lt/eq/ne` | `.>= / .<= / .> / .< / .== / .!=` | functional comparison forms |
| ✅ | `double/single/logical` | `Float64. / Float32. / Bool.` |  |
| ✅ | `uint8/uint16` | `round.(UInt8, clamp.(x,0,255)) / ...` | saturating cast |
| ✅ | `atan2/rot90/hex2dec/diff` | `atan / rotl90 / parse(Int,_,base=16) / diff` |  |
| ✅ | `[X,Y]=meshgrid(x,y)` | `repeat(reshape(...)) tuple` |  |
| ✅ | `fft2/ifft2` | `fft/ifft (FFTW)` |  |
| 🟡 | `imread/imwrite/rgb2gray/im2double/imresize/imrotate/imfilter/imagesc` | `Images.jl ecosystem (Images/ImageFiltering/ImageTransformations/Plots)` | imwrite arg order swapped; imshow best-effort |
| ✅ | `anything unmapped` | `name(args...) + todos entry` |  |
| ✅ | `size(x)` | `size(x)` | tuple vs vector; indexing compatible |
| ✅ | `error(msg)` | `error(msg)` |  |
| ✅ | `cell(n)` | `Array{Any}(undef, n, n)` |  |
| 🟡 | `plot/stem/bar/scatter/xlabel/...` | `Plots.plot/sticks/bar/.../xlabel!/...` | Plots.jl; stateful subplot/figure/hold/legend semantics are best-effort (subplot/figure still pass through) |
| 🟡 | `fminsearch/fminunc` | `Optim.minimizer(Optim.optimize(f, x0))` | Optim.jl (unconstrained); use JuMP/Convex/MathOptInterface for constrained (linprog/quadprog) — TODO |
| ✅ | `conv/conv2/filter/freqz/xcorr (DSP toolbox)` | `DSP.conv/DSP.filt/...` | DSP.jl |
| 🟡 | `butter(n,Wn)` | `DSP.digitalfilter(Lowpass(Wn), Butterworth(n))` | returns a filter object, not [b,a]; band/high types need manual work; fir1 still TODO |
| 🟡 | `interp1/interp2` | `Interpolations.linear_interpolation(...).(xq)` | linear default, 'spline'/'cubic'->cubic_spline; interp2 grids must be coordinate vectors |
| 🟡 | `tf/ss/step/bode/lsim/c2d/feedback/pole (Control toolbox)` | `ControlSystems.tf/ss/...` | ControlSystems.jl; pole->poles; step/bode return objects, not [y,t] |
| 🟡 | `seqcomplement/seqrcomplement/nt2aa/randseq (Bioinformatics toolbox)` | `BioSequences.complement/reverse_complement/translate/randdnaseq` | BioJulia; inputs must be BioSequences (wrap char strings, e.g. LongDNA{4}(s)) |
| ✅ | `sparse/speye/full/nnz/nonzeros` | `SparseArrays.sparse / sparse(I,n,n) / Matrix / count(!iszero,x) / nonzeros` | SparseArrays stdlib; spdiags/accumarray/sub2ind still TODO |
| ✅ | `gpuArray/gather` | `identity (CPU target — GPU transfer is a no-op)` | results identical, just not offloaded |
| ⬜ | `syms / symbolic math` | `—` | Symbolic Toolbox; would need Symbolics.jl |

## Linear algebra & arrays

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `norm/dot/cross/det/diag` | `norm/dot/cross/det/diag` | LinearAlgebra |
| ✅ | `trace(A)` | `tr(A)` | LinearAlgebra; renamed |
| ✅ | `transpose(x)` | `transpose(x)` |  |
| ✅ | `reshape(A,m,n)` | `reshape(A, m, n)` | column-major in both; `[]` dim -> `:` |
| ✅ | `fliplr/flipud/flip` | `reverse(…, dims=2/1)/reverse` |  |
| ✅ | `sort(x)/cumsum/cumprod` | `ndims-dispatched (dims=first non-singleton for ≥2-D)` | works for vectors and 1×N rows |
| ✅ | `unique(x)` | `sort(unique(x))` | MATLAB unique is sorted |
| 🟡 | `cumsum/cumprod` | `cumsum/cumprod` | vectors; matrix needs dims |
| 🟡 | `any(x)/all(x)` | `any(x)/all(x)` | vectors; matrix reduces per-column in MATLAB |
| 🟡 | `mean/median/std/var` | `mean/median/std/var` | Statistics; matrix reduces per-column in MATLAB |
| ✅ | `gcd/lcm/factorial` | `gcd.(…)/lcm.(…)/factorial.(…)` |  |
| ✅ | `nchoosek(n,k)` | `binomial(n, k)` |  |
| ✅ | `kron(A,B)` | `kron(A, B)` | LinearAlgebra |
| ✅ | `intersect/union/setdiff` | `sort(intersect/union/setdiff(…))` | MATLAB set ops are sorted |
| ✅ | `ismember(a,b)` | `in.(a, Ref(b))` |  |
| ✅ | `tril/triu` | `tril/triu` | LinearAlgebra |
| ✅ | `fft/ifft/fftshift/ifftshift` | `fft/ifft/fftshift/ifftshift` | FFTW; names match |
| 🟡 | `eig(A)` | `eigvals(A)` | LinearAlgebra; [V,D]=eig needs eigen() |

## Strings, conversions & maps

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `strcmp(a,b)` | `a == b` |  |
| ✅ | `strcmpi(a,b)` | `lowercase(a) == lowercase(b)` |  |
| ✅ | `upper/lower/strtrim` | `uppercase/lowercase/strip` |  |
| ✅ | `strrep(s,a,b)` | `replace(s, a => b)` |  |
| 🟡 | `strcat(a,b,…)` | `string(a, b, …)` | MATLAB trims trailing whitespace of char args |
| 🟡 | `num2str(x)` | `string(x)` | formatting/precision differs |
| ✅ | `str2double/str2num` | `parse(Float64, x)` |  |
| ✅ | `contains(s,p)` | `occursin(p, s)` | arg order swapped; Octave lacks contains -> not oracle-tested |
| ✅ | `startsWith/endsWith` | `startswith/endswith` |  |
| 🟡 | `sprintf/fprintf` | `Printf.@sprintf / Printf.@printf` | escape/format edge cases not fully modeled |
| ✅ | `containers.Map(kc,vc)` | `Dict(zip(kc, vc))` | Map()->Dict(); Map(k,v)->Dict(k=>v); type-param form->Dict()+TODO |
| ✅ | `m(k) / m(k)=v (Map)` | `m[k] / m[k]=v` |  |
| 🟡 | `keys(m)/values(m)` | `collect(keys(m))/collect(values(m))` | MATLAB order (sorted) vs Julia (unordered) |
| ✅ | `isKey(m,k)/remove(m,k)` | `haskey(m,k)/delete!(m,k)` |  |
| ✅ | `obj.method(args)` | `method(obj, args...)` | method-call syntax |
| ✅ | `strsplit/strjoin/deblank/fileread` | `split / join / rstrip / read(_,String)` |  |
| ✅ | `regexprep(s,pat,rep)` | `replace(s, Regex(pat) => rep)` | regexp itself still TODO (option-dependent API) |
| ✅ | `char/class/isequaln/typecast` | `Char. / string(typeof(x)) / isequal / reinterpret` |  |
| ✅ | `cellfun/arrayfun(f, …)` | `map(f, …)` | drops trailing 'UniformOutput',false |
| 🟡 | `isa(x,'type') / ischar/isnumeric/isstruct/iscell/islogical` | `x isa T / eltype-based` | approximate (MATLAB type system != Julia) |
| ✅ | `cell content-index c{i} / c{:} / [c{:}] / f(c{:})` | `c[i] / splat c... / [c...] / f(c...)` | {} is getindex; c{:} is a comma-separated list -> splat. c{i}(j) after a brace stays a call (computed-callee ambiguity) |

## Control flow & functions

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `preallocated index loop` | `comprehension  y = [rhs for i in r]` | recognized when body is y(i)=rhs, i the loop var, rhs independent of y |
| ✅ | `@(x) expr  /  @name` | `x -> expr  /  name` | anonymous functions; lambda params are scoped so x(i) inside is indexing |
| 🟡 | `function-handle parameter f(x)` | `f(x) (kept a call, not f[x])` | heuristic: a param used only as a call-like callee; a read-only array param sized only by indexing may misclassify (loud error, not silent) |
| 🟡 | `command syntax (clc, format …)` | `dropped (no Julia equivalent)` | recorded as a todo |
| ✅ | `if/elseif/else/end` | `if/elseif/else/end` |  |
| ✅ | `for v = expr ... end` | `for v in expr ... end` |  |
| ✅ | `while c ... end` | `while c ... end` |  |
| ✅ | `break / continue / return` | `break / continue / return` | early `return` carries the function's outputs |
| ✅ | `switch/case/otherwise` | `if/elseif/else` | `case {a,b}` -> `sv == a || sv == b` |
| ✅ | `try/catch e` | `try/catch e` |  |
| ✅ | `function y = f(a,b)` | `function f(a, b) ... return y end` |  |
| ✅ | `function [u,v] = f(...)` | `... return (u, v) end` |  |
| ✅ | `varargin / varargin{i}` | `varargin... / varargin[i]` |  |
| ✅ | `nargin` | `computed prologue + optional params` |  |
| 🟡 | `nargout` | `nargout = <#declared outputs>` | assumes all outputs requested (Julia has no caller arity) |
| 🟡 | `single-line ;-separated control flow` | `—` | grammar emits ERROR; use newlines (flagged via has_error) |
| ✅ | `[~, x] = f(...)` | `(_, x) = ...` | ~ ignored-output placeholder kept in position |
| ✅ | `[m,i]=max(v) / [m,i]=min(v) / [s,p]=sort(v)` | `findmax / findmin / (sort(v), sortperm(v))` | output-arity-dependent; vector index is Int (matrix max index -> CartesianIndex differs) |

## Scripts vs functions

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `script with a top-level loop` | `body wrapped in let ... end` | Julia soft-scope rule |
| ✅ | `function file` | `top-level functions (hoisted ahead of script code)` |  |

## classdef

| | MATLAB | Julia | Notes |
|---|---|---|---|
| ✅ | `classdef C` | `abstract type AbstractC + mutable struct C <: AbstractC` |  |
| ✅ | `properties` | `struct fields` | defaults applied in the constructor |
| ✅ | `constructor function obj = C(...)` | `inner constructor using new()` |  |
| ✅ | `method function r = m(obj,...)` | `function m(obj::C, ...)` |  |
| ✅ | `operator methods plus/minus/mtimes/eq/lt/uminus/transpose/horzcat/...` | `extend Base.:+ / :- / :* / :(==) / :< / unary :- / transpose / hcat ...` | so a+b, a==b, -a, a' dispatch; elementwise times/rdivide/power left as plain methods (route via *) |
| 🟡 | `classdef C < S` | `abstract type AbstractC <: AbstractS` | inheritance only when S converted in the same unit |
| ⬜ | `struct arrays / events / Access= attrs` | `—` |  |

