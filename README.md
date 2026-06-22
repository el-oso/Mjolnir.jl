# Mjolnir.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/Mjolnir.jl/dev/)
[![CI](https://github.com/el-oso/Mjolnir.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/el-oso/Mjolnir.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://coveralls.io/repos/github/el-oso/Mjolnir.jl/badge.svg?branch=main)](https://coveralls.io/github/el-oso/Mjolnir.jl?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Code style: Runic](https://img.shields.io/badge/code_style-Runic-000000.svg)](https://github.com/fredrikekre/Runic.jl)

**Hammering MATLAB into a JL-shape.**

Mjolnir turns your MATLAB code into Julia you can actually read — `.m` scripts, functions, classes,
and whole project folders. It doesn't translate line by line; it writes the Julia the way a Julia
programmer would, so you get a real starting point rather than a mess to clean up.

The name is *Mjǫlnir*, Thor's hammer — the tool that forges raw material into shape — and the
"**Mj**" carries the **M** of MATLAB and the **J** of Julia. (Pronounced *MYOL-nir*; the "j"
is a "y" sound.)

Mjolnir is the **source-transpilation** complement to the runtime-interop trio
[Mexicah.jl](https://github.com/el-oso/Mexicah.jl) (Julia→MEX),
[Unmex.jl](https://github.com/el-oso/Unmex.jl) (call a MEX from Julia), and
[LibMx.jl](https://github.com/el-oso/LibMx.jl) (shared mxArray FFI).

## Installation

Mjolnir is not yet registered in General. Install from GitHub:

```julia
using Pkg
Pkg.add(url = "https://github.com/el-oso/Mjolnir.jl")
```

No build step — the `tree-sitter` runtime and the MATLAB grammar come from the Julia **artifact
ecosystem** (`tree_sitter_jll` + `tree_sitter_matlab_jll`), so there's no system `libtree-sitter`,
no C compiler, and no ABI mismatch. `using Mjolnir` just works.

[Octave](https://octave.org) on `PATH` is optional — only the differential-oracle tests use it
(as an arm's-length subprocess; never linked, source never read).

## Quick start

```julia
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

Full documentation is at **[el-oso.github.io/Mjolnir.jl](https://el-oso.github.io/Mjolnir.jl/dev/)**.
The exact, normative translation rules live in the
[idiom map](https://el-oso.github.io/Mjolnir.jl/dev/idioms) (generated from
[`docs/matlab_julia_idioms.md`](docs/matlab_julia_idioms.md)). Contributor/agent notes are in
[`CLAUDE.md`](CLAUDE.md).

## Highlights

- **Real parser** — the community MIT `tree-sitter-matlab` grammar via C FFI (no Python), shipped
  as a JLL artifact, handling MATLAB's hard ambiguities (`'` transpose-vs-string, command syntax,
  `[1 -2]`, `end`).
- **Idiomatic, not literal** — 1-based indexing & column-major map straight across; broadcasting,
  multiple dispatch for `classdef`, NamedTuples for structs, de-broadcasting where shapes allow.
- **Correctness is gated by a differential oracle** — every snippet is run in real **Octave**
  (and optionally MATLAB) and compared against the converted Julia.
- **Optional, gated LLM polish** *(experimental, under development)* — a refactor-only refinement
  accepted only if it stays behaviorally identical (Claude / Ollama / local CLI / Copilot backends).
  The model story (small local model vs. remote) is still being figured out; the deterministic
  pipeline is the supported path.

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
