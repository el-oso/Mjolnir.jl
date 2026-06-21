# How it works

Mjolnir is an IR pipeline. Each stage is one file in `src/`:

```
.m source ─▶ parse.jl      (tree-sitter FFI → MatlabCST)
          ─▶ lower.jl      (CST → Julia Expr; scope-resolves call-vs-index; uses builtins.jl)
          ─▶ idiomatic.jl  run_semantic (always: shape-aware correctness) then
                           run_idiomatic (de-broadcast / de-colon / let-wrap / comprehensions)
          ─▶ emit.jl       (Expr → source; JuliaSyntax validity gate; ConvertResult)
          ─▶ assemble.jl   (convert_project: .m tree → package, +packages → submodules)
```

## Why MATLAB → Julia is tractable

MATLAB and Julia share **1-based indexing and column-major** storage, which eliminates the single
largest class of bugs that plagues MATLAB→Python/NumPy translation — no index rebasing, no
row/col-major transposition.

## Key translation decisions

- **Operators lower to broadcast for safety** (`+`→`.+`, `==`→`.==`, …) because MATLAB does
  implicit expansion; the idiomatic pass **de-broadcasts** when shape inference proves both
  operands scalar. `*` `/` `^` `\` stay matrix operators.
- **Vector literals are MATLAB-faithful**: `[1 2 3]` → `[1 2 3]` (1×N matrix), `[1;2;3]` → a
  `Vector`, `[A b]` → `hcat`. So `size(x,2)`, transpose, and inner products match MATLAB.
- **`name(...)` call-vs-index** is resolved by a scope pre-pass: a known variable → `x[i]`
  (index), otherwise a call/builtin.
- **`classdef`** → an abstract type + a `mutable struct`; methods → outer functions dispatching on
  the type; operator methods (`plus`, `eq`, `uminus`, …) extend `Base.:+`/`:(==)`/…; `disp`/
  `display` → `Base.show`.
- **Structs** become Julia `struct`s / `NamedTuple`s (not `Dict`s), per Julia idiom.

## Correctness is gated by a differential oracle

Each MATLAB snippet is run in **Octave** (subprocess, JSON dump) and compared to the converted
Julia (fresh module). Any new mapping must keep the oracle green — that is the definition of
"correct". Idiomatic rewrites are only kept if they survive it. A real-MATLAB oracle can be used
for the final/pre-release gate (the cases Octave gets wrong: `string`, classdef, toolboxes).

## Reporting bugs without sharing source

If a conversion misbehaves on proprietary code, `conversion_report(src)` (or
`conversion_report_json`) produces an **IP-free** diagnostic you can file without the source.
Conversion is resilient — it does not stop at the first error, so one report captures every
problem. The report renders the CST as an s-expression of node *kinds*, replaces user
variable/function names with `idN` placeholders, strips string/number literals, and scrubs those
names from messages and todos. MATLAB keywords and recognized builtins are kept verbatim (public
API, not your IP), so the maintainer can reproduce and fix the issue from structure alone.

## Coverage

Mjolnir has been shaken down against real open-source MATLAB across many domains — numerical
methods, DSP, optimization, control, image processing, machine learning, OOP (Chebfun), text/data
parsing, sparse/FEM, and bioinformatics (~1900 files). Toolbox functions map to the natural Julia
package (Plots, DSP, ControlSystems, Images, Interpolations, SparseArrays, BioSequences, …). The
exact, normative rules — including known partials and divergences — are in the [idiom map](idioms.md).
