# API reference

```@meta
CurrentModule = Mjolnir
```

```@index
```

## Module

```@docs
Mjolnir
```

## Conversion

```@docs
convert_matlab
convert_file
convert_project
ConvertResult
```

## Parsing

```@docs
parse_matlab
parse_file
MatlabCST
CSTNode
sexpr
nodetext
walk
findkind
children
```

## Idiom registry

```@docs
Idiom
idioms
idioms_json
idioms_markdown
write_idioms
idiom_builtin_gaps
```

## LLM refinement

```@docs
LLMBackend
FunctionBackend
ManualBackend
SubprocessBackend
HTTPBackend
claude_backend
ollama_backend
refine
gated_refine
verify_equivalent
extract_code
```
