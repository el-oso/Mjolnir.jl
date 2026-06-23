# Project audit: which functions does this MATLAB tree call but never define?
#
# Poorly-organized projects scatter helpers across folders. When a called function lives in a
# folder you didn't include, the conversion can't see it and records an "unmapped function" todo.
# `audit_project` collects those across the whole tree, subtracts everything actually defined in it
# (and the MATLAB builtins Mjolnir knows), and reports what's left — the functions you still need
# to bring in — searching given paths for the matching `.m` files.

# Function names defined in one `.m` source (top-level, nested, and classdef methods).
function _defined_funcs(src::AbstractString)
    names = Set{Symbol}()
    cst = parse_matlab(src)
    for n in findkind(cst, :function_definition)
        nm = _field(n, :name)
        nm === nothing || push!(names, Symbol(nodetext(cst, nm)))
    end
    return names
end

_mfiles(dir, recursive) = recursive ?
    [joinpath(d, f) for (d, _, fs) in walkdir(dir) for f in fs if endswith(f, ".m") && !startswith(f, "._")] :
    [joinpath(dir, f) for f in readdir(dir) if endswith(f, ".m") && !startswith(f, "._")]

"""
    audit_project(srcdir; searchpaths=String[], recursive=true)
        -> (; defined, unresolved, suggestions)

Scan a MATLAB source tree and report functions that are **called but defined nowhere** in it — the
usual symptom of a scattered project whose helpers live in folders you haven't added yet.

For each unresolved name, `searchpaths` (plus `srcdir`'s parent directory) are searched for a
matching `<name>.m`, offered as folders to add. Returns a `NamedTuple`:

  * `defined` — every function name defined anywhere in the tree;
  * `unresolved` — called-but-undefined names (MATLAB builtins Mjolnir recognizes are excluded);
  * `suggestions` — `name => folder` for each unresolved name whose `.m` was found on a search path.

See also [`convert_project`](@ref)'s `audit=true` flag.
"""
function audit_project(
        srcdir::AbstractString;
        searchpaths::AbstractVector = String[], recursive::Bool = true
    )
    defined = Set{Symbol}()
    called = Set{Symbol}()
    for p in _mfiles(srcdir, recursive)
        src = read(p, String)
        union!(defined, _defined_funcs(src))
        for t in conversion_todos(src)
            m = match(r"^unmapped function: (\w+)", t)
            m === nothing || push!(called, Symbol(m.captures[1]))
        end
    end
    unresolved = setdiff(called, defined, _known_names())

    roots = unique(String[String.(searchpaths)..., dirname(abspath(srcdir))])
    suggestions = Dict{Symbol, String}()
    for nm in unresolved
        target = string(nm, ".m")
        for root in roots
            isdir(root) || continue
            for (d, _, fs) in walkdir(root)
                if target in fs
                    suggestions[nm] = d
                    break
                end
            end
            haskey(suggestions, nm) && break
        end
    end
    return (defined = defined, unresolved = unresolved, suggestions = suggestions)
end

# Just the todos from converting `src` (used by the audit; avoids depending on todo wording elsewhere).
conversion_todos(src::AbstractString) = convert_matlab(src).todos
