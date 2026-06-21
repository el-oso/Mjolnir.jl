# Getting started

## Installation

Mjolnir is not yet registered in the General registry. Install it directly from GitHub:

```julia
using Pkg
Pkg.add(url = "https://github.com/el-oso/Mjolnir.jl")
```

### Build the parser (once)

Mjolnir parses MATLAB with the C `tree-sitter` runtime and the MATLAB grammar, driven via
`ccall`. The grammar is compiled once into `runtime/`:

```julia
import Mjolnir
include(joinpath(pkgdir(Mjolnir), "deps", "build.jl"))   # clones + compiles the MATLAB grammar
```

A C compiler (`cc`/`gcc`) and `git` must be available. The module errors at load if the grammar
has not been built.

!!! note "Differential testing needs Octave"
    Running the test suite's differential oracle requires [Octave](https://octave.org) on `PATH`
    (used only as an arm's-length subprocess — never linked, its source never read). Tests that
    need it are skipped with a warning if Octave is absent.

## First conversion

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

[`convert_matlab`](@ref) returns a [`ConvertResult`](@ref) with the generated `julia` source, the
`imports` it needs, and any `todos` (e.g. unmapped functions).

## Converting files and projects

```julia
convert_file("analysis.m")                                  # one .m file
convert_project("matlab/", "out/"; name = "MyPkg")          # a whole tree -> a Julia package
```

`convert_project` mirrors a MATLAB project layout into a Julia package: it scaffolds
`Project.toml` (UUID generated via `Pkg`, never hand-written), wires dependencies, and maps
`+package` folders to submodules.

## Optional: gated LLM refinement

Mjolnir can optionally polish the deterministic output with an LLM, but **only accepts a candidate
if it is proven behaviorally equivalent** to the deterministic baseline. See
[LLM refinement](llm.md).
