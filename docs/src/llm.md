# LLM refinement (optional, gated)

Mjolnir's deterministic passes produce correct, reasonably idiomatic Julia on their own. An
**optional** stage can ask an LLM to polish a unit further — but the result is **refactor-only and
gated**: a candidate is accepted only if it is proven behaviorally equivalent to the deterministic
baseline. Behavior never changes silently.

```julia
backend = ollama_backend(; model = "qwen2.5-coder")   # or claude_backend(...)
polished = gated_refine(backend, baseline_julia; probes = my_probes)
```

If `gated_refine` cannot verify equivalence (via [`verify_equivalent`](@ref)), it discards the
candidate and returns the deterministic baseline unchanged.

## Backends

All backends implement the [`LLMBackend`](@ref) interface:

- [`HTTPBackend`](@ref) — Anthropic Messages API (direct Claude) or any OpenAI-compatible endpoint,
  including a local **Ollama** server (`claude_backend`, `ollama_backend`).
- [`SubprocessBackend`](@ref) — a local CLI / `llama.cpp` process.
- [`ManualBackend`](@ref) — export prompt artifacts and ingest responses (e.g. the Copilot path).
- [`FunctionBackend`](@ref) — wrap any `String -> String` function (useful in tests).

See the [API reference](api.md) for the full surface.
