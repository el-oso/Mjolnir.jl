# Troubleshooting

Sometimes the converted Julia doesn't run the first time. Here's how to find out why — and how to
send the problem back for a fix **without sharing your source**.

## 1. Read the to-do list first

`result.todos` is where Mjolnir tells you, in plain words, what it couldn't handle. Most "it didn't
compile" cases are explained right here:

- **`unmapped function: foo`** — Mjolnir didn't recognize `foo`, so it left the call as-is. When you
  run the code you'll see `UndefVarError: foo not defined`. Map it by hand, or include the file that
  defines it (see [Examples](examples.md), "Is anything missing?").
- **`duplicate definition of ...`** — two functions share a name and silently overwrite each other.
- **`parse error` / validity warnings** — something in the input the grammar or emitter couldn't
  handle cleanly.

```julia
r = convert_matlab(my_source)
foreach(println, r.todos)
```

## 2. Check the imports

`r.imports` lists the packages the output expects. Make sure each one is installed in the
environment where you run the result — a missing package shows up as `Package X not found` or an
`UndefVarError`.

## 3. Try to load it and read the error

```julia
m = Module()
include_string(m, r.julia)
```

The error message (and its line) points straight at the construct that's wrong.

## 4. Send it back — IP-free

This is the important part for proprietary code. [`conversion_report_json`](@ref) produces a
shareable description of the problem with **your names replaced by `id1`, `id2`, …** and literals
stripped — so you can file a Mjolnir bug without handing over the source:

```julia
using Mjolnir
write("mjolnir_report.json", conversion_report_json(my_source; check_load = true))
```

`check_load = true` goes one step further: it actually **loads the generated Julia** and records the
(scrubbed) compile error too, so the report says exactly where it broke. Attach `mjolnir_report.json`
to the issue — it carries an anonymized structure *and* a synthetic reproducer, and a maintainer can
recreate the failure locally with `replay_report` without ever seeing your code.

!!! warning "`check_load` runs the code"
    Loading executes the generated top-level code. That's harmless for function and `classdef`
    files (it just defines them), but a converted **script** will run its statements — use it on a
    safe input or in a throwaway session.
