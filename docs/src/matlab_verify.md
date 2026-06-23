# Verifying against MATLAB

Mjolnir's correctness is gated by a **differential oracle** that runs each MATLAB snippet
in an external engine (Octave or MATLAB) and compares the output variables to the converted
Julia. By default the CI uses **Octave**, which is free, fast, and covers the vast majority
of cases.

Real MATLAB catches a handful of things Octave gets wrong:

- `string` (double-quoted) vs `char` array semantics
- `classdef` subtleties (property default values, `Dependent` properties, events)
- Toolbox functions that Octave does not implement

## Running the oracle against Octave (default)

```
julia --project=test test/runtests.jl
```

This is what CI runs. The Octave oracle is the definition of "correct" — any new mapping
must keep it green.

## Running against MATLAB (collaborators)

If you have MATLAB installed, set the `MJOLNIR_ORACLE` environment variable:

```
# MATLAB only
MJOLNIR_ORACLE=matlab julia --project=test test/runtests.jl

# Octave AND MATLAB (runs each oracle case against both engines)
MJOLNIR_ORACLE=both julia --project=test test/runtests.jl
```

The variable is silently ignored for engines that are not installed — you will see a skip
notice rather than an error.

## Generating IP-free divergence reports

When converted Julia disagrees with the engine, `differential_report` builds an IP-free
report you can share without disclosing proprietary source:

```julia
using Mjolnir

rep = differential_report(matlab_src, ["y", "z"]; anonymize = true)
# rep["mismatched"]  → names of variables that differ
# rep["divergences"] → per-variable type/size/first-diff-index summary
# rep["converted_julia"] → anonymized Julia output
# rep["skeleton"]    → node-kind s-expression (no user names or literals)
```

With `anonymize=true` (the default) the report contains:

- Variable/function names replaced by `id1`, `id2`, … placeholders
- Numeric and string literals stripped
- Divergence described as type, size, first differing flat index, and magnitude — never raw values

Set `anonymize=false` for local debugging where privacy is not a concern.

## Collaborator quick-start

Clone the repo, ensure MATLAB is on `PATH`, then:

```
julia --project=. dev/matlab_verify.jl
```

This runs `differential_report` over a set of representative snippets and writes IP-free
JSON reports to `dev/reports/`. Share those files with the maintainer so MATLAB-specific
mappings can be improved.

## Engine API

See the [API reference](api.md) for full documentation of `octave_available`,
`matlab_available`, `available_engines`, `differential_report`, and
`differential_report_json`.
