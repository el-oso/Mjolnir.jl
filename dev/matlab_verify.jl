# dev/matlab_verify.jl — collaborator script for MATLAB-based differential verification.
#
# Run this on a machine that has MATLAB installed:
#
#   julia --project=. dev/matlab_verify.jl
#
# It runs `differential_report` over a set of sample snippets and writes IP-free JSON
# reports to dev/reports/. Share those files (they contain no user names or raw literals)
# so the Mjolnir maintainer can improve engine-specific mappings.
#
# To run the FULL test suite against MATLAB instead of Octave:
#
#   MJOLNIR_ORACLE=matlab julia --project=test test/runtests.jl
#
# To run against BOTH (Octave + MATLAB) and catch any divergences between them:
#
#   MJOLNIR_ORACLE=both julia --project=test test/runtests.jl

using Mjolnir
using JSON

# ── How to run ────────────────────────────────────────────────────────────────────────────────────

println("""
Mjolnir — MATLAB differential verifier
=======================================

Engines found: $(available_engines())

To run the full test suite against MATLAB:
  MJOLNIR_ORACLE=matlab julia --project=test test/runtests.jl

To run against both Octave and MATLAB simultaneously:
  MJOLNIR_ORACLE=both julia --project=test test/runtests.jl

Running differential_report over sample snippets...
""")

if !matlab_available()
    @warn "matlab not found on PATH — reports will use Octave (if available)"
end
if isempty(available_engines())
    error("no oracle engine available; install octave or matlab and re-run")
end

# ── Sample snippets ───────────────────────────────────────────────────────────────────────────────

const SAMPLES = [
    (
        "scalar_arithmetic",
        "a = 3;\nb = 4;\nc = sqrt(a^2 + b^2);\n",
        ["c"],
    ),
    (
        "vector_ops",
        "v = [1 2 3 4];\ns = sum(v);\nm = max(v);\n",
        ["s", "m"],
    ),
    (
        "matrix_index",
        "A = [1 2; 3 4];\nd = A(2, 1);\nt = trace(A);\n",
        ["d", "t"],
    ),
    (
        "accumulator_loop",
        "s = 0;\nfor i = 1:10\n  s = s + i;\nend\n",
        ["s"],
    ),
    (
        "string_ops",
        "u = upper('hello');\nb = strcmp('a', 'a');\n",
        ["u", "b"],
    ),
    (
        "struct_basics",
        "p = struct('x', 3, 'y', 4);\nv = p.x + p.y;\n",
        ["v"],
    ),
    (
        "nargin_optional",
        "1;\nfunction y = inc(a, b)\n  if nargin < 2\n    b = 1;\n  end\n  y = a + b;\nend\nq = inc(5);\nr = inc(5, 10);\n",
        ["q", "r"],
    ),
]

# ── Run and write reports ─────────────────────────────────────────────────────────────────────────

outdir = joinpath(@__DIR__, "reports")
mkpath(outdir)

for (name, src, vars) in SAMPLES
    println("  $name ...")
    rep = differential_report(src, vars; anonymize = true)
    outpath = joinpath(outdir, name * ".json")
    write(outpath, JSON.json(rep, 2))
    status = isempty(rep["mismatched"]) ? "OK" : "MISMATCH ($(rep["mismatched"]))"
    println("    engine=$(rep["engine"])  $status  → $outpath")
end

println("\nDone. Share dev/reports/*.json with the maintainer (all IP-free).")
