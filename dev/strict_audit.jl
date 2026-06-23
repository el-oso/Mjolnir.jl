#!/usr/bin/env julia
# dev/strict_audit.jl
#
# Usage:  julia --project=dev dev/strict_audit.jl [<corpus-dir> ...]
#
# Without arguments, scans all standard /tmp corpora.
# Produces a two-tier report:
#   (a) Static scan: weak-idiom markers in converted Julia
#   (b) Dynamic StrictMode: type-stability/allocation verdicts on oracle kernels
#
# Saves the full markdown report to /tmp/mjolnir_audit_report.md

# --- setup -------------------------------------------------------------------

using Dates

# Allow running as `julia --project=test dev/strict_audit.jl`
using Mjolnir

# StrictMode + backends are optional — gracefully absent in the package env
const HAS_STRICTMODE = try
    @eval using StrictMode, AllocCheck, JET
    true
catch
    false
end

# --------------------------------------------------------------------------- #
#  PART (a) — STATIC SCAN                                                     #
# --------------------------------------------------------------------------- #

"""Scan a block of converted Julia text for weak-idiom markers.
Returns a NamedTuple of counts."""
function scan_markers(julia_text::AbstractString)
    any_vec = count(r"Any\[", julia_text)
    array_any = count(r"Array\{Any\}", julia_text)
    vector_any = count(r"Vector\{Any\}", julia_text)
    # untyped classdef struct: `mutable struct Foo` without a `{`on the same line
    untyped_struct = count(r"mutable struct [A-Za-z_][A-Za-z0-9_]*\b(?!.*\{)", julia_text)
    max_size = count(r"maximum\(size\(", julia_text)
    stray_bcast = count(r"\d+\s*\.\+\s*\d+|\d+\s*\.\-\s*\d+", julia_text)
    unmapped = count(r"unmapped function:", julia_text)
    duplicate = count(r"duplicate definition", julia_text)
    return (;
        any_vec, array_any, vector_any, untyped_struct,
        max_size, stray_bcast, unmapped, duplicate,
    )
end

struct FileResult
    path::String
    julia_text::String
    markers::NamedTuple
    error::Union{Nothing, String}
end

"""Scan all .m files under `dir`. Returns (results, n_failed)."""
function scan_dir(dir::AbstractString; max_files::Int = typemax(Int))
    m_files = String[]
    for (root, _, files) in walkdir(dir)
        for f in files
            endswith(f, ".m") && push!(m_files, joinpath(root, f))
        end
    end
    sort!(m_files)
    if length(m_files) > max_files
        m_files = m_files[1:max_files]
    end

    results = FileResult[]
    n_failed = 0
    for path in m_files
        try
            src = read(path, String)
            cr = convert_file(path)
            jtext = cr.julia
            mkrs = scan_markers(jtext)
            push!(results, FileResult(path, jtext, mkrs, nothing))
        catch e
            n_failed += 1
            push!(
                results, FileResult(
                    path, "", (;
                        any_vec = 0, array_any = 0, vector_any = 0, untyped_struct = 0,
                        max_size = 0, stray_bcast = 0, unmapped = 0, duplicate = 0,
                    ), sprint(showerror, e)
                )
            )
        end
    end
    return results, n_failed
end

"""Aggregate marker totals across FileResults."""
function aggregate_markers(results::Vector{FileResult})
    tot = Dict{Symbol, Int}()
    for r in results
        for (k, v) in pairs(r.markers)
            tot[k] = get(tot, k, 0) + v
        end
    end
    return tot
end

"""Return up to `n` files with highest combined marker count."""
function worst_offenders(results::Vector{FileResult}, n::Int = 5)
    scored = [(sum(values(r.markers)), r) for r in results if r.error === nothing]
    sort!(scored; by = first, rev = true)
    return [r for (_, r) in scored[1:min(n, length(scored))]]
end

# --------------------------------------------------------------------------- #
#  PART (b) — DYNAMIC STRICTMODE AUDIT                                        #
# --------------------------------------------------------------------------- #

"""
A curated kernel definition: the MATLAB source for the function, plus representative
concrete argument types for the dynamic check.
"""
struct KernelSpec
    name::String
    matlab_src::String
    arg_types::Tuple  # concrete types for StrictMode
    call_args::Vector  # actual values for the call
end

"""Curated kernels derived from the Octave-oracle fixtures (clear signatures + numeric inputs)."""
const ORACLE_KERNELS = KernelSpec[
    KernelSpec(
        "scalar_hypot",
        """
        function c = scalar_hypot(a, b)
          c = sqrt(a^2 + b^2);
        end
        """,
        (Float64, Float64),
        [3.0, 4.0],
    ),
    KernelSpec(
        "accumulator_sum",
        """
        function s = accumulator_sum(v)
          s = 0;
          for i = 1:numel(v)
            s = s + v(i);
          end
        end
        """,
        (Vector{Float64},),
        [[1.0, 2.0, 3.0, 4.0]],
    ),
    KernelSpec(
        "vector_norm",
        """
        function n = vector_norm(v)
          n = sqrt(sum(v .* v));
        end
        """,
        (Vector{Float64},),
        [[3.0, 4.0]],
    ),
    KernelSpec(
        "safe_divide",
        """
        function y = safe_divide(a, b)
          if b == 0
            y = 0;
          else
            y = a / b;
          end
        end
        """,
        (Float64, Float64),
        [10.0, 2.0],
    ),
    KernelSpec(
        "count_above",
        """
        function n = count_above(v, thr)
          n = sum(v > thr);
        end
        """,
        (Vector{Float64}, Float64),
        [[1.0, 5.0, 3.0, 7.0], 4.0],
    ),
    KernelSpec(
        "dot_product",
        """
        function d = dot_product(a, b)
          d = 0;
          for i = 1:numel(a)
            d = d + a(i) * b(i);
          end
        end
        """,
        (Vector{Float64}, Vector{Float64}),
        [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]],
    ),
    KernelSpec(
        "running_max",
        """
        function m = running_max(v)
          m = v(1);
          for i = 2:numel(v)
            if v(i) > m
              m = v(i);
            end
          end
        end
        """,
        (Vector{Float64},),
        [[3.0, 1.0, 4.0, 1.0, 5.0, 9.0]],
    ),
    KernelSpec(
        "linspace_sum",
        """
        function s = linspace_sum(n)
          p = linspace(0, 1, n);
          s = sum(p);
        end
        """,
        (Int64,),
        [5],
    ),
]

struct KernelVerdict
    name::String
    julia_src::String
    typestable::Union{Bool, Nothing}  # nothing = could not check
    allocates::Union{Bool, Nothing}
    ts_reason::String
    alloc_reason::String
    error::Union{Nothing, String}
end

"""Convert, load into a fresh Module, then run StrictMode checks."""
function audit_kernel(spec::KernelSpec)::KernelVerdict
    local jl_src, fn
    try
        cr = convert_matlab(spec.matlab_src)
        jl_src = cr.julia

        m = Module(Symbol("AuditKernel_$(spec.name)"))
        Base.eval(m, :(using LinearAlgebra))
        Base.include_string(m, jl_src)
        fn = getfield(m, Symbol(spec.name))
    catch e
        return KernelVerdict(spec.name, "", nothing, nothing, "", "", sprint(showerror, e))
    end

    if !HAS_STRICTMODE
        return KernelVerdict(spec.name, jl_src, nothing, nothing, "(StrictMode not loaded)", "(StrictMode not loaded)", nothing)
    end

    # Type-stability + allocation checks together
    typestable = nothing
    allocates = nothing
    ts_reason = ""
    alloc_reason = ""
    try
        fs = StrictMode.check(fn, spec.arg_types; guarantees = (:typestable, :noalloc), fail = :none)
        for f in fs
            if f.guarantee === :typestable
                typestable = f.status === :pass
                ts_reason = f.status === :pass ? "ok" : f.reason
            elseif f.guarantee === :noalloc
                allocates = f.status === :fail
                alloc_reason = f.status === :pass ? "ok" : f.reason
            end
        end
    catch e
        ts_reason = "check error: $(sprint(showerror, e))"
        alloc_reason = ts_reason
    end

    return KernelVerdict(spec.name, jl_src, typestable, allocates, ts_reason, alloc_reason, nothing)
end

# --------------------------------------------------------------------------- #
#  REPORT FORMATTING                                                           #
# --------------------------------------------------------------------------- #

function format_report(
        domain_results::Vector{Tuple{String, String, Vector{FileResult}, Int}},
        kernel_verdicts::Vector{KernelVerdict},
    )::String
    io = IOBuffer()

    println(io, "# Mjolnir Idiom Audit Report")
    println(io)
    println(io, "Generated: $(Dates.now())")
    println(io, "StrictMode available: $HAS_STRICTMODE")
    println(io)

    # ---- STATIC SCAN ---------------------------------------------------------
    println(io, "## Part A — Static Scan (Weak-Idiom Markers)")
    println(io)
    println(io, "Markers detected in converted Julia text:")
    println(io, "- `Any[` — non-concrete cell/container")
    println(io, "- `Array{Any}` / `Vector{Any}` — untyped array types")
    println(io, "- untyped `mutable struct` (classdef fallback, no type params)")
    println(io, "- `maximum(size(` — leftover MATLAB `length` idiom")
    println(io, "- stray scalar broadcast (digit `.+` digit)")
    println(io, "- `unmapped function:` / `duplicate definition` todos")
    println(io)

    println(io, "| Domain | Dir | Files | Failed | Any[ | Array{Any} | Vector{Any} | UntypedStruct | MaxSize | StrayBcast | Unmapped | Duplicate |")
    println(io, "|--------|-----|-------|--------|------|------------|-------------|---------------|---------|------------|----------|-----------|")

    total_markers = Dict{Symbol, Int}()
    total_files = 0
    total_failed = 0

    for (domain, dir, results, n_failed) in domain_results
        ag = aggregate_markers(results)
        nf = length(results)
        total_files += nf
        total_failed += n_failed
        for (k, v) in ag
            total_markers[k] = get(total_markers, k, 0) + v
        end
        short_dir = length(dir) > 30 ? "...$(dir[(end - 27):end])" : dir
        println(io, "| $(rpad(domain, 12)) | `$short_dir` | $nf | $n_failed | $(get(ag, :any_vec, 0)) | $(get(ag, :array_any, 0)) | $(get(ag, :vector_any, 0)) | $(get(ag, :untyped_struct, 0)) | $(get(ag, :max_size, 0)) | $(get(ag, :stray_bcast, 0)) | $(get(ag, :unmapped, 0)) | $(get(ag, :duplicate, 0)) |")
    end

    println(io, "| **TOTAL** | — | **$total_files** | **$total_failed** | **$(get(total_markers, :any_vec, 0))** | **$(get(total_markers, :array_any, 0))** | **$(get(total_markers, :vector_any, 0))** | **$(get(total_markers, :untyped_struct, 0))** | **$(get(total_markers, :max_size, 0))** | **$(get(total_markers, :stray_bcast, 0))** | **$(get(total_markers, :unmapped, 0))** | **$(get(total_markers, :duplicate, 0))** |")
    println(io)

    # worst offenders across all domains
    all_results = [r for (_, _, rs, _) in domain_results for r in rs]
    worst = worst_offenders(all_results, 8)
    if !isempty(worst)
        println(io, "### Top Offenders (most markers per file)")
        println(io)
        println(io, "| File | Any[ | Array{Any} | Vector{Any} | UntypedStruct | MaxSize | Unmapped |")
        println(io, "|------|------|------------|-------------|---------------|---------|----------|")
        for r in worst
            m = r.markers
            short_path = length(r.path) > 50 ? "...$(r.path[(end - 47):end])" : r.path
            println(io, "| `$short_path` | $(m.any_vec) | $(m.array_any) | $(m.vector_any) | $(m.untyped_struct) | $(m.max_size) | $(m.unmapped) |")
        end
        println(io)

        # Show a snippet from the top offender
        top = worst[1]
        println(io, "#### Example from top offender: `$(basename(top.path))`")
        println(io)
        snippet = join(split(top.julia_text, '\n')[1:min(20, end)], '\n')
        println(io, "```julia")
        println(io, snippet)
        println(io, "```")
        println(io)
    end

    # ---- DYNAMIC STRICTMODE --------------------------------------------------
    println(io, "## Part B — Dynamic StrictMode Audit (Oracle Kernels)")
    println(io)

    if !HAS_STRICTMODE
        println(io, "> StrictMode not loaded — skipping dynamic checks.")
        println(io, "> Add `using StrictMode, AllocCheck, JET` to enable.")
        println(io)
    end

    println(io, "| Kernel | Convert OK | TypeStable | Allocates | TS Reason | Alloc Reason |")
    println(io, "|--------|------------|------------|-----------|-----------|--------------|")
    for v in kernel_verdicts
        conv_ok = v.error === nothing ? "yes" : "NO: $(v.error[1:min(50, end)])"
        ts = v.typestable === nothing ? "?" : (v.typestable ? "yes" : "**NO**")
        alloc = v.allocates === nothing ? "?" : (v.allocates ? "**YES**" : "no")
        ts_r = length(v.ts_reason) > 60 ? v.ts_reason[1:57] * "…" : v.ts_reason
        alloc_r = length(v.alloc_reason) > 60 ? v.alloc_reason[1:57] * "…" : v.alloc_reason
        println(io, "| `$(v.name)` | $conv_ok | $ts | $alloc | $ts_r | $alloc_r |")
    end
    println(io)

    # Detail for any unstable kernels
    unstable = filter(v -> v.typestable === false || v.allocates === true, kernel_verdicts)
    if !isempty(unstable)
        println(io, "### Unstable / allocating kernels — detail")
        println(io)
        for v in unstable
            println(io, "#### `$(v.name)`")
            println(io)
            println(io, "**Type-stable:** $(v.typestable === nothing ? "unknown" : v.typestable)")
            println(io, "**Reason:** $(v.ts_reason)")
            println(io, "**Allocates:** $(v.allocates === nothing ? "unknown" : v.allocates)")
            println(io, "**Alloc reason:** $(v.alloc_reason)")
            println(io)
            if !isempty(v.julia_src)
                println(io, "Converted Julia:")
                println(io, "```julia")
                println(io, v.julia_src)
                println(io, "```")
            end
            println(io)
        end
    end

    # ---- SUMMARY / TOP-5 FINDINGS -------------------------------------------
    println(io, "## Summary: Top-5 Highest-Value Idiom Problems")
    println(io)

    # Build ranking from marker totals
    findings = [
        (
            :any_vec, "Non-concrete cell containers `Any[…]`",
            "MATLAB `{}` cell arrays always become `Any[…]` even when elements are homogeneous numbers. The `_narrow_cells` pass handles literal homogeneous cases but misses variables that are assigned then indexed. Each `Any[…]` blocks type inference on every downstream access.",
        ),
        (
            :array_any, "Untyped `Array{Any}(undef, …)` for `cell(n)` allocation",
            "`cell(n)` / `cell(m,n)` in MATLAB allocates an Any-typed array. Mjolnir correctly emits `Array{Any}(undef,…)` but this can often be narrowed if the subsequent fill pattern is homogeneous.",
        ),
        (
            :untyped_struct, "Untyped `mutable struct` classdef fallback",
            "When `_try_parametric` cannot prove a simple assignment-only constructor, it falls back to an untyped `mutable struct Foo` with `Any`-typed fields. Every field access becomes a runtime dispatch — typically 2–5× slower.",
        ),
        (
            :max_size, "Residual `maximum(size(…))` chains",
            "MATLAB `length(A)` = max dimension is lowered to `maximum(size(A))` by a semantic pass. For 1-D vectors proven at call-site this can become `length(A)` directly.",
        ),
        (
            :unmapped, "Unmapped toolbox functions recorded as todos",
            "Functions like `ode45`, `fzero`, `quadgk` etc. that do not have Julia equivalents in Mjolnir's builtin table pass through as plain calls and are flagged as todos. They will cause `UndefVarError` at runtime.",
        ),
    ]
    # sort by total count desc
    sort!(findings; by = f -> get(total_markers, f[1], 0), rev = true)

    for (rank, (key, title, desc)) in enumerate(findings[1:5])
        count_val = get(total_markers, key, 0)
        println(io, "### $(rank). $(title) — $(count_val) occurrences")
        println(io)
        println(io, desc)
        println(io)
        # Find a concrete example
        example_file = nothing
        for r in all_results
            r.error === nothing || continue
            v = getfield(r.markers, key)
            v > 0 || continue
            example_file = r
            break
        end
        if example_file !== nothing
            println(io, "**Example file:** `$(basename(example_file.path))`")
            # Find the relevant line
            for line in split(example_file.julia_text, '\n')
                pattern = key == :any_vec ? r"Any\[" :
                    key == :array_any ? r"Array\{Any\}" :
                    key == :vector_any ? r"Vector\{Any\}" :
                    key == :untyped_struct ? r"mutable struct " :
                    key == :max_size ? r"maximum\(size\(" :
                    key == :unmapped ? r"unmapped function:" :
                    r"duplicate definition"
                if occursin(pattern, line)
                    println(io, "```julia")
                    println(io, strip(line))
                    println(io, "```")
                    break
                end
            end
            println(io)
        end
    end

    return String(take!(io))
end

# --------------------------------------------------------------------------- #
#  MAIN                                                                        #
# --------------------------------------------------------------------------- #

function main()
    # Default corpus dirs
    default_dirs = [
        ("cheb", "/tmp/cheb"),
        ("fem", "/tmp/fem"),
        ("ml", "/tmp/ml"),
        ("dsp", "/tmp/dsp"),
        ("opt", "/tmp/opt"),
        ("nm-matlab", "/tmp/nm-matlab"),
        ("jsonlab", "/tmp/jsonlab"),
        ("bio", "/tmp/bio"),
        ("ctrl", "/tmp/ctrl"),
        ("mip", "/tmp/mip"),
        ("oop", "/tmp/oop"),
        ("odeprobe", "/tmp/odeprobe"),
        ("nw-bio", "/tmp/ATalhaTimur_Needleman-Wunsch-Algorithm"),
        ("dna-bio", "/tmp/DulanDias_DNA-Sequence-Alignment"),
        ("bioseq", "/tmp/AhmadAymanBahaa_Bioinformatics"),
    ]

    # Allow passing dirs on command line as dir args; else use defaults
    cli_dirs = ARGS
    if !isempty(cli_dirs)
        corpus = [(basename(d), d) for d in cli_dirs]
    else
        corpus = [(name, dir) for (name, dir) in default_dirs if isdir(dir)]
    end

    if isempty(corpus)
        @warn "No corpus directories found. Pass dirs as arguments or populate /tmp."
        return
    end

    println("Mjolnir Idiom Audit — $(Dates.now())")
    println("Scanning $(length(corpus)) domain(s)…")
    println()

    # --- Static scan ----------------------------------------------------------
    domain_results = Tuple{String, String, Vector{FileResult}, Int}[]

    for (domain, dir) in corpus
        m_count = 0
        for (_, _, fs) in walkdir(dir)
            m_count += count(f -> endswith(f, ".m"), fs)
        end
        # Cap to 200 per domain to keep runtime reasonable; cheb has 3400+ files
        cap = 200
        print("  [$domain] $m_count .m files (scanning up to $cap)… ")
        flush(stdout)
        results, n_failed = scan_dir(dir; max_files = cap)
        ag = aggregate_markers(results)
        total_issues = sum(values(ag))
        println("$n_failed failed, $total_issues markers")
        push!(domain_results, (domain, dir, results, n_failed))
    end

    println()
    println("Running dynamic StrictMode audit on $(length(ORACLE_KERNELS)) oracle kernels…")
    kernel_verdicts = KernelVerdict[]
    for spec in ORACLE_KERNELS
        print("  [$(spec.name)]… ")
        flush(stdout)
        v = audit_kernel(spec)
        if v.error !== nothing
            println("CONVERT ERROR: $(v.error[1:min(80, end)])")
        elseif v.typestable === nothing
            println("skipped (no StrictMode)")
        else
            ts_str = v.typestable ? "stable" : "UNSTABLE"
            alloc_str = v.allocates ? "ALLOCATES" : "no-alloc"
            println("$ts_str, $alloc_str")
        end
        push!(kernel_verdicts, v)
    end

    println()
    println("Formatting report…")
    report = format_report(domain_results, kernel_verdicts)

    out_path = "/tmp/mjolnir_audit_report.md"
    write(out_path, report)
    println("Saved to $out_path")
    println()
    return println(report)
end

main()
