
# LLM refinement (optional, gated) {#LLM-refinement-optional,-gated}

Mjolnir's deterministic passes produce correct, reasonably idiomatic Julia on their own. An **optional** stage can ask an LLM to polish a unit further — but the result is **refactor-only and gated**: a candidate is accepted only if it is proven behaviorally equivalent to the deterministic baseline. Behavior never changes silently.

```julia
backend = ollama_backend(; model = "qwen2.5-coder")   # or claude_backend(...)
polished = gated_refine(backend, baseline_julia; probes = my_probes)
```


If `gated_refine` cannot verify equivalence (via [`verify_equivalent`](/api#Mjolnir.verify_equivalent)), it discards the candidate and returns the deterministic baseline unchanged.

## Backends {#Backends}

All backends implement the [`LLMBackend`](/api#Mjolnir.LLMBackend) interface:
- [`HTTPBackend`](/api#Mjolnir.HTTPBackend) — Anthropic Messages API (direct Claude) or any OpenAI-compatible endpoint, including a local **Ollama** server (`claude_backend`, `ollama_backend`).
  
- [`SubprocessBackend`](/api#Mjolnir.SubprocessBackend) — a local CLI / `llama.cpp` process.
  
- [`ManualBackend`](/api#Mjolnir.ManualBackend) — export prompt artifacts and ingest responses (e.g. the Copilot path).
  
- [`FunctionBackend`](/api#Mjolnir.FunctionBackend) — wrap any `String -> String` function (useful in tests).
  

See the [API reference](api.md) for the full surface.
