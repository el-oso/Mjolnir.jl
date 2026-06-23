"""
    Mjolnir

A source-level MATLAB → idiomatic-Julia converter, written in Julia.

Pipeline: Parse → Resolve → Lower → Idiomatic passes → (optional, gated LLM refine) →
Emit → Package assembly. The tree-sitter runtime and MATLAB grammar come from JLL
artifacts, so there is no build step — `using Mjolnir` works after `Pkg.instantiate`.

Start with [`convert_matlab`](@ref) / [`convert_file`](@ref) / [`convert_project`](@ref).
When output misbehaves, [`conversion_report`](@ref) builds an IP-free bug report and
[`audit_project`](@ref) finds functions the source calls but never defines.
"""
module Mjolnir

# The tree-sitter runtime and the MATLAB grammar both come from the Julia artifact ecosystem
# (JLLs from Yggdrasil), so there is no build step, no system `libtree-sitter`, and no grammar/
# runtime ABI mismatch — the two JLLs are version-coordinated upstream.
using tree_sitter_jll, tree_sitter_matlab_jll
const LIBTREESITTER = tree_sitter_jll.libtreesitter
const LIBTREESITTER_MATLAB = tree_sitter_matlab_jll.libtreesitter_matlab
const GRAMMAR_REV = "tree_sitter_matlab_jll"

include("parse.jl")
include("builtins.jl")
include("lower.jl")
include("idiomatic.jl")
include("emit.jl")
include("assemble.jl")
include("llm.jl")
include("idioms.jl")
include("report.jl")
include("oracle.jl")
include("audit.jl")

export parse_matlab, parse_file, sexpr
export MatlabCST, CSTNode, nodetext, walk, findkind, children
export convert_matlab, convert_file, ConvertResult, convert_project
export LLMBackend, FunctionBackend, ManualBackend, SubprocessBackend, HTTPBackend
export claude_backend, ollama_backend, refine, gated_refine, verify_equivalent, extract_code
export Idiom, idioms, idioms_json, idioms_markdown, write_idioms, idiom_builtin_gaps
export conversion_report, conversion_report_json, replay_report, audit_project
export octave_available, matlab_available, available_engines
export differential_report, differential_report_json

end # module Mjolnir
