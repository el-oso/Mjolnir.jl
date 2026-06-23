"""
    Mjolnir

A source-level MATLAB → idiomatic-Julia converter, written in Julia.

Pipeline (built incrementally): Parse → Resolve → Lower → Idiomatic passes →
(optional, gated LLM refine) → Emit → Package assembly.

This release implements **Stage 1 — Parse**: a tree-sitter front-end (C FFI, no Python)
that turns MATLAB source into a concrete syntax tree ([`MatlabCST`]).

Run `deps/build.jl` once before using (compiles the MATLAB grammar):

    julia> import Mjolnir
    julia> include(joinpath(pkgdir(Mjolnir), "deps", "build.jl"))
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
include("audit.jl")

export parse_matlab, parse_file, sexpr
export MatlabCST, CSTNode, nodetext, walk, findkind, children
export convert_matlab, convert_file, ConvertResult, convert_project
export LLMBackend, FunctionBackend, ManualBackend, SubprocessBackend, HTTPBackend
export claude_backend, ollama_backend, refine, gated_refine, verify_equivalent, extract_code
export Idiom, idioms, idioms_json, idioms_markdown, write_idioms, idiom_builtin_gaps
export conversion_report, conversion_report_json, replay_report, audit_project

end # module Mjolnir
