using Mjolnir
using Documenter
using DocumenterVitepress

# Publish the idiom map straight from the registry (single source of truth — never edit by hand).
write(joinpath(@__DIR__, "src", "idioms.md"), Mjolnir.idioms_markdown())

DocMeta.setdocmeta!(Mjolnir, :DocTestSetup, :(using Mjolnir); recursive = true)

makedocs(;
    modules = [Mjolnir],
    authors = "el-oso",
    sitename = "Mjolnir.jl",
    repo = Remotes.GitHub("el-oso", "Mjolnir.jl"),
    format = DocumenterVitepress.MarkdownVitepress(;
        repo = "https://github.com/el-oso/Mjolnir.jl",
        devbranch = "main",
        devurl = "dev",
    ),
    checkdocs = :exports,
    pages = [
        "Home" => "index.md",
        "Getting started" => "getting_started.md",
        "How it works" => "guide.md",
        "Idiom map" => "idioms.md",
        "LLM refinement" => "llm.md",
        "API reference" => "api.md",
    ],
    warnonly = true,
)

deploydocs(;
    repo = "github.com/el-oso/Mjolnir.jl",
    devbranch = "main",
    push_preview = true,
)
