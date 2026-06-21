using Mjolnir
using Test

include("octave_oracle.jl")

@testset "Mjolnir — Stage 1: MATLAB front-end (tree-sitter FFI)" begin

    @testset "trivial script round-trips" begin
        cst = parse_matlab("x = 1;\n")
        @test cst isa MatlabCST
        @test cst.root.kind === :source_file
        @test !cst.has_error
        @test length(findkind(cst, :assignment)) == 1
    end

    @testset "whitespace-sensitive matrix [1 -2] is two elements" begin
        cst = parse_matlab("x = [1 -2];\n")
        @test !cst.has_error
        @test length(findkind(cst, :matrix)) == 1
        @test length(findkind(cst, :row)) == 1
        # `-2` is a unary minus -> the row holds a number AND a unary_operator (two elements),
        # not a single `1 - 2` subtraction.
        @test length(findkind(cst, :unary_operator)) == 1
        @test isempty(findkind(cst, :binary_operator))
    end

    @testset "[1 - 2] (spaces both sides) is one binary subtraction" begin
        cst = parse_matlab("x = [1 - 2];\n")
        @test !cst.has_error
        @test length(findkind(cst, :binary_operator)) == 1
        @test isempty(findkind(cst, :unary_operator))
    end

    @testset "transpose vs string disambiguation" begin
        t = parse_matlab("y = x';\n")
        @test !t.has_error
        @test length(findkind(t, :postfix_operator)) == 1   # transpose
        @test isempty(findkind(t, :string))

        s = parse_matlab("s = 'hello';\n")
        @test !s.has_error
        @test length(findkind(s, :string)) == 1             # char/string literal
        @test isempty(findkind(s, :postfix_operator))
    end

    @testset "function definition" begin
        cst = parse_matlab("function r = sq(a)\n  r = a.^2;\nend\n")
        @test !cst.has_error
        @test length(findkind(cst, :function_definition)) == 1
        @test length(findkind(cst, :function_output)) == 1
    end

    @testset "nodetext recovers source slices" begin
        cst = parse_matlab("foo = 42;\n")
        ids = findkind(cst, :identifier)
        @test any(n -> nodetext(cst, n) == "foo", ids)
        nums = findkind(cst, :number)
        @test any(n -> nodetext(cst, n) == "42", nums)
    end

    @testset "parse_file" begin
        mktempdir() do dir
            path = joinpath(dir, "demo.m")
            write(path, "a = 1;\nb = a + 2;\n")
            cst = parse_file(path)
            @test !cst.has_error
            @test length(findkind(cst, :assignment)) == 2
        end
    end

    @testset "syntactically invalid input is flagged, not crashed" begin
        cst = parse_matlab("x = (1 + ;\n")
        @test cst isa MatlabCST
        @test cst.has_error
    end
end

@testset "Mjolnir — Stage 2/3/6: lower + emit (idiomatic mappings)" begin
    conv(s) = convert_matlab(s).julia

    @testset "emitted Julia is always syntactically valid" begin
        # convert_matlab runs the JuliaSyntax validity gate internally; reaching here is the test
        @test conv("x = 1;\ny = x + 2;\n") isa String
    end

    @testset "indexing is 1-based and uses []" begin
        out = conv("A = zeros(3);\nA(2,2) = 5;\nb = A(2);\n")
        @test occursin("zeros(3, 3)", out)      # MATLAB zeros(n) is n×n
        @test occursin("A[2, 2] = 5", out)
        @test occursin("b = A[2]", out)
    end

    @testset "function call vs index resolved by scope" begin
        out = conv("y = f(2);\nz = 3;\nw = z(1);\n")
        @test occursin("y = f(2)", out)          # f unknown -> call
        @test occursin("w = z[1]", out)          # z is a variable -> index
    end

    @testset "multi-output function returns a tuple" begin
        out = conv("function [u, v] = g(p, q)\n  u = p + q;\n  v = p - q;\nend\n")
        @test occursin("function g(p, q)", out)
        @test occursin("return (u, v)", out)
    end

    @testset "elementwise ops & comparisons broadcast" begin
        @test occursin(".==", conv("y = a == b;\n"))
        @test occursin(".!=", conv("y = a ~= b;\n"))
        @test occursin("sqrt.(", conv("y = sqrt(x);\n"))
        @test occursin(".&", conv("y = a & b;\n"))
        @test occursin("&&", conv("y = a && b;\n"))
    end

    @testset "transpose vs adjoint" begin
        @test occursin("transpose(", conv("y = x.';\n"))
        @test occursin("'", conv("y = x';\n"))
    end

    @testset "unmapped functions are recorded as TODOs" begin
        r = convert_matlab("y = fzero(h, 0);\n")
        @test any(t -> occursin("fzero", t), r.todos)
    end
end

@testset "Mjolnir — Stage 4: idiomatic passes (de-broadcast, colon, script wrap)" begin
    @testset "scalar arithmetic is de-broadcast" begin
        out = convert_matlab(
            """
            function stats = summarize(v)
              n = numel(v);
              mu = sum(v) / n;
              acc = 0;
              for i = 1:n
                acc = acc + (v(i) - mu)^2;
              end
              stats = sqrt(acc / n);
            end
            """
        ).julia
        @test occursin("acc + (", out)        # de-broadcast: scalar + scalar
        @test occursin("sqrt(acc", out)        # de-broadcast: sqrt(scalar)
        @test !occursin(".+", out)
        @test !occursin("sqrt.(", out)
    end

    @testset "array ops stay broadcast" begin
        out = convert_matlab("a = [1 2 3];\nb = a + 1;\n"; wrap_script = false).julia
        @test occursin("a .+ 1", out)          # a is non-scalar -> must stay broadcast
    end

    @testset "Colon() renders as :" begin
        out = convert_matlab("A = zeros(2);\nc = A(2,:);\n"; wrap_script = false).julia
        @test occursin("A[2, :]", out)
        @test !occursin("Colon()", out)
    end

    @testset "loop-bearing script is wrapped in let and runs at top level" begin
        out = convert_matlab("s = 0;\nfor i = 1:10\n  s = s + i;\nend\n").julia
        @test occursin("let", out)
        Base.include_string(Module(), out)     # must not throw (soft scope handled)
        @test true
    end

    @testset "unwrapped loop script hits soft scope (wrapper is necessary)" begin
        out = convert_matlab("s = 0;\nfor i = 1:10\n  s = s + i;\nend\n"; wrap_script = false).julia
        @test_throws Exception Base.include_string(Module(), out)
    end

    @testset "idiomatic=false leaves the safe broadcast form" begin
        out = convert_matlab("x = 1;\ny = x + 2;\n"; idiomatic = false).julia
        @test occursin("x .+ 2", out)
    end
end

@testset "Mjolnir — Stage 4b: classdef -> struct + methods" begin
    point = """
    classdef Point
      properties
        x
        y = 0
      end
      methods
        function obj = Point(x, y)
          obj.x = x;
          obj.y = y;
        end
        function d = dist(obj)
          d = sqrt(obj.x^2 + obj.y^2);
        end
        function obj = scale(obj, k)
          obj.x = obj.x * k;
          obj.y = obj.y * k;
        end
      end
    end
    """

    @testset "structure of emitted code" begin
        out = convert_matlab(point).julia
        @test occursin("abstract type AbstractPoint", out)
        @test occursin("mutable struct Point <: AbstractPoint", out)
        @test occursin("function Point(x, y)", out)     # inner constructor
        @test occursin("obj = new()", out)
        @test occursin("function dist(obj::Point)", out) # method dispatches on type
        # struct must precede its methods (otherwise it won't compile)
        @test findfirst("mutable struct Point", out).start < findfirst("function dist", out).start
    end

    @testset "converted class runs in Julia" begin
        m = Module()
        Base.include_string(m, convert_matlab(point).julia)
        p = Base.invokelatest(getfield(m, :Point), 3, 4)
        @test Base.invokelatest(getfield(m, :dist), p) == 5.0
        q = Base.invokelatest(getfield(m, :scale), p, 2)
        @test q.x == 6 && q.y == 8
    end

    @testset "inheritance maps to abstract-type chain" begin
        src = "classdef Circle < Shape\n  properties\n    r\n  end\nend\n" *
            "classdef Shape\n  properties\n    name\n  end\nend\n"
        out = convert_matlab(src).julia
        @test occursin("abstract type AbstractShape", out)
        @test occursin("abstract type AbstractCircle <: AbstractShape", out)
    end
end

@testset "Mjolnir — Stage 4d: cells & structs" begin
    @testset "cell array -> Any[...] and content index" begin
        out = convert_matlab("c = {1, 2, 3};\nx = c{2};\n"; wrap_script = false).julia
        @test occursin("Any[1, 2, 3]", out)
        @test occursin("x = c[2]", out)
    end
    @testset "struct(...) -> NamedTuple" begin
        out = convert_matlab("t = struct('a', 1, 'b', 2);\n"; wrap_script = false).julia
        @test occursin("(a = 1, b = 2)", out)
        @test !occursin("Dict", out)                 # prefer NamedTuple, not Dict
    end
    @testset "incremental struct build -> NamedTuple merge" begin
        out = convert_matlab("s.x = 10;\ns.y = 20;\n"; wrap_script = false).julia
        @test occursin("s = (x = 10,)", out)
        @test occursin("merge(s, (y = 20,))", out)
    end
    @testset "classdef field assignment stays in-place (not NamedTuple)" begin
        out = convert_matlab(
            "classdef C\n  properties\n    v\n  end\n  methods\n    function obj = set(obj, x)\n      obj.v = x;\n    end\n  end\nend\n"
        ).julia
        @test occursin("obj.v = x", out)             # mutate, not merge
        @test !occursin("merge(", out)
    end
end

@testset "Mjolnir — Stage 4e: containers.Map, strings, method calls" begin
    @testset "containers.Map -> Dict" begin
        out = convert_matlab("m = containers.Map({'a','b'}, {1, 2});\nx = m('a');\nm('c') = 3;\n"; wrap_script = false).julia
        @test occursin("Dict(zip(", out)
        @test occursin("x = m[\"a\"]", out)
        @test occursin("m[\"c\"] = 3", out)
    end
    @testset "string & conversion builtins" begin
        @test occursin("uppercase(", convert_matlab("u = upper('x');\n"; wrap_script = false).julia)
        @test occursin("\"a\" == \"b\"", convert_matlab("b = strcmp('a','b');\n"; wrap_script = false).julia)
        @test occursin("string(", convert_matlab("s = num2str(5);\n"; wrap_script = false).julia)
        @test occursin("=> ", convert_matlab("r = strrep('a','a','b');\n"; wrap_script = false).julia)
        @test occursin("occursin(", convert_matlab("b = contains('ab','a');\n"; wrap_script = false).julia)
        @test occursin("Printf.@sprintf", convert_matlab("d = sprintf('%d', 1);\n"; wrap_script = false).julia)
    end
    @testset "method-call syntax obj.m(x) -> m(obj, x)" begin
        out = convert_matlab("p = 0;\nq = p.dist();\nr = p.scale(2);\n"; wrap_script = false).julia
        @test occursin("dist(p)", out)
        @test occursin("scale(p, 2)", out)
    end
    @testset "struct introspection & predicates" begin
        out = convert_matlab("f = fieldnames(s);\nk = isfield(s,'a');\nt = rmfield(s,'a');\nm = isnan(x);\n"; wrap_script = false).julia
        @test occursin("collect(string.(keys(s)))", out)
        @test occursin("haskey(s, Symbol(\"a\"))", out)
        @test occursin("Base.structdiff(s, NamedTuple{(Symbol(\"a\"),)}", out)
        @test occursin("isnan.(x)", out)
        @test occursin("@warn", convert_matlab("warning('x');\n"; wrap_script = false).julia)
    end
    @testset "dynamic fields, nargout, struct arrays" begin
        dr = convert_matlab("v = s.(f);\n"; wrap_script = false).julia
        @test occursin("getproperty(s, Symbol(f))", dr)
        dw = convert_matlab("s.(g) = 3;\n"; wrap_script = false).julia
        @test occursin("merge(s, NamedTuple{(Symbol(g),)}((3,)))", dw)
        no = convert_matlab("function [a, b] = f()\n  a = 1;\n  if nargout > 1\n    b = 2;\n  end\nend\n").julia
        @test occursin("nargout = 2", no)
        sa = convert_matlab("arr(2).a = 5;\nx = arr(2).a;\n"; wrap_script = false).julia
        @test occursin("arr[2] = merge(arr[2], (a = 5,))", sa)   # struct-array element field set
        @test occursin(").a", sa)                                # arr[2].a read
    end
    @testset "linear algebra & array builtins" begin
        @test occursin("tr(A)", convert_matlab("t = trace(A);\n"; wrap_script = false).julia)   # renamed
        @test occursin("norm(", convert_matlab("n = norm(v);\n"; wrap_script = false).julia)
        @test occursin("sort(unique(", convert_matlab("u = unique(x);\n"; wrap_script = false).julia)
        @test occursin("reverse(A, dims = 2)", convert_matlab("b = fliplr(A);\n"; wrap_script = false).julia)
        @test occursin("reshape(A, :, 3)", convert_matlab("b = reshape(A, [], 3);\n"; wrap_script = false).julia)
        @test occursin("binomial(", convert_matlab("c = nchoosek(5, 2);\n"; wrap_script = false).julia)
        @test occursin("sort(intersect(", convert_matlab("i = intersect(a, b);\n"; wrap_script = false).julia)
        @test occursin("in.(a, Ref(b))", convert_matlab("m = ismember(a, b);\n"; wrap_script = false).julia)
    end
    @testset "function handles, commands, misc builtins" begin
        @test occursin("x->x ^ 2", convert_matlab("g = @(x) x^2;\n"; wrap_script = false).julia)
        @test occursin("h = sin", convert_matlab("h = @sin;\n"; wrap_script = false).julia)
        # function-handle parameter: f used only as f(...) -> stays a call
        hp = convert_matlab("function r = ap(f, x)\n  r = f(x);\nend\n").julia
        @test occursin("f(x)", hp) && !occursin("f[x]", hp)
        # read-only array parameter (also sized) -> stays indexing
        ap = convert_matlab("function y = g(a)\n  n = numel(a);\n  y = a(1) + n;\nend\n").julia
        @test occursin("a[1]", ap)
        @test occursin("size(", convert_matlab("s = size(A);\n"; wrap_script = false).julia)
        @test occursin("error(", convert_matlab("error('boom');\n"; wrap_script = false).julia)
        @test occursin("tril(", convert_matlab("L = tril(A);\n"; wrap_script = false).julia)
        @test occursin("Array{Any}(undef", convert_matlab("c = cell(3);\n"; wrap_script = false).julia)
        @test any(t -> occursin("dropped MATLAB command", t), convert_matlab("clc;\n").todos)
        # line continuation `...` is transparent
        @test occursin("x = 1 + 2", convert_matlab("x = 1 + ...\n  2;\n"; wrap_script = false).julia)
        # fft -> FFTW
        rfft = convert_matlab("y = fft(x);\n"; wrap_script = false)
        @test occursin("fft(x)", rfft.julia) && (:FFTW in rfft.imports)
        # Julia reserved-word identifiers are sanitized (e.g. a variable named `const`)
        kw = convert_matlab("const = 5;\ny = const + 1;\n"; wrap_script = false).julia
        @test occursin("const_ = 5", kw) && occursin("const_ + 1", kw)
        # files without a trailing newline still parse cleanly (no spurious has_error)
        @test !convert_matlab("x = 1").has_error
        # plotting -> Plots.jl
        pl = convert_matlab("plot(x, y);\nxlabel('t');\n"; wrap_script = false)
        @test occursin("plot(x, y)", pl.julia) && occursin("xlabel!(\"t\")", pl.julia) && (:Plots in pl.imports)
        # multibyte UTF-8 string literal (e.g. Greek) doesn't crash
        @test occursin("\"αβ\"", convert_matlab("s = 'αβ';\n"; wrap_script = false).julia)
        # lambda parameters are scoped: x(i) inside @(x) is indexing, not a call
        lam = convert_matlab("f = @(x) x(1)^2 + x(2)^2;\n"; wrap_script = false).julia
        @test occursin("x[1]", lam) && occursin("x[2]", lam)
        @test occursin("eigvals(A)", convert_matlab("e = eig(A);\n"; wrap_script = false).julia)
    end

    @testset "loop -> comprehension (and refusal when cumulative)" begin
        comp = convert_matlab("function y = f(n)\n  y = zeros(1, n);\n  for i = 1:n\n    y(i) = i^2;\n  end\nend\n").julia
        @test occursin("y = [i ^ 2 for i = 1:n]", comp)
        @test !occursin("for i = 1:n\n", comp) || !occursin("y[i]", comp)   # loop replaced
        cumulative = convert_matlab("s = 0;\nfor i = 1:n\n  s = s + i;\nend\n").julia
        @test occursin("for i = 1:n", cumulative)                            # NOT converted
    end
end

@testset "Mjolnir — idiom registry (single source of truth)" begin
    @test !isempty(idioms())
    @test all(i -> i.status in (:ok, :partial, :todo), idioms())
    @test !isempty(idioms(category = "classdef"))
    @test !isempty(idioms(status = :todo))

    @testset "registry never claims an unimplemented builtin (no doc/code drift)" begin
        @test isempty(idiom_builtin_gaps().unimplemented)
    end

    @testset "generated artifacts are committed and current" begin
        d = joinpath(pkgdir(Mjolnir), "docs")
        @test read(joinpath(d, "idioms.json"), String) == idioms_json()
        @test read(joinpath(d, "matlab_julia_idioms.md"), String) == idioms_markdown()
    end

    @testset "json export is valid and structured (agent-readable)" begin
        arr = JSON.parse(idioms_json())
        @test arr isa AbstractVector
        @test all(e -> haskey(e, "matlab") && haskey(e, "julia") && haskey(e, "status"), arr)
    end
end

@testset "Mjolnir — Stage 4c: project assembly" begin
    mktempdir() do dir
        src = joinpath(dir, "matlab")
        mkpath(src)
        mkpath(joinpath(src, "+geom"))
        write(joinpath(src, "addone.m"), "function y = addone(x)\n  y = x + 1;\nend\n")
        write(joinpath(src, "mkid.m"), "function M = mkid(n)\n  M = eye(n);\nend\n")  # needs LinearAlgebra
        write(joinpath(src, "+geom", "twice.m"), "function y = twice(x)\n  y = 2 * x;\nend\n")
        out = joinpath(dir, "out")
        mkpath(out)
        pkgdir = convert_project(src, out; name = "DemoPkg")
        @test isfile(joinpath(pkgdir, "Project.toml"))
        @test occursin("LinearAlgebra", read(joinpath(pkgdir, "Project.toml"), String))  # dep wired
        @test isfile(joinpath(pkgdir, "src", "DemoPkg.jl"))
        @test isfile(joinpath(pkgdir, "src", "addone.jl"))
        @test isfile(joinpath(pkgdir, "src", "Geom.jl"))          # +geom -> submodule Geom
        @test isfile(joinpath(pkgdir, "src", "Geom", "twice.jl"))
        # the generated package loads and its functions work
        m = Module()
        Base.include(m, joinpath(pkgdir, "src", "DemoPkg.jl"))
        DemoPkg = getfield(m, :DemoPkg)
        @test Base.invokelatest(getfield(DemoPkg, :addone), 41) == 42
        @test Base.invokelatest(getfield(getfield(DemoPkg, :Geom), :twice), 21) == 42
    end
end

@testset "Mjolnir — Stage 5: gated LLM refinement" begin
    baseline = "function sq(x)\n    y = x ^ 2\n    return y\nend"
    probes = ["sq(2)", "sq(5)", "sq(1.5)"]

    @testset "extract_code pulls the julia fence" begin
        @test extract_code("blah\n```julia\nf(x) = x\n```\nthanks") == "f(x) = x"
        @test extract_code("f(x) = x") == "f(x) = x"
    end

    @testset "equivalent refactor is accepted" begin
        good = FunctionBackend(_ -> "```julia\nsq(x) = x^2\n```")
        r = gated_refine(good, baseline; probes)
        @test r.accepted
        @test r.code != baseline           # candidate adopted
    end

    @testset "behavior-changing refactor is rejected, baseline kept" begin
        bad = FunctionBackend(_ -> "```julia\nsq(x) = x^3\n```")
        r = gated_refine(bad, baseline; probes)
        @test !r.accepted
        @test r.code == baseline
    end

    @testset "syntactically broken candidate is rejected" begin
        broken = FunctionBackend(_ -> "```julia\nsq(x) =\n```")
        r = gated_refine(broken, baseline; probes)
        @test !r.accepted
        @test r.code == baseline
    end

    @testset "no probes -> cannot accept" begin
        good = FunctionBackend(_ -> "```julia\nsq(x) = x^2\n```")
        @test !gated_refine(good, baseline; probes = String[]).accepted
    end

    @testset "ManualBackend (Copilot path) reads the response file" begin
        mktempdir() do dir
            pf, rf = joinpath(dir, "prompt.txt"), joinpath(dir, "response.txt")
            write(rf, "```julia\nsq(x) = x^2\n```")
            r = gated_refine(ManualBackend(pf, rf), baseline; probes)
            @test r.accepted
            @test isfile(pf)               # prompt was emitted for the human/editor
        end
    end

    @testset "SubprocessBackend via a local command" begin
        mktempdir() do dir
            rf = joinpath(dir, "out.txt")
            write(rf, "```julia\nsq(x) = x^2\n```")
            # a CLI that drains stdin (the prompt) then emits a completion
            r = gated_refine(SubprocessBackend(`sh -c "cat >/dev/null; cat $rf"`), baseline; probes)
            @test r.accepted
        end
    end

    @testset "end-to-end: refine a converted function, gated" begin
        conv = convert_matlab("function y = sq(x)\n  y = x.^2;\nend\n").julia
        good = FunctionBackend(_ -> "```julia\nsq(x) = x ^ 2\n```")
        @test gated_refine(good, conv; probes = ["sq(3)", "sq(4)"]).accepted
        bad = FunctionBackend(_ -> "```julia\nsq(x) = x + 1\n```")
        @test !gated_refine(bad, conv; probes = ["sq(3)", "sq(4)"]).accepted
    end
end

@testset "Mjolnir — Octave classdef differential oracle" begin
    if !octave_available()
        @test_skip octave_available()
    else
        point = """
        classdef Point
          properties
            x
            y
          end
          methods
            function obj = Point(x, y)
              obj.x = x;
              obj.y = y;
            end
            function d = dist(obj)
              d = sqrt(obj.x^2 + obj.y^2);
            end
            function obj = scale(obj, k)
              obj.x = obj.x * k;
              obj.y = obj.y * k;
            end
          end
        end
        """
        driver = "p = Point(3, 4);\nd = dist(p);\nq = scale(p, 2);\nqx = q.x;\n"
        ok, info = oracle_check_class([("Point", point)], driver, ["d", "qx"])
        ok || @info "class oracle mismatch" info.mismatched info.julia info.octave info.jlvals
        @test ok
    end
end

@testset "Mjolnir — Octave differential oracle (Stage 2 correctness)" begin
    if !octave_available()
        @warn "octave not found on PATH — skipping differential oracle tests"
        @test_skip octave_available()
    else
        # Realistic (newline-separated) MATLAB; the grammar requires newlines, not single-line
        # `;`, to separate statements inside control-flow bodies.
        cases = [
            ("scalar arithmetic", "a = 3;\nb = 4;\nc = sqrt(a^2 + b^2);\n", ["c"]),
            ("accumulator loop", "s = 0;\nfor i = 1:100\n  s = s + i;\nend\n", ["s"]),
            ("vector reductions", "v = [1 2 3 4];\nt = sum(v);\nm = max(v);\n", ["t", "m"]),
            ("matrix index & colon", "A = [1 2; 3 4];\nd = A(2,1);\ns = sum(A(:));\n", ["d", "s"]),
            ("conditional", "x = 5;\nif x > 3\n  y = 1;\nelse\n  y = 0;\nend\n", ["y"]),
            ("strided range + numel", "r = 2:2:10;\nn = numel(r);\n", ["r", "n"]),
            ("linspace", "p = linspace(0, 1, 5);\n", ["p"]),
            ("elementwise vector ops", "a = [1 2 3];\nb = a .* 2 + 1;\n", ["b"]),
            ("abs/mod broadcast", "v = [-1 2 -3];\nw = abs(v);\nm = mod(10, 3);\n", ["w", "m"]),
            ("zeros square + assign", "A = zeros(2);\nA(1,2) = 7;\nt = sum(A(:));\n", ["t"]),
            ("function in script", "1;\nfunction r = sq(x)\n  r = x.^2;\nend\nq = sq(4);\n", ["q"]),
            # Phase 4.5: matrix-shape semantics (these expose length/sum/max divergences)
            ("matrix column sum", "A = [1 2; 3 4];\nc = sum(A);\n", ["c"]),
            ("matrix length is max dim", "A = zeros(2, 3);\nL = length(A);\n", ["L"]),
            ("matrix column max", "A = [1 5; 3 2];\nmx = max(A);\n", ["mx"]),
            ("vector sum stays scalar", "v = [1 2 3 4];\nt = sum(v);\n", ["t"]),
            # Phase 4.5: optional args via nargin, and varargin
            (
                "optional arg via nargin",
                "1;\nfunction y = inc(a, b)\n  if nargin < 2\n    b = 1;\n  end\n  y = a + b;\nend\nq = inc(5);\nr = inc(5, 10);\n",
                ["q", "r"],
            ),
            (
                "varargin count",
                "1;\nfunction y = cnt(varargin)\n  y = numel(varargin);\nend\nk = cnt(10, 20, 30);\n",
                ["k"],
            ),
            # cells & structs
            ("cell numeric access", "c = {10, 20, 30};\nv = c{2} + c{3};\n", ["v"]),
            ("struct constructor", "t = struct('a', 3, 'b', 4);\nv = t.a + t.b;\n", ["v"]),
            ("struct value compare", "p = struct('a', 1, 'b', 2);\n", ["p"]),
            ("incremental struct build", "s.x = 10;\ns.y = 20;\nz = s.x * s.y;\n", ["z"]),
            # containers.Map & strings
            ("map access", "m = containers.Map({'a','b'}, {1, 2});\nv = m('a') + m('b');\n", ["v"]),
            (
                "map param-form + assign",
                "m = containers.Map('KeyType','char','ValueType','double');\nm('x') = 7;\nv = m('x');\n", ["v"],
            ),
            ("num2str", "s = num2str(42);\n", ["s"]),
            ("upper + strcmp", "u = upper('hi');\nb = strcmp('a', 'a');\n", ["u", "b"]),
            # note: `contains` is unit-tested (->occursin) but not oracle-tested — Octave lacks it.
            ("sprintf", "d = sprintf('%d-%d', 3, 4);\n", ["d"]),
            # struct introspection & predicates
            ("fieldnames", "s.a = 1;\ns.b = 2;\nf = fieldnames(s);\n", ["f"]),
            ("isfield", "s.a = 1;\np = isfield(s,'a');\nq = isfield(s,'z');\n", ["p", "q"]),
            ("rmfield", "s.a = 1;\ns.b = 2;\nt = rmfield(s,'a');\nv = t.b;\nn = numel(fieldnames(t));\n", ["v", "n"]),
            ("isnan vector", "x = [1 NaN 3];\nm = isnan(x);\n", ["m"]),
            # dynamic fields, nargout, dynamic rmfield
            ("dynamic field read", "s.a = 7;\nf = 'a';\nv = s.(f);\n", ["v"]),
            ("dynamic field write", "s.a = 1;\ng = 'b';\ns.(g) = 5;\nv = s.b;\n", ["v"]),
            ("nargout (all requested)", "1;\nfunction [a,b] = f()\n  a = 1;\n  if nargout > 1\n    b = 2;\n  end\nend\n[x, y] = f();\n", ["x", "y"]),
            ("dynamic rmfield", "s.a = 1;\ns.b = 2;\nnm = 'a';\nt = rmfield(s, nm);\nv = t.b;\nn = numel(fieldnames(t));\n", ["v", "n"]),
            # toolbox batch
            ("gcd/lcm/factorial/nchoosek", "g = gcd(12, 8);\nl = lcm(4, 6);\nfa = factorial(5);\nc = nchoosek(5, 2);\n", ["g", "l", "fa", "c"]),
            ("kron", "K = kron([1 0; 0 1], [1 2; 3 4]);\n", ["K"]),
            ("ismember", "m = ismember([1 2 5], [2 3 1]);\n", ["m"]),
            ("set ops (sorted)", "i = intersect([1 2 3 4], [2 4 6]);\nu = union([1 2], [2 3]);\nd = setdiff([1 2 3], [2]);\n", ["i", "u", "d"]),
            # loop -> comprehension, runtime-equivalent
            ("comprehension", "1;\nfunction y = sq(n)\n  y = zeros(1, n);\n  for i = 1:n\n    y(i) = i^2;\n  end\nend\nr = sq(4);\n", ["r"]),
            # function handle (lambda) passed as a parameter and called
            ("function handle param", "1;\nfunction r = applyf(f, x)\n  r = f(x) + 1;\nend\ny = applyf(@(z) z^2, 3);\n", ["y"]),
            # linear algebra & arrays
            ("norm & dot", "v = [3 4];\nn = norm(v);\nd = dot([1 2 3], [4 5 6]);\n", ["n", "d"]),
            ("trace & det", "A = [1 2; 3 4];\nt = trace(A);\ne = det(A);\n", ["t", "e"]),
            ("diag", "A = [1 2; 3 4];\nd = diag(A);\n", ["d"]),
            ("reshape column-major", "B = reshape(1:6, 2, 3);\n", ["B"]),
            ("fliplr/flipud", "a = fliplr([1 2; 3 4]);\nb = flipud([1;2;3]);\n", ["a", "b"]),
            # sort/cumsum on a true (column) vector; row-vector literals are 1×N matrices in Julia
            ("sort & unique", "s = sort([3;1;2]);\nu = unique([3;1;1;2]);\n", ["s", "u"]),
            ("cumsum", "c = cumsum([1;2;3]);\n", ["c"]),
            ("any/all (nonzero=true)", "p = any([0 1 0]);\nq = all([1 1 0]);\n", ["p", "q"]),
            ("mean", "m = mean([1 2 3 4]);\n", ["m"]),
        ]
        for (name, mlab, vars) in cases
            @testset "$name" begin
                @test !convert_matlab(mlab).has_error
                ok, info = oracle_check(mlab, vars)
                ok || @info "oracle mismatch" name julia = info.julia octave = info.octave jl = info.jlvals mismatched = info.mismatched
                @test ok
            end
        end
    end
end
