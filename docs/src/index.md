```@raw html
---
layout: home

hero:
  name: "Mjolnir.jl"
  text: "MATLAB → idiomatic Julia"
  tagline: Hammering MATLAB into a JL-shape.
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
    icon: 🔨
    details: Deterministic rewrite passes turn MATLAB into Julia that reads like Julia — broadcasting, comprehensions, multiple dispatch, structs over Dicts.
  - title: Scripts, functions, classes, projects
    icon: 📦
    details: Converts .m scripts, function files, classdef OOP, and whole project trees into a loadable Julia package.
  - title: Correctness gated by an oracle
    icon: ✅
    details: Every mapping is differentially tested against Octave (and optionally real MATLAB). Idiomatic rewrites are kept only if behavior is preserved.
---
```

# Mjolnir.jl

**Mjolnir turns your MATLAB code into Julia you can actually read** — `.m` scripts, functions,
classes, even whole folders. It doesn't translate line by line; it writes the Julia the way a Julia
programmer would, so the result is a real starting point, not a mess to clean up.

## See it in action

```julia
using Mjolnir
println(convert_matlab("""
    function y = sq(x)
      y = x.^2;
    end
    """).julia)
```

```julia
function sq(x)
    y = x .^ 2
    return y
end
```

That's the whole idea: hand it MATLAB, get back tidy Julia. The [Getting started](getting_started.md)
page walks you through installing it, and [Examples](examples.md) shows it on real functions,
classes, and projects.

It also takes care of the fiddly corners of MATLAB that usually trip up a hand-translation —
the `'` that's sometimes a transpose and sometimes a string, whitespace-sensitive matrices like
`[1 -2]`, `end` inside indexing, and so on. The [Idiom map](idioms.md) lists exactly what becomes
what.

!!! note "The name"
    *Mjolnir* is Thor's hammer — the tool that forges raw material into shape — and "**Mj**" carries
    the **M** of MATLAB and the **J** of Julia. (Say it *MYOL-nir*; the "j" is a "y" sound.) It's
    the source-level companion to the runtime-interop tools
    [Mexicah.jl](https://github.com/el-oso/Mexicah.jl),
    [Unmex.jl](https://github.com/el-oso/Unmex.jl), and
    [LibMx.jl](https://github.com/el-oso/LibMx.jl).
