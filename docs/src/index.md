---
layout: home

hero:
  name: "Mjolnir.jl"
  text: "MATLAB → idiomatic Julia"
  tagline: Hammering MATLAB into shape.
  actions:
    - theme: brand
      text: Getting started
      link: /getting_started
    - theme: alt
      text: How it works
      link: /guide
    - theme: alt
      text: Idiom map
      link: /idioms
    - theme: alt
      text: View on GitHub
      link: https://github.com/el-oso/Mjolnir.jl

features:
  - title: Idiomatic, not line-by-line
    details: Deterministic rewrite passes turn MATLAB into Julia that reads like Julia — broadcasting, comprehensions, multiple dispatch, structs over Dicts.
  - title: Scripts, functions, classes, projects
    details: Converts .m scripts, function files, classdef OOP, and whole project trees into a loadable Julia package.
  - title: Correctness gated by an oracle
    details: Every mapping is differentially tested against Octave (and optionally real MATLAB). Idiomatic rewrites are kept only if behavior is preserved.
---

# Mjolnir.jl

A source-level **MATLAB → idiomatic Julia** converter, written in Julia. It turns `.m`
scripts, function files, `classdef` files, and whole project trees into idiomatic Julia
(not a line-by-line transliteration) — ideally a loadable package.

The name is *Mjǫlnir*, Thor's hammer — the tool that forges raw material into shape — and the
"**Mj**" carries the **M** of MATLAB and the **J** of Julia. (Pronounced *MYOL-nir*; the "j"
is a "y" sound.)

Mjolnir is the **source-transpilation** complement to the runtime-interop trio
[Mexicah.jl](https://github.com/el-oso/Mexicah.jl) (Julia→MEX),
[Unmex.jl](https://github.com/el-oso/Unmex.jl) (call a MEX from Julia), and
[LibMx.jl](https://github.com/el-oso/LibMx.jl) (shared `mxArray` FFI).

## At a glance

```julia
using Mjolnir
println(convert_matlab("""
    function y = sq(x)
      y = x.^2;
    end
    """).julia)
# function sq(x)
#     y = x .^ 2
#     return y
# end
```

Mjolnir handles the hard parts of the language — `'` transpose vs. string, command syntax,
whitespace-significant matrices, `end` in subscripts, column-major/1-based layout (shared with
Julia), `classdef` operator overloading, cell comma-separated lists, multi-output builtins, and
more. See the [idiom map](idioms.md) for the exact, normative translation rules.
