# Mjolnir.jl

**Hammering MATLAB into shape.**

A source-level **MATLAB → idiomatic Julia** converter, written in Julia. It turns `.m`
scripts, function files, `classdef` files, and whole project trees into idiomatic Julia
(not a line-by-line transliteration) — ideally a loadable package.

The name is *Mjǫlnir*, Thor's hammer — the tool that forges raw material into shape — and the
"**Mj**" carries the **M** of MATLAB and the **J** of Julia. (Pronounced *MYOL-nir*; the "j"
is a "y" sound.)

Mjolnir is the **source-transpilation** complement to the runtime-interop trio
[Mexicah.jl](https://github.com/el-oso/Mexicah.jl) (Julia→MEX),
[Unmex.jl](https://github.com/el-oso/Unmex.jl) (call a MEX from Julia), and
[LibMx.jl](https://github.com/el-oso/LibMx.jl) (shared mxArray FFI).

## Quick start

```julia
julia> import Mjolnir
julia> include(joinpath(pkgdir(Mjolnir), "deps", "build.jl"))   # once: build the MATLAB grammar

julia> using Mjolnir
julia> println(convert_matlab("""
       function y = sq(x)
         y = x.^2;
       end
       """).julia)
# function sq(x)
#     y = x .^ 2
#     return y
# end

julia> convert_file("analysis.m")            # one file
julia> convert_project("matlab/", "out/"; name = "MyPkg")   # a whole project -> a Julia package
```

How it works, the supported subset, and the exact translation rules live in
[`docs/matlab_julia_idioms.md`](docs/matlab_julia_idioms.md). Contributor/agent notes are in
[`CLAUDE.md`](CLAUDE.md).

## Highlights

- **Real parser** — the community MIT `tree-sitter-matlab` grammar via C FFI (no Python),
  handling MATLAB's hard ambiguities (`'` transpose-vs-string, command syntax, `[1 -2]`, `end`).
- **Idiomatic, not literal** — 1-based indexing & column-major map straight across; broadcasting,
  multiple dispatch for `classdef`, NamedTuples for structs, de-broadcasting where shapes allow.
- **Correctness is gated by a differential oracle** — every snippet is run in real **Octave**
  (and optionally MATLAB) and compared against the converted Julia.
- **Optional, gated LLM polish** — a refactor-only refinement that is accepted only if it stays
  behaviorally identical (Claude / Ollama / local CLI / Copilot backends).

## The name (and fallbacks)

*Mjolnir* is the chosen name. If it ever needs to change, these candidates also encode
**M/ML** (MATLAB) + **J/Ju** (Julia):

| Name | Origin / idea |
|------|----------------|
| **Jumla** | Arabic *jumla*, "a whole / complete sentence" — literally spells **Ju**+**ML** |
| **Manju** / **Manjushri** | Buddhist bodhisattva whose sword cuts confusion into clarity |
| **Maju** | Basque serpent of renewal (shedding the old skin → new language) |
| **Jormungandr** | Norse world-serpent binding two worlds (the round-trip cycle) |

Honorable mentions: `Majolica` (the craft of shaping raw clay into a finished glazed piece),
`Mulia` (Malay "noble"; reads as M + *ulia* ≈ Julia).

## License

MIT. Clean-room: derived from publicly documented MATLAB references; no MathWorks source.
Octave is used only as an out-of-process test oracle. See [`NOTICE`](NOTICE).
