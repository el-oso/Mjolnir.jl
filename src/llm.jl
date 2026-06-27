# Optional LLM refinement layer (Stage 5).
#
# The deterministic core already emits correct, oracle-validated Julia. This layer can polish a
# unit toward more idiomatic Julia, but it is **refactor-only and gated**: a candidate from any
# backend is accepted only if it is behaviorally equivalent to the deterministic baseline on a
# set of probe expressions. Otherwise the baseline is kept. The LLM can never silently change
# behavior. No Python: HTTP via `Downloads` (stdlib), local models via a subprocess.

import Downloads
import JSON

# ---------------------------------------------------------------------------------------
# Backends
# ---------------------------------------------------------------------------------------

"""
    LLMBackend

Abstract supertype for optional LLM refinement backends. Concrete subtypes
([`HTTPBackend`](@ref), [`SubprocessBackend`](@ref), [`ManualBackend`](@ref),
[`FunctionBackend`](@ref)) implement [`refine`](@ref). Refinement is always **gated**: use
[`gated_refine`](@ref), which keeps a candidate only if [`verify_equivalent`](@ref) proves it
matches the deterministic baseline.
"""
abstract type LLMBackend end

"`complete(backend, prompt; system)` -> raw model text. Implemented per backend."
function complete end

"In-process backend wrapping `f(prompt)::String` — used for testing and custom integrations."
struct FunctionBackend <: LLMBackend
    f::Function
end
complete(b::FunctionBackend, prompt::AbstractString; system::AbstractString = "") = b.f(prompt)

"""
Manual round-trip backend — the path for **Claude via Copilot in VSCode** (not scriptable):
writes the prompt to `promptfile`, expects the model response in `responsefile`.
"""
struct ManualBackend <: LLMBackend
    promptfile::String
    responsefile::String
end
function complete(b::ManualBackend, prompt::AbstractString; system::AbstractString = "")
    write(b.promptfile, system, "\n\n", prompt)
    isfile(b.responsefile) ||
        error("ManualBackend: paste the model response into $(b.responsefile), then retry")
    return read(b.responsefile, String)
end

"""
Subprocess backend for a local CLI (e.g. llama.cpp / a Tonalli runner). `cmd` receives the
prompt on stdin and writes the completion to stdout.
"""
struct SubprocessBackend <: LLMBackend
    cmd::Cmd
end
function complete(b::SubprocessBackend, prompt::AbstractString; system::AbstractString = "")
    out = IOBuffer()
    run(pipeline(b.cmd; stdin = IOBuffer(string(system, "\n\n", prompt)), stdout = out))
    return String(take!(out))
end

"""
HTTP backend for an Anthropic- or OpenAI-compatible chat endpoint. Covers **Claude** directly
and a local **Ollama** server (OpenAI-compatible). See [`claude_backend`] / [`ollama_backend`].
"""
struct HTTPBackend <: LLMBackend
    url::String
    model::String
    api_key::String
    kind::Symbol                      # :anthropic or :openai
    max_tokens::Int
end

"Claude (Anthropic Messages API). `api_key` defaults to the ANTHROPIC_API_KEY env var."
claude_backend(;
    model = "claude-opus-4-8", api_key = get(ENV, "ANTHROPIC_API_KEY", ""),
    url = "https://api.anthropic.com/v1/messages", max_tokens = 4096
) =
    HTTPBackend(url, model, api_key, :anthropic, max_tokens)

"Local Ollama server (OpenAI-compatible chat endpoint)."
ollama_backend(;
    model = "julia-expert-v6", url = "http://localhost:11434/v1/chat/completions",
    api_key = "", max_tokens = 4096
) =
    HTTPBackend(url, model, api_key, :openai, max_tokens)

function complete(b::HTTPBackend, prompt::AbstractString; system::AbstractString = "")
    if b.kind === :anthropic
        body = Dict(
            "model" => b.model, "max_tokens" => b.max_tokens, "system" => system,
            "messages" => [Dict("role" => "user", "content" => prompt)]
        )
        headers = [
            "x-api-key" => b.api_key, "anthropic-version" => "2023-06-01",
            "content-type" => "application/json",
        ]
    else
        msgs = isempty(system) ? [Dict("role" => "user", "content" => prompt)] :
            [Dict("role" => "system", "content" => system), Dict("role" => "user", "content" => prompt)]
        body = Dict("model" => b.model, "max_tokens" => b.max_tokens, "messages" => msgs)
        headers = ["content-type" => "application/json"]
        isempty(b.api_key) || push!(headers, "authorization" => "Bearer $(b.api_key)")
    end
    out = IOBuffer()
    Downloads.request(
        b.url; method = "POST", headers = headers,
        input = IOBuffer(JSON.json(body)), output = out
    )
    resp = JSON.parse(String(take!(out)))
    return b.kind === :anthropic ? resp["content"][1]["text"] :
        resp["choices"][1]["message"]["content"]
end

# ---------------------------------------------------------------------------------------
# Prompting & extraction
# ---------------------------------------------------------------------------------------

const REFINE_SYSTEM = "You are an expert Julia engineer. You refactor MATLAB-transpiled Julia \
into idiomatic Julia. You must preserve behavior exactly; only change style. Reply with a \
single ```julia code block and nothing else."

_refine_prompt(code) = string(
    "Rewrite this Julia code to be more idiomatic without changing its behavior:\n\n",
    "```julia\n", code, "\n```",
)

"Extract the first ```julia fenced block (or the trimmed whole text if none)."
function extract_code(s::AbstractString)
    m = match(r"```(?:julia)?\s*\n(.*?)```"s, s)
    return m === nothing ? strip(s) : strip(m.captures[1])
end

"Ask `backend` to refine `code`; returns candidate source (not yet gated)."
function refine(backend::LLMBackend, code::AbstractString; system::AbstractString = REFINE_SYSTEM)
    return extract_code(complete(backend, _refine_prompt(code); system))
end

# ---------------------------------------------------------------------------------------
# Equivalence gate
# ---------------------------------------------------------------------------------------

_approx(a::Number, b::Number; atol, rtol) = isapprox(a, b; atol, rtol)
_approx(a::AbstractArray, b::AbstractArray; atol, rtol) =
    size(a) == size(b) && all(isapprox.(a, b; atol, rtol))
_approx(a, b; atol, rtol) = isequal(a, b)

function _eval_probes(code::AbstractString, probes)
    m = Module()
    Base.include_string(m, code)
    return [Core.eval(m, Meta.parse(p)) for p in probes]
end

"""
    verify_equivalent(baseline, candidate, probes; atol, rtol) -> Bool

True if `candidate` reproduces `baseline` on every probe expression (e.g. `"f(2)"`, `"f(3.5)"`)
evaluated in a fresh module. A candidate that errors or disagrees is not equivalent.
"""
function verify_equivalent(baseline, candidate, probes; atol = 1.0e-9, rtol = 1.0e-7)
    isempty(probes) && return false                      # nothing to verify -> cannot accept
    bvals = try
        _eval_probes(baseline, probes)
    catch
        return false
    end
    cvals = try
        _eval_probes(candidate, probes)
    catch
        return false
    end
    return all(_approx(b, c; atol, rtol) for (b, c) in zip(bvals, cvals))
end

"""
    gated_refine(backend, baseline; probes, kwargs...) -> (; code, accepted)

Refine `baseline` with `backend`, then accept the candidate **only if** it is behaviorally
equivalent to `baseline` on `probes`; otherwise return `baseline` unchanged. Any backend/parse
error falls back to the baseline. This is the guarantee: refinement never changes behavior.
"""
function gated_refine(backend::LLMBackend, baseline::AbstractString; probes, kwargs...)
    cand = try
        refine(backend, baseline; kwargs...)
    catch
        return (code = baseline, accepted = false)
    end
    if verify_equivalent(baseline, cand, probes)
        return (code = cand, accepted = true)
    end
    return (code = baseline, accepted = false)
end

# ---------------------------------------------------------------------------------------
# Auto-probe generation
# ---------------------------------------------------------------------------------------

const _COMPLEX_TYPES = Set(
    [
        :Vector, :Array, :Matrix, :Dict, :Set, :Tuple,
        :AbstractArray, :AbstractVector, :AbstractMatrix,
        :AbstractDict, :AbstractSet, :IO, :IOStream, :Channel,
    ]
)

_is_complex_type(::Any) = false
_is_complex_type(t::Symbol) = t in _COMPLEX_TYPES
_is_complex_type(t::Expr) = t.head === :curly || any(_is_complex_type, t.args)

_type_vals(::Nothing) = ["1", "2", "3"]
_type_vals(::Expr) = ["1", "2", "3"]
_type_vals(t::Symbol) =
    t in (:Float64, :Float32, :AbstractFloat, :Real) ? ["1.0", "2.5", "-1.0"] :
    t in (:String, :AbstractString) ? ["\"hello\"", "\"abc\""] :
    t === :Bool ? ["true", "false"] :
    ["1", "2", "3"]

function _probes_for_func(name::Symbol, params::Vector, n::Int)
    isempty(params) && return ["$name()"]
    types = map(p -> (p isa Expr && p.head === :(::) && length(p.args) >= 2) ? p.args[2] : nothing, params)
    any(_is_complex_type, filter(!isnothing, types)) && return String[]
    any(p -> p isa Expr && p.head === :(...), params) && return String[]
    vals = _type_vals.(types)
    return ["$name($(join([v[min(i, length(v))] for v in vals], ", ")))" for i in 1:n]
end

"""
    auto_probes(code; n=3) -> Vector{String}

Inspect the Julia `code` string and return up to `n` probe expressions per
top-level function definition (and one per module-level scalar assignment).
Probe expressions can be passed directly to [`gated_refine`](@ref):

```julia
gated_refine(backend, code; probes = auto_probes(code))
```

Returns `String[]` on parse errors or when no safe probes can be derived
(e.g. all functions take array arguments). An empty result causes
`gated_refine` to reject — the conservative safe outcome.
"""
function auto_probes(code::AbstractString; n::Int = 3)::Vector{String}
    top = try
        Meta.parse("begin\n$code\nend")
    catch
        return String[]
    end
    probes = String[]
    stmts = (top isa Expr && top.head === :block) ? top.args : [top]
    for stmt in stmts
        stmt isa Expr || continue
        sig = if stmt.head === :function
            stmt.args[1]
        elseif stmt.head === :(=) && stmt.args[1] isa Expr && stmt.args[1].head === :call
            stmt.args[1]
        else
            nothing
        end
        if sig !== nothing
            (sig isa Expr && sig.head === :call) || continue
            name = sig.args[1]
            name isa Symbol || continue
            params = filter!(p -> !(p isa LineNumberNode), copy(sig.args[2:end]))
            append!(probes, _probes_for_func(name, params, n))
            continue
        end
        inner = stmt.head === :const ? stmt.args[1] : stmt
        if inner isa Expr && inner.head === :(=) && inner.args[1] isa Symbol
            push!(probes, string(inner.args[1]))
        end
    end
    return unique(probes)
end
