# Shared oracle case lists — consumed by both test/runtests.jl (Octave)
# and dev/oracle_export.jl + dev/oracle_compare.jl (MATLAB CI harness).
#
# Each entry in ORACLE_CASES: (name::String, matlab_src::String, vars::Vector{String})
# Each entry in ORACLE_CLASS_CASES:
#   (classes::Vector{Tuple{String,String}}, driver::String, vars::Vector{String})

const ORACLE_CASES = [
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
    # Phase 4.5: matrix-shape semantics
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
        "m = containers.Map('KeyType','char','ValueType','double');\nm('x') = 7;\nv = m('x');\n",
        ["v"],
    ),
    ("num2str", "s = num2str(42);\n", ["s"]),
    ("upper + strcmp", "u = upper('hi');\nb = strcmp('a', 'a');\n", ["u", "b"]),
    # note: `contains` is unit-tested (->occursin) but not oracle-tested — Octave lacks it.
    ("sprintf", "d = sprintf('%d-%d', 3, 4);\n", ["d"]),
    # struct introspection & predicates
    ("fieldnames", "s.a = 1;\ns.b = 2;\nf = fieldnames(s);\n", ["f"]),
    ("isfield", "s.a = 1;\np = isfield(s,'a');\nq = isfield(s,'z');\n", ["p", "q"]),
    (
        "rmfield",
        "s.a = 1;\ns.b = 2;\nt = rmfield(s,'a');\nv = t.b;\nn = numel(fieldnames(t));\n",
        ["v", "n"],
    ),
    ("isnan vector", "x = [1 NaN 3];\nm = isnan(x);\n", ["m"]),
    # dynamic fields, nargout, dynamic rmfield
    ("dynamic field read", "s.a = 7;\nf = 'a';\nv = s.(f);\n", ["v"]),
    ("dynamic field write", "s.a = 1;\ng = 'b';\ns.(g) = 5;\nv = s.b;\n", ["v"]),
    (
        "nargout (all requested)",
        "1;\nfunction [a,b] = f()\n  a = 1;\n  if nargout > 1\n    b = 2;\n  end\nend\n[x, y] = f();\n",
        ["x", "y"],
    ),
    (
        "dynamic rmfield",
        "s.a = 1;\ns.b = 2;\nnm = 'a';\nt = rmfield(s, nm);\nv = t.b;\nn = numel(fieldnames(t));\n",
        ["v", "n"],
    ),
    # toolbox batch
    (
        "gcd/lcm/factorial/nchoosek",
        "g = gcd(12, 8);\nl = lcm(4, 6);\nfa = factorial(5);\nc = nchoosek(5, 2);\n",
        ["g", "l", "fa", "c"],
    ),
    ("kron", "K = kron([1 0; 0 1], [1 2; 3 4]);\n", ["K"]),
    ("ismember", "m = ismember([1 2 5], [2 3 1]);\n", ["m"]),
    (
        "set ops (sorted)",
        "i = intersect([1 2 3 4], [2 4 6]);\nu = union([1 2], [2 3]);\nd = setdiff([1 2 3], [2]);\n",
        ["i", "u", "d"],
    ),
    # loop -> comprehension, runtime-equivalent
    (
        "comprehension",
        "1;\nfunction y = sq(n)\n  y = zeros(1, n);\n  for i = 1:n\n    y(i) = i^2;\n  end\nend\nr = sq(4);\n",
        ["r"],
    ),
    # function handle (lambda) passed as a parameter and called
    (
        "function handle param",
        "1;\nfunction r = applyf(f, x)\n  r = f(x) + 1;\nend\ny = applyf(@(z) z^2, 3);\n",
        ["y"],
    ),
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

const ORACLE_CLASS_CASES = [
    (
        [
            (
                "Point",
                """
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
                """,
            ),
        ],
        "p = Point(3, 4);\nd = dist(p);\nq = scale(p, 2);\nqx = q.x;\n",
        ["d", "qx"],
    ),
]
