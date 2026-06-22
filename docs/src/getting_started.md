# Getting started

## Install it

Mjolnir isn't in Julia's package registry yet, so install it straight from GitHub:

```julia
using Pkg
Pkg.add(url = "https://github.com/el-oso/Mjolnir.jl")
```

Then `using Mjolnir` and you're ready — there's nothing to build or configure.

!!! note "Good to know"
    The MATLAB parser ships as a prebuilt artifact, so you don't need a C compiler or any system
    libraries. (If you ever run Mjolnir's own test suite it will compare results against
    [Octave](https://octave.org) when that's installed — but that's only for testing the package,
    never for using it.)

## Your first conversion

Give [`convert_matlab`](@ref) some MATLAB and look at the `.julia` field:

```julia
using Mjolnir

result = convert_matlab("""
    function s = mysum(v)
      s = 0;
      for i = 1:length(v)
        s = s + v(i);
      end
    end
    """)

println(result.julia)
```

prints

```julia
function mysum(v)
    s = 0
    for i = 1:maximum(size(v))
        s = s + v[i]
    end
    return s
end
```

## What you get back

`result` is a [`ConvertResult`](@ref) with three fields worth knowing:

- `result.julia` — the converted code, as a string.
- `result.imports` — any packages the code needs (for example `Plots` or `FFTW`).
- `result.todos` — a short to-do list of anything Mjolnir couldn't translate by itself. It's
  usually empty; when it isn't, it's pointing you straight at the spot to check.

## Converting files and whole projects

```julia
convert_file("analysis.m")                            # one file

convert_project("matlab/", "out/"; name = "MyPkg")    # a whole folder → a Julia package
```

`convert_project` keeps your folder layout and writes a ready-to-load package, dependencies and
all. See [Examples](examples.md) for these on real code.

## Polishing with an LLM (optional, experimental)

Mjolnir can optionally ask a language model to tidy the output a little further — but only when the
result is proven to behave identically to the plain conversion, so it can never quietly change what
your code does. This part is still experimental; see [LLM refinement](llm.md).
