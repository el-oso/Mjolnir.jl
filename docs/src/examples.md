# Examples

The easiest way to get a feel for Mjolnir is to watch it work. Each example below shows the MATLAB
you feed in and the Julia you get back.

```julia
using Mjolnir
```

## A quick snippet

Pass a string of MATLAB to [`convert_matlab`](@ref) and read the `.julia` field:

```julia
println(convert_matlab("""
    function y = square(x)
      y = x.^2;
    end
    """).julia)
```

MATLAB in:

```matlab
function y = square(x)
  y = x.^2;
end
```

Julia out:

```julia
function square(x)
    y = x .^ 2
    return y
end
```

Notice it added the `return` and turned `.^` into Julia's `.^` — small things, but it does them
consistently so you don't have to.

## A function with a loop

```matlab
function s = mysum(v)
  s = 0;
  for i = 1:length(v)
    s = s + v(i);
  end
end
```

becomes

```julia
function mysum(v)
    s = 0
    for i = 1:maximum(size(v))
        s = s + v[i]
    end
    return s
end
```

A few MATLAB-isms were handled for you: `v(i)` became `v[i]` (Julia indexes with square brackets),
and `length` became `maximum(size(...))` so it matches MATLAB's "longest dimension" meaning.

## Converting a file

```julia
convert_file("analysis.m")
```

This reads `analysis.m` and returns the converted Julia (again as a [`ConvertResult`](@ref) —
see [Reading the result](#Reading-the-result) below).

## A class

MATLAB `classdef` turns into a Julia type plus functions. Operators carry over too, so `a + b` and
`a == b` keep working:

```matlab
classdef Vec2
  properties
    x
    y
  end
  methods
    function obj = Vec2(a, b)
      obj.x = a;
      obj.y = b;
    end
    function r = plus(a, b)
      r = Vec2(a.x + b.x, a.y + b.y);
    end
  end
end
```

becomes

```julia
abstract type AbstractVec2 end
mutable struct Vec2{T1, T2} <: AbstractVec2
    x::T1
    y::T2
    function Vec2(a, b)
        return new{typeof(a), typeof(b)}(a, b)
    end
end
function Base.:+(a::Vec2, b)
    return Vec2(a.x .+ b.x, a.y .+ b.y)
end
```

The `plus` method became `Base.:+`, so `Vec2(1, 2) + Vec2(3, 4)` works in Julia just like it did in
MATLAB. The struct came out **parametric** (`Vec2{T1, T2}`) so its fields keep their concrete types
instead of falling back to `Any` — that's Julia's idiom for a fast, type-stable value type.

Classes with named instance methods also get a [TypeContracts](https://github.com/el-oso/TypeContracts.jl)
interface contract via [BaseTypeContracts](https://github.com/el-oso/BaseTypeContracts.jl):

```matlab
classdef Point
  properties
    x
    y
  end
  methods
    function obj = Point(x, y)
      obj.x = x;
      obj.y = y;
    end
    function d = dist(obj)
      d = sqrt(obj.x^2 + obj.y^2);
    end
    function obj = scale(obj, k)
      obj.x = obj.x * k;
      obj.y = obj.y * k;
    end
  end
end
```

becomes

```julia
using BaseTypeContracts

abstract type AbstractPoint end
function dist end
function scale end
@contract AbstractPoint begin
    dist(::Self)::Any
    scale(::Self, ::Any)::Any
end
mutable struct Point{T1, T2} <: AbstractPoint
    x::T1
    y::T2
    function Point(x, y)
        return new{typeof(x), typeof(y)}(x, y)
    end
end
function dist(obj::Point)
    return sqrt.(obj.x ^ 2 .+ obj.y ^ 2)
end
function scale(obj::Point, k)
    obj.x = obj.x * k
    obj.y = obj.y * k
    return obj
end
@verify Point
```

The `@contract` on `AbstractPoint` declares that any subtype must implement `dist` and `scale`.
The `@verify Point` at the end confirms this at precompile time — a missing method is caught
immediately, not at runtime.

## A whole folder → a package

Point [`convert_project`](@ref) at a folder of `.m` files and it builds a ready-to-load Julia
package:

```julia
convert_project("matlab/", "out/"; name = "MyPkg")
```

It mirrors your layout — each `.m` file becomes a `.jl` file, and MATLAB `+package` folders become
Julia sub-modules — and writes a `Project.toml` with the right dependencies filled in.

### Offline or unregistered dependencies

If the generated package needs a package that isn't registered or you're behind a firewall (for
example [Unmex.jl](https://github.com/el-oso/Unmex.jl) for a compiled MEX), Mjolnir wires it in
**by path** instead of downloading it. Anything you've already `develop`ed into your current Julia
environment is picked up automatically; or point at the clones yourself:

```julia
convert_project("matlab/", "out/"; name = "MyPkg",
                dev = Dict("Unmex" => "/home/me/clones/Unmex.jl",
                           "LibMx" => "/home/me/clones/LibMx.jl"))
```

### Is anything missing?

Scattered projects often call helpers that live in folders you didn't include. Ask Mjolnir what's
unaccounted for — either with `audit = true` on the conversion, or directly:

```julia
report = audit_project("matlab/"; searchpaths = ["/home/me/more_matlab"])
report.unresolved    # functions called but defined nowhere in the tree
report.suggestions   # name => folder where a matching `.m` was found
```

Add the suggested folders and convert again. Mjolnir also flags **duplicate function names** (two
definitions that would silently overwrite each other) as a `todo`/warning, so you can rename or
namespace them.

## Reading the result

`convert_matlab` / `convert_file` hand back a [`ConvertResult`](@ref) with three useful fields:

```julia
r = convert_matlab("y = fft(x);\n")

r.julia      # the converted Julia source (a string)
r.imports    # packages the result needs, e.g. [:FFTW]
r.todos      # a short to-do list of anything it couldn't translate on its own
```

`todos` is the honest part: if Mjolnir met something it doesn't know how to translate yet, it
leaves the call as-is and notes it here instead of guessing.

## Built-in and toolbox functions

Common MATLAB functions map to their natural Julia equivalent — often a well-known package:

```matlab
y = fft(x);        % →  y = fft(x)            (uses FFTW)
n = norm(v);       % →  n = norm(v)           (uses LinearAlgebra)
plot(x, y);        % →  plot(x, y)            (uses Plots)
s = sort(v);       % →  s = sort(v; dims=…)
```

The full, up-to-date list of what maps to what — including the partial cases and the few places
MATLAB and Julia genuinely differ — is the [Idiom map](idioms.md).

## "It left a TODO — now what?"

If a conversion leaves a `todo` (for example, a function Mjolnir doesn't map yet), you have a couple
of easy options:

- **Just fill it in.** The generated code still runs everywhere else; replace the one flagged call
  with the Julia equivalent by hand.
- **Tell us, privately.** `conversion_report(src)` produces a shareable, **source-free** description
  of the problem (your variable and function names are replaced with placeholders), so you can
  report it without sending your actual code. See [How it works](guide.md#Reporting-bugs).
