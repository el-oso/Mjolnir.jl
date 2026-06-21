# MATLAB front-end: tree-sitter (via C FFI) -> Mjolnir concrete syntax tree (MatlabCST).
#
# Stage 1 of the pipeline. No Python: the parser is the C tree-sitter runtime plus the
# compiled MATLAB grammar, driven entirely through `ccall`.

# ---------------------------------------------------------------------------------------
# tree-sitter FFI
# ---------------------------------------------------------------------------------------

# Mirror of C `TSNode` (tree_sitter/api.h): {uint32_t context[4]; const void *id; const Tree *tree;}
# isbits, so it round-trips through ccall by value matching the C ABI.
struct TSNode
    context::NTuple{4, UInt32}
    id::Ptr{Cvoid}
    tree::Ptr{Cvoid}
end

_lang() = ccall((:tree_sitter_matlab, LIBTREESITTER_MATLAB), Ptr{Cvoid}, ())

_node_type(n::TSNode) = unsafe_string(ccall((:ts_node_type, LIBTREESITTER), Cstring, (TSNode,), n))
_node_named(n::TSNode) = ccall((:ts_node_is_named, LIBTREESITTER), Bool, (TSNode,), n)
_node_child_count(n::TSNode) = ccall((:ts_node_child_count, LIBTREESITTER), UInt32, (TSNode,), n)
_node_child(n::TSNode, i) = ccall((:ts_node_child, LIBTREESITTER), TSNode, (TSNode, UInt32), n, UInt32(i))
_node_start(n::TSNode) = ccall((:ts_node_start_byte, LIBTREESITTER), UInt32, (TSNode,), n)
_node_end(n::TSNode) = ccall((:ts_node_end_byte, LIBTREESITTER), UInt32, (TSNode,), n)
_node_has_error(n::TSNode) = ccall((:ts_node_has_error, LIBTREESITTER), Bool, (TSNode,), n)

function _field_name(n::TSNode, i)
    p = ccall((:ts_node_field_name_for_child, LIBTREESITTER), Ptr{UInt8}, (TSNode, UInt32), n, UInt32(i))
    return p == C_NULL ? nothing : Symbol(unsafe_string(p))
end

# ---------------------------------------------------------------------------------------
# CST data model
# ---------------------------------------------------------------------------------------

"""
    CSTNode

A node in the MATLAB concrete syntax tree. `span` is a 1-based inclusive byte range into
the source (use [`nodetext`](@ref) to materialize the slice). `field` is the node's role in
its parent (e.g. `:left`, `:right`, `:name`) or `nothing`. Anonymous tokens (punctuation,
keywords, operators) are retained with `named == false`.
"""
struct CSTNode
    kind::Symbol
    named::Bool
    field::Union{Symbol, Nothing}
    span::UnitRange{Int}
    children::Vector{CSTNode}
end

"""
    MatlabCST

A parsed MATLAB unit: the original `source`, the `root` [`CSTNode`], and `has_error`
(true if tree-sitter inserted any ERROR/MISSING nodes).
"""
struct MatlabCST
    source::String
    root::CSTNode
    has_error::Bool
end

"Materialize the source text spanned by `n`."
nodetext(cst::MatlabCST, n::CSTNode) = String(codeunits(cst.source)[n.span])

children(n::CSTNode) = n.children

"Depth-first pre-order traversal, applying `f` to every node."
function walk(f, n::CSTNode)
    f(n)
    for c in n.children
        walk(f, c)
    end
    return nothing
end
walk(f, cst::MatlabCST) = walk(f, cst.root)

"Collect every node of the given `kind`."
function findkind(cst::MatlabCST, kind::Symbol)
    out = CSTNode[]
    walk(n -> (n.kind === kind && push!(out, n)), cst.root)
    return out
end

# ---------------------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------------------

function _build(node::TSNode, field)
    a = Int(_node_start(node))
    b = Int(_node_end(node))
    nc = Int(_node_child_count(node))
    kids = CSTNode[]
    for i in 0:(nc - 1)
        child = _node_child(node, i)
        push!(kids, _build(child, _field_name(node, i)))
    end
    return CSTNode(Symbol(_node_type(node)), _node_named(node), field, (a + 1):b, kids)
end

"""
    parse_matlab(src) -> MatlabCST

Parse a MATLAB source string into a concrete syntax tree.
"""
function parse_matlab(src::AbstractString)
    s = String(src)
    parser = ccall((:ts_parser_new, LIBTREESITTER), Ptr{Cvoid}, ())
    return try
        ok = ccall(
            (:ts_parser_set_language, LIBTREESITTER), Bool,
            (Ptr{Cvoid}, Ptr{Cvoid}), parser, _lang()
        )
        ok || error("Mjolnir: ts_parser_set_language failed (grammar/runtime ABI mismatch)")
        tree = ccall(
            (:ts_parser_parse_string, LIBTREESITTER), Ptr{Cvoid},
            (Ptr{Cvoid}, Ptr{Cvoid}, Cstring, UInt32),
            parser, C_NULL, s, UInt32(ncodeunits(s))
        )
        tree == C_NULL && error("Mjolnir: parse failed (null tree)")
        try
            root = ccall((:ts_tree_root_node, LIBTREESITTER), TSNode, (Ptr{Cvoid},), tree)
            return MatlabCST(s, _build(root, nothing), _node_has_error(root))
        finally
            ccall((:ts_tree_delete, LIBTREESITTER), Cvoid, (Ptr{Cvoid},), tree)
        end
    finally
        ccall((:ts_parser_delete, LIBTREESITTER), Cvoid, (Ptr{Cvoid},), parser)
    end
end

"""
    parse_file(path) -> MatlabCST

Parse a MATLAB source file (`.m`) into a concrete syntax tree.
"""
parse_file(path::AbstractString) = parse_matlab(read(path, String))

# ---------------------------------------------------------------------------------------
# Debug rendering (tree-sitter-style s-expression over named nodes)
# ---------------------------------------------------------------------------------------

"Render the named-node s-expression of a CST (handy for inspection and tests)."
function sexpr(cst::MatlabCST)
    io = IOBuffer()
    _sexpr(io, cst.root)
    return String(take!(io))
end

function _sexpr(io::IO, n::CSTNode)
    print(io, "(", n.kind)
    for c in n.children
        c.named || continue
        print(io, " ")
        c.field === nothing || print(io, c.field, ": ")
        _sexpr(io, c)
    end
    return print(io, ")")
end
