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
        repo = "github.com/el-oso/Mjolnir.jl",
        devbranch = "main",
        devurl = "dev",
    ),
    checkdocs = :exports,
    pages = [
        "Home" => "index.md",
        "Getting started" => "getting_started.md",
        "How it works" => "guide.md",
        "Idiom map" => "idioms.md",
        "LLM refinement (experimental)" => "llm.md",
        "API reference" => "api.md",
    ],
    warnonly = true,
)

# Use DocumenterVitepress.deploydocs (NOT Documenter.deploydocs): it assembles the VitePress
# final_site and moves the numbered base folder into the version dir. Plain Documenter.deploydocs
# ships the raw build/ intermediate -> site lands in dev/1/ and the root redirect 404s.
DocumenterVitepress.deploydocs(;
    repo = "github.com/el-oso/Mjolnir.jl",
    devbranch = "main",
    push_preview = true,
)
