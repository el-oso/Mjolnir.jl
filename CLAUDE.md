# Mjolnir.jl — agent guide

> **Name.** *Mjolnir* (Norse — Thor's hammer, the tool that forges and transforms); "Mj" = the
> M of MATLAB + the J of Julia. **Slogan: "Hammering MATLAB into a JL-shape."** Pronounced roughly
> *MYOL-nir* / *MJÖL-nir* (the "j" is a "y" sound) — be aware it can trip up non-Norse speakers.
> Fallback names if we ever rebrand (all encode M/ML + J/Ju): **Jumla** (Arabic "a whole"; spells
> Ju+ML), **Manju**/**Manjushri** (wisdom-sword cutting confusion), **Maju** (Basque serpent of
> renewal), **Jormungandr** (Norse world-serpent binding two worlds). See `README.md`.

A source-level **MATLAB → idiomatic-Julia converter**, written in Julia. Input: `.m` scripts,
function files, `classdef` files, and whole project trees. Output: idiomatic Julia (not a
line-by-line transliteration) — ideally a loadable package.

It is the **source-transpilation** complement to the author's runtime-interop trio: Mexicah.jl
(Julia→MEX), Unmex.jl (call MEX from Julia), LibMx.jl (shared mxArray FFI). Those are runtime;
this is source.

## Hard rules (do not violate)

- **No Python, anywhere** (global user rule). The parser is the C `tree-sitter` runtime + the
  MATLAB grammar from JLL **artifacts** (`tree_sitter_jll` + `tree_sitter_matlab_jll`), driven via
  `ccall`. Octave/MATLAB are used only as out-of-process oracles.
- **UUIDs via `Pkg`, never hand-written.** Add deps with `Pkg.add` / generate with `Pkg.generate`.
- **Run `runic -i src/ test/` before every commit.** All `src/*.jl` must be Runic-clean.
- **Clean-room, MIT.** Normative reference = public MATLAB docs. The MATLAB grammar comes from the
  `tree_sitter_matlab_jll` artifact (MIT, version-coordinated with `tree_sitter_jll`) — nothing
  vendored, no build step. **Octave is never linked and its GPL source is never read** — it is an
  arm's-length subprocess test oracle only. See `NOTICE`.

## Build & test

```
julia --project=. -e 'using Pkg; Pkg.instantiate()'   # pulls the tree-sitter JLL artifacts
julia --project=test test/runtests.jl                 # full suite (front-end + lower/emit + idiomatic + oracle)
```
No build step: the tree-sitter runtime + MATLAB grammar are JLL artifacts (`tree_sitter_jll` +
`tree_sitter_matlab_jll`), so `using Mjolnir` works after `Pkg.instantiate`. `src/Mjolnir.jl`
aliases `LIBTREESITTER`/`LIBTREESITTER_MATLAB` to the JLL libs. Octave is needed for the
differential-oracle tests (skipped with a warning if absent).

## Pipeline (each stage is one file in `src/`)

```
.m source ─▶ parse.jl  (tree-sitter FFI → MatlabCST)
          ─▶ lower.jl  (CST → Julia Expr; scope-resolves call-vs-index; uses builtins.jl)
          ─▶ idiomatic.jl  run_semantic (always: shape-aware correctness) then
                           run_idiomatic (de-broadcast / de-colon / let-wrap)
          ─▶ emit.jl   (Expr → source; JuliaSyntax validity gate; ConvertResult)
          ─▶ assemble.jl  convert_project: .m tree → package (+pkg/ → submodule)
```
Public API: `convert_matlab(src; modulename, idiomatic=true, wrap_script=true)`,
`convert_file`, `convert_project(srcdir, outdir; name)`, plus `parse_matlab`/`parse_file`.

## Invariants & gotchas (learned the hard way)

- **1-based + column-major are shared** with Julia — translate indices/storage as-is. This is
  why this is more tractable than MATLAB→Python.
- **Vector literals are MATLAB-faithful** (design decision, revisited after real-code e2e showed
  ~30% of functions break otherwise): `[1 2 3]` → `[1 2 3]` (1×N **Matrix**), `[1;2;3]` → `Vector`,
  `[A b]`/`[A;b]` → `hcat`/`vcat` (concatenation). So `size(x,2)`, transpose (`'`), `x*y` inner
  products, and augmented matrices all match MATLAB. Cost: `sort`/`cumsum`/`cumprod` need a `dims`
  for ≥2-D, so they're emitted `ndims`-dispatched (`_dimsafe`): `f(x)` for a vector, `f(x; dims=
  first-non-singleton)` for a 1×N row.
- **`name(...)` is call-vs-index ambiguous.** Resolved by a scope pre-pass (`collect_vars`): if
  the name is a known variable → `x[i]` (index), else → call/builtin. Keep this pre-pass correct.
- **Operators lower to broadcast for safety** (`+`→`.+`, `==`→`.==`, …) because MATLAB does
  implicit expansion and Julia `+` won't add scalar+array. `idiomatic.jl` **de-broadcasts** only
  when shape inference proves both operands `:scalar`. `*` `/` `^` `\` stay matrix ops.
- **Shape inference** (`shape_of`/`shape_env`, lattice `:scalar/:vector/:matrix/:unknown`) starts
  **optimistic `:scalar`** so self-referential accumulators (`acc = acc + x`) resolve — a
  pessimistic start silently breaks de-broadcasting. Drives matrix reduction fixups too.
- **Matrix reductions diverge**: MATLAB `sum/prod/max/min(A)` reduce the first dim (row vector);
  Julia collapses to scalar. `run_semantic` adds `dims=1` only when the arg is *proven* matrix.
  `length(x)`→`maximum(size(x))` (MATLAB length = longest dim; Julia `length` = numel = MATLAB `numel`).
- **`nargin`/optional args**: when a body uses `nargin`, fixed params become optional (`=nothing`)
  and a prologue computes `nargin`. `varargin` → `varargin...`.
- **Scripts vs functions**: a script with a top-level loop is wrapped in `let … end` (Julia
  soft-scope errors otherwise). Definitions (abstract/struct/function) are hoisted ahead of
  script statements, in order (a struct MUST precede its methods).
- **classdef** → `abstract type AbstractC [<: AbstractSuper]` + a `mutable struct`. When the ctor
  is the simple "assign every field once" pattern, `_try_parametric` (lower.jl) emits a **type-stable
  parametric** struct `C{T1,…} <: AbstractC; f1::T1; …` with a direct `new{typeof(e1),…}(…)`;
  otherwise it falls back to an untyped `mutable struct C` with the incremental `obj = new()` ctor.
  Methods → outer `f(obj::C, …)` (`obj::C` matches any `C{…}`); operator methods extend `Base.:+`
  etc.; `disp`/`display` → `Base.show`. `Ctx.in_method` makes `obj.field = v` an in-place set;
  **outside** classdef the same syntax builds a **NamedTuple** — we prefer structs/NamedTuples, **not `Dict`**.
- **Idiomatic passes (idiomatic.jl):** `out = expr; return out` collapses to `return expr`
  (`_collapse_return`); homogeneous cell literals narrow `Any[1,2,3]`→`[1,2,3]` (`_narrow_cells`,
  but kept `Any[]` if the var is element-assigned or heterogeneous).
- **Duplicate-function guard:** `emit.jl` `_duplicate_funcs` flags defs sharing a (qualified name,
  arg-type signature) — they'd silently overwrite — as a todo; `convert_project` also warns per
  module scope (`_warn_duplicate_funcs`). Genuine multiple dispatch (distinct arg types) isn't flagged.
- **convert_project deps & audit:** deps are wired by **path** when `develop`ed in the active env or
  given via `dev=Dict(name=>path)` (offline/unregistered like Unmex/LibMx), else `Pkg.add` (uuid-
  pinned). `audit_project(srcdir; searchpaths)` / `audit=true` reports called-but-undefined functions
  (likely in folders not yet added).
- **Single-line `;`-separated control flow** (`for …; …; end`) makes the grammar emit an ERROR
  node → flagged via `ConvertResult.has_error`. Use newlines.
- **CRLF line endings are normalized** in `parse_matlab` (`\r\n`/`\r` → `\n`). Windows-authored
  `.m` files otherwise break the grammar's `...` line-continuation + trailing-comment handling
  (a stray `\r` orphans the continuation line → spurious ERROR nodes).
- **Emitter must stay valid**: `emit.jl` runs a `JuliaSyntax` parse gate; unmapped builtins pass
  through as a plain call and are recorded in `ConvertResult.todos`.

## Correctness is gated by the differential oracle

`test/octave_oracle.jl` runs each MATLAB snippet in **Octave** (subprocess, JSON dump) and the
converted Julia (fresh module), comparing numerically (`oracle_check`) or field-wise for structs;
`oracle_check_class` does the same for `classdef` (class `.m` on the Octave path; converted class
as a Julia prelude). **Any new mapping must keep the oracle green** — that is the definition of
"correct". Idiomatic rewrites are only allowed if they survive it.

## The idiom map is the shared contract (one source, three consumers)

**`src/idioms.jl` is canonical** — a structured `IDIOMS::Vector{Idiom}` registry. From it:
- **humans** get `docs/matlab_julia_idioms.md` (generated),
- **agents/tools** get `docs/idioms.json` (generated) — or call the query API,
- **Mjolnir** queries it: `idioms(; category, status, builtin)`.

Both `docs/*` are **generated** — never hand-edit them; edit `IDIOMS`, then run
`Mjolnir.write_idioms()` to regenerate. A test asserts the committed `docs/idioms.json` /
`docs/matlab_julia_idioms.md` equal the freshly-generated output (so they can't go stale) **and**
that `idiom_builtin_gaps().unimplemented` is empty — i.e. the registry never claims a `builtin`
the converter doesn't actually implement (no doc↔code drift). When you add a mapping: implement
it in `builtins.jl`/`lower.jl`, add an `Idiom` row (set `builtin=` for function maps), run
`write_idioms()`, keep the oracle green.

## Status / roadmap

Done: parse → lower → idiomatic → emit → package assembly; classdef; matrix-shape correctness;
nargin/varargin; dependency wiring; cells & structs; **Stage 5 gated LLM refinement** (`llm.jl`:
`LLMBackend` + `FunctionBackend`/`ManualBackend`(Copilot)/`SubprocessBackend`(llama.cpp/Tonalli)/
`HTTPBackend` via `claude_backend`/`ollama_backend`; `gated_refine(backend, code; probes)` accepts
a candidate only if `verify_equivalent` proves it matches the deterministic baseline — refactor
only, never changes behavior).

Deferred coverage (next): `containers.Map`→`Dict`, struct arrays, dynamic field names, `nargout`,
toolbox functions, loop→comprehension polish, and richer auto-probe generation for `gated_refine`.
