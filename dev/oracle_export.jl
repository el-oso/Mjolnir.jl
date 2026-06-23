# dev/oracle_export.jl — Export ORACLE_CASES / ORACLE_CLASS_CASES to a workdir for MATLAB.
#
# Usage:
#   julia --project=. dev/oracle_export.jl <workdir>
#
# Writes:
#   <workdir>/<id>.m          — the MATLAB source for each case
#   <workdir>/<ClassName>.m   — class definition files (for classdef cases)
#   <workdir>/manifest.json   — list of {id, vars, class_files} for the harness
#
# No Mjolnir package is required (raw MATLAB out only).

length(ARGS) == 1 || error("Usage: julia dev/oracle_export.jl <workdir>")
workdir = ARGS[1]
mkpath(workdir)

# Load the shared case list (no Mjolnir needed).
include(joinpath(@__DIR__, "..", "test", "oracle_cases.jl"))

using JSON

# Sanitize a case name into a valid MATLAB function/script identifier.
function make_id(name::String, idx::Int)
    # Replace non-alphanumeric characters with underscores, prefix with "case_".
    safe = replace(name, r"[^a-zA-Z0-9]" => "_")
    safe = replace(safe, r"_+" => "_")
    safe = strip(safe, '_')
    return "case_$(lpad(idx, 3, '0'))_$(safe)"
end

manifest = Dict{String, Any}[]

# ── Regular cases ─────────────────────────────────────────────────────────────────────────────────
for (idx, (name, mlab_src, vars)) in enumerate(ORACLE_CASES)
    id = make_id(name, idx)
    fpath = joinpath(workdir, "$(id).m")
    write(fpath, mlab_src)
    push!(manifest, Dict{String, Any}("id" => id, "vars" => vars, "class_files" => String[]))
end

# ── Class cases ───────────────────────────────────────────────────────────────────────────────────
base_idx = length(ORACLE_CASES)
for (idx, (classes, driver, vars)) in enumerate(ORACLE_CLASS_CASES)
    id = make_id("class_$(idx)", base_idx + idx)
    # Write each class .m file.
    class_file_names = String[]
    for (classname, src) in classes
        cf = "$(classname).m"
        write(joinpath(workdir, cf), src)
        push!(class_file_names, cf)
    end
    # Write the driver script.
    write(joinpath(workdir, "$(id).m"), driver)
    push!(
        manifest,
        Dict{String, Any}("id" => id, "vars" => vars, "class_files" => class_file_names),
    )
end

# ── Write manifest.json ───────────────────────────────────────────────────────────────────────────
manifest_path = joinpath(workdir, "manifest.json")
write(manifest_path, JSON.json(manifest, 2))

println("oracle_export: wrote $(length(manifest)) cases to $(workdir)")
println("  manifest: $(manifest_path)")
