"""A tiny interpreter for the subset of decompiled Java used by the Minecraft
Alpha 1.0.16 sources (Block*/Item*/Material/StepSound ...).

It is used by gen_tables.py to *execute* the static registrations
(`Block.stone = new BlockStone(1, 1).setHardness(1.5F)...`), constructors,
field initializers and simple getters (getBlockTextureFromSideAndMetadata,
getRenderType, isOpaqueCube, ...) exactly as Java would, instead of pattern
matching them. Java semantics that matter here and are reproduced:
  * constructor order: super(...) / this(...), then field initializers, then body;
  * virtual dispatch from inside a super constructor (Block's constructor calls
    this.isOpaqueCube() before the subclass fields are assigned);
  * static initialization on first use, with recursive access seeing the
    partially initialized class (Block <-> Item);
  * int arithmetic (truncating division, 32-bit wrap, shifts), casts.
Floats are kept as Python floats (double) built from the decimal literal, so
0.6F is reported as 0.6, not as float32 0.6000000238.

Anything outside the subset raises Unsupported; callers record it.
"""
import os
import re


class Unsupported(Exception):
    pass


class JavaThrow(Exception):
    pass


# ---------------------------------------------------------------- tokenizer
TOKEN_RE = re.compile(r"""
    (?P<ws>\s+|//[^\n]*|/\*.*?\*/)
  | (?P<str>"(?:\\.|[^"\\])*")
  | (?P<chr>'(?:\\.|[^'\\])+')
  | (?P<num>0[xX][0-9a-fA-F]+[lL]?|(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?[fFdDlL]?)
  | (?P<id>[A-Za-z_$][A-Za-z0-9_$]*)
  | (?P<op>>>>=|<<=|>>=|>>>|==|!=|<=|>=|&&|\|\||\+\+|--|\+=|-=|\*=|/=|%=|&=|\|=|\^=|<<|>>|[{}()\[\];,.=<>!~?:+\-*/&|^%@])
""", re.S | re.X)


class Tok:
    __slots__ = ("kind", "val")

    def __init__(self, kind, val):
        self.kind = kind
        self.val = val

    def __repr__(self):
        return "%s:%s" % (self.kind, self.val)


def tokenize(src):
    toks = []
    pos = 0
    n = len(src)
    while pos < n:
        m = TOKEN_RE.match(src, pos)
        if not m:
            raise Unsupported("tokenize at %r" % src[pos:pos + 20])
        pos = m.end()
        k = m.lastgroup
        if k == "ws":
            continue
        toks.append(Tok(k, m.group(k)))
    toks.append(Tok("eof", None))
    return toks


PRIMS = {"int", "float", "double", "boolean", "byte", "short", "long", "char", "void"}
MODS = {"public", "protected", "private", "static", "final", "abstract", "synchronized",
        "transient", "volatile", "native", "strictfp"}


# ------------------------------------------------------------ class parsing
class Member:
    def __init__(self, kind, name, cls, static=False, type_=None, params=None, body=None, init=None):
        self.kind = kind          # field | method | ctor | clinit
        self.name = name
        self.cls = cls
        self.static = static
        self.type = type_
        self.params = params or []
        self.body = body          # token list (method/ctor/clinit)
        self.init = init          # token list (field initializer)
        self._ast = None


class JClass:
    def __init__(self, name, sup, kind):
        self.name = name
        self.sup = sup
        self.kind = kind  # class | enum | interface
        self.fields = []      # instance fields (Member)
        self.sfields = []     # static fields in order
        self.static_order = []  # static fields and clinit blocks in source order
        self.methods = {}     # name -> [Member]
        self.ctors = []
        self.enum_consts = []
        self.static_state = None  # None | "init" | "done"
        self.statics = {}


class Parser:
    def __init__(self, toks):
        self.t = toks
        self.p = 0

    def peek(self, k=0):
        return self.t[self.p + k]

    def next(self):
        tok = self.t[self.p]
        self.p += 1
        return tok

    def at(self, val, k=0):
        tok = self.t[self.p + k]
        return tok.val == val and tok.kind in ("op", "id")

    def expect(self, val):
        tok = self.next()
        if tok.val != val:
            raise Unsupported("expected %r got %r" % (val, tok.val))
        return tok

    def skip_balanced(self, open_, close):
        depth = 0
        start = self.p
        while True:
            tok = self.next()
            if tok.kind == "eof":
                raise Unsupported("unbalanced")
            if tok.kind == "op" and tok.val == open_:
                depth += 1
            elif tok.kind == "op" and tok.val == close:
                depth -= 1
                if depth == 0:
                    return self.t[start:self.p]

    # --- class declarations
    def parse_file(self):
        classes = []
        while self.peek().kind != "eof":
            tok = self.peek()
            if tok.val in ("package", "import"):
                while self.next().val != ";":
                    pass
                continue
            if tok.val in MODS:
                self.next()
                continue
            if tok.val in ("class", "enum", "interface"):
                classes.extend(self.parse_class())
                continue
            self.next()
        return classes

    def parse_type(self):
        name = self.next().val
        while self.at(".") and self.peek(1).kind == "id":
            self.next()
            name += "." + self.next().val
        while self.at("[") and self.at("]", 1):
            self.next()
            self.next()
            name += "[]"
        return name

    def parse_class(self):
        kind = self.next().val
        name = self.next().val
        sup = None
        while not self.at("{"):
            tok = self.next()
            if tok.val == "extends" and kind == "class":
                sup = self.parse_type()
        self.expect("{")
        cls = JClass(name, sup, kind)
        out = [cls]
        if kind == "enum":
            while not self.at(";") and not self.at("}"):
                tok = self.next()
                if tok.kind == "id":
                    cls.enum_consts.append(tok.val)
                    if self.at("("):
                        self.skip_balanced("(", ")")
                    if self.at("{"):
                        self.skip_balanced("{", "}")
                if self.at(","):
                    self.next()
            if self.at(";"):
                self.next()
        while not self.at("}"):
            mods = set()
            while self.peek().val in MODS:
                mods.add(self.next().val)
            if self.at("{"):  # static / instance initializer block
                body = self.skip_balanced("{", "}")
                m = Member("clinit" if "static" in mods else "init", None, cls, "static" in mods, body=body)
                if m.static:
                    cls.static_order.append(m)
                continue
            if self.at(";"):
                self.next()
                continue
            if self.peek().val in ("class", "enum", "interface"):
                out.extend(self.parse_class())
                continue
            if self.peek().kind == "id" and self.peek().val == name and self.at("(", 1):
                self.next()
                params = self.parse_params()
                while not self.at("{"):
                    self.next()
                body = self.skip_balanced("{", "}")
                cls.ctors.append(Member("ctor", name, cls, params=params, body=body))
                continue
            type_ = self.parse_type()
            mname = self.next().val
            if self.at("("):
                params = self.parse_params()
                while not self.at("{") and not self.at(";"):
                    self.next()
                body = self.skip_balanced("{", "}") if self.at("{") else None
                if self.at(";"):
                    self.next()
                m = Member("method", mname, cls, "static" in mods, type_, params, body)
                cls.methods.setdefault(mname, []).append(m)
                continue
            # field declarators
            while True:
                ftype = type_
                while self.at("["):
                    self.next()
                    self.expect("]")
                    ftype += "[]"
                init = None
                if self.at("="):
                    self.next()
                    start = self.p
                    depth = 0
                    while True:
                        tok = self.peek()
                        if tok.kind == "op" and tok.val in "([{":
                            depth += 1
                        elif tok.kind == "op" and tok.val in ")]}":
                            depth -= 1
                        elif depth == 0 and tok.kind == "op" and tok.val in (",", ";"):
                            break
                        self.next()
                    init = self.t[start:self.p] + [Tok("eof", None)]
                f = Member("field", mname, cls, "static" in mods, ftype, init=init)
                f.private = "private" in mods
                if f.static:
                    cls.sfields.append(f)
                    cls.static_order.append(f)
                else:
                    cls.fields.append(f)
                if self.at(","):
                    self.next()
                    mname = self.next().val
                    continue
                self.expect(";")
                break
        self.expect("}")
        return out

    def parse_params(self):
        self.expect("(")
        params = []
        while not self.at(")"):
            if self.peek().val == "final":
                self.next()
            ptype = self.parse_type()
            pname = self.next().val
            params.append((ptype, pname))
            if self.at(","):
                self.next()
        self.expect(")")
        return params

    # --- statements
    def parse_block_body(self):
        """Parse statements until end of token list (list is body incl. braces)."""
        stmts = []
        while self.peek().kind != "eof" and not self.at("}"):
            stmts.append(self.statement())
        return stmts

    def is_decl_start(self):
        tok = self.peek()
        if tok.kind != "id":
            return False
        if tok.val in PRIMS:
            return True
        if tok.val in ("return", "new", "this", "super", "throw", "if", "for", "while", "else", "do", "break", "continue"):
            return False
        # Type ident  |  Type[] ident  | pkg.Type ident
        k = 1
        while self.peek(k).val == "." and self.peek(k + 1).kind == "id":
            k += 2
        while self.peek(k).val == "[" and self.peek(k + 1).val == "]":
            k += 2
        return self.peek(k).kind == "id" and self.peek(k + 1).val in ("=", ";", ",", "[")

    def statement(self):
        tok = self.peek()
        if tok.kind == "op" and tok.val == "{":
            self.next()
            body = []
            while not self.at("}"):
                body.append(self.statement())
            self.next()
            return ("block", body)
        if tok.kind == "op" and tok.val == ";":
            self.next()
            return ("block", [])
        if tok.kind == "id":
            v = tok.val
            if v == "return":
                self.next()
                e = None if self.at(";") else self.expr()
                self.expect(";")
                return ("return", e)
            if v == "if":
                self.next()
                self.expect("(")
                c = self.expr()
                self.expect(")")
                a = self.statement()
                b = None
                if self.at("else"):
                    self.next()
                    b = self.statement()
                return ("if", c, a, b)
            if v == "while":
                self.next()
                self.expect("(")
                c = self.expr()
                self.expect(")")
                return ("while", c, self.statement())
            if v == "for":
                self.next()
                self.expect("(")
                init = []
                if not self.at(";"):
                    if self.is_decl_start():
                        init.append(self.decl(False))
                    else:
                        init.append(("expr", self.expr()))
                        while self.at(","):
                            self.next()
                            init.append(("expr", self.expr()))
                self.expect(";")
                cond = None if self.at(";") else self.expr()
                self.expect(";")
                upd = []
                while not self.at(")"):
                    upd.append(self.expr())
                    if self.at(","):
                        self.next()
                self.expect(")")
                return ("for", init, cond, upd, self.statement())
            if v == "throw":
                self.next()
                e = self.expr()
                self.expect(";")
                return ("throw", e)
            if v == "break":
                self.next()
                self.expect(";")
                return ("break",)
            if v == "continue":
                self.next()
                self.expect(";")
                return ("continue",)
            if v in ("switch", "try", "do", "synchronized", "case", "default"):
                raise Unsupported("statement " + v)
            if self.is_decl_start():
                return self.decl(True)
        e = self.expr()
        self.expect(";")
        return ("expr", e)

    def decl(self, semi):
        type_ = self.parse_type()
        items = []
        while True:
            name = self.next().val
            t = type_
            while self.at("["):
                self.next()
                self.expect("]")
                t += "[]"
            init = None
            if self.at("="):
                self.next()
                init = self.array_init() if self.at("{") else self.expr()
            items.append((t, name, init))
            if self.at(","):
                self.next()
                continue
            break
        if semi:
            self.expect(";")
        return ("decl", items)

    def array_init(self):
        self.expect("{")
        elems = []
        while not self.at("}"):
            elems.append(self.array_init() if self.at("{") else self.expr())
            if self.at(","):
                self.next()
        self.expect("}")
        return ("arrlit", elems)

    # --- expressions (precedence climbing)
    BIN = [
        ("||",), ("&&",), ("|",), ("^",), ("&",), ("==", "!="),
        ("<", ">", "<=", ">=", "instanceof"), ("<<", ">>", ">>>"), ("+", "-"), ("*", "/", "%"),
    ]
    ASSIGN = ("=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", ">>>=")

    def expr(self):
        lhs = self.ternary()
        tok = self.peek()
        if tok.kind == "op" and tok.val in self.ASSIGN:
            self.next()
            rhs = self.expr()
            return ("assign", tok.val, lhs, rhs)
        return lhs

    def ternary(self):
        c = self.binary(0)
        if self.at("?"):
            self.next()
            a = self.expr()
            self.expect(":")
            b = self.ternary_or_assign()
            return ("cond", c, a, b)
        return c

    def ternary_or_assign(self):
        return self.expr()

    def binary(self, level):
        if level == len(self.BIN):
            return self.unary()
        lhs = self.binary(level + 1)
        while True:
            tok = self.peek()
            if tok.val in self.BIN[level] and tok.kind in ("op", "id"):
                self.next()
                if tok.val == "instanceof":
                    rhs = ("type", self.parse_type())
                else:
                    rhs = self.binary(level + 1)
                lhs = ("bin", tok.val, lhs, rhs)
            else:
                return lhs

    def is_cast(self):
        # at '('
        k = 1
        tok = self.peek(k)
        if tok.kind != "id":
            return False
        prim = tok.val in PRIMS
        k += 1
        while self.peek(k).val == "." and self.peek(k + 1).kind == "id":
            k += 2
        while self.peek(k).val == "[" and self.peek(k + 1).val == "]":
            k += 2
        if self.peek(k).val != ")":
            return False
        if prim:
            return True
        if not tok.val[0].isupper():
            return False
        after = self.peek(k + 1)
        return after.kind in ("id", "num", "str", "chr") or (after.kind == "op" and after.val in ("(", "!", "~"))

    def unary(self):
        tok = self.peek()
        if tok.kind == "op":
            if tok.val in ("-", "+", "!", "~"):
                self.next()
                return ("un", tok.val, self.unary())
            if tok.val in ("++", "--"):
                self.next()
                return ("preinc", tok.val, self.unary())
            if tok.val == "(" and self.is_cast():
                self.next()
                t = self.parse_type()
                self.expect(")")
                return ("cast", t, self.unary())
        return self.postfix(self.primary())

    def args(self):
        self.expect("(")
        out = []
        while not self.at(")"):
            out.append(self.expr())
            if self.at(","):
                self.next()
        self.expect(")")
        return out

    def primary(self):
        tok = self.next()
        if tok.kind == "num":
            s = tok.val
            if s.lower().startswith("0x"):
                return ("lit", int(s.rstrip("lL"), 16))
            if s[-1] in "lL":
                return ("lit", int(s[:-1]))
            if s[-1] in "fFdD" or "." in s or "e" in s.lower():
                return ("lit", float(s.rstrip("fFdD")))
            return ("lit", int(s))
        if tok.kind == "str":
            return ("lit", bytes(tok.val[1:-1], "utf-8").decode("unicode_escape"))
        if tok.kind == "chr":
            return ("lit", ord(bytes(tok.val[1:-1], "utf-8").decode("unicode_escape")))
        if tok.kind == "op" and tok.val == "(":
            e = self.expr()
            self.expect(")")
            return e
        if tok.kind == "id":
            v = tok.val
            if v == "true":
                return ("lit", True)
            if v == "false":
                return ("lit", False)
            if v == "null":
                return ("lit", None)
            if v == "this":
                if self.at("("):
                    return ("ctorcall", "this", self.args())
                return ("this",)
            if v == "super":
                if self.at("("):
                    return ("ctorcall", "super", self.args())
                return ("super",)
            if v == "new":
                t = self.next().val
                while self.at(".") and self.peek(1).kind == "id":
                    self.next()
                    t += "." + self.next().val
                if self.at("["):
                    dims = []
                    while self.at("["):
                        self.next()
                        if self.at("]"):
                            self.next()
                            dims.append(None)
                        else:
                            dims.append(self.expr())
                            self.expect("]")
                    if self.at("{"):
                        return ("newarrlit", t, self.array_init())
                    return ("newarr", t, dims)
                a = self.args()
                if self.at("{"):
                    raise Unsupported("anonymous class")
                return ("new", t, a)
            if v in PRIMS and self.at("."):
                return ("name", v)
            if self.at("("):
                return ("call", None, v, self.args())
            return ("name", v)
        raise Unsupported("primary %r" % tok)

    def postfix(self, e):
        while True:
            if self.at("."):
                self.next()
                name = self.next().val
                if self.at("("):
                    e = ("call", e, name, self.args())
                else:
                    e = ("field", e, name)
            elif self.at("["):
                self.next()
                i = self.expr()
                self.expect("]")
                e = ("index", e, i)
            elif self.peek().kind == "op" and self.peek().val in ("++", "--"):
                e = ("postinc", self.next().val, e)
            else:
                return e


# -------------------------------------------------------------- runtime
class JObject:
    __slots__ = ("cls", "f")

    def __init__(self, cls):
        self.cls = cls
        self.f = {}

    def __repr__(self):
        return "<%s>" % self.cls.name


class ClassRef:
    def __init__(self, cls):
        self.cls = cls


class Stub:
    """Instance or class reference of a class we do not interpret (java.*, GL ...)."""

    def __init__(self, name, is_class=False):
        self.name = name
        self.is_class = is_class

    def __repr__(self):
        return "<stub %s>" % self.name


class EnumConst:
    def __init__(self, cls, name, ordinal):
        self.cls = cls
        self.name = name
        self.ordinal = ordinal

    def __repr__(self):
        return "%s.%s" % (self.cls.name, self.name)


def _parse_int(v, radix=10):
    try:
        return i32(int(v, radix))
    except (TypeError, ValueError):
        raise JavaThrow("NumberFormatException %r" % (v,))


# Host (java.*) static methods the interpreted code may touch during class init.
# The environment is a plain JVM without -D properties (so F2F.enabled == false).
HOST_STATIC = {
    "System.getProperty": lambda k, d=None: d,
    "System.getenv": lambda k: None,
    "Integer.parseInt": _parse_int,
    "Boolean.getBoolean": lambda k: False,
    "Math.abs": abs,
    "Math.min": min,
    "Math.max": max,
}


class _Ret(Exception):
    def __init__(self, v):
        self.v = v


class _Break(Exception):
    pass


class _Continue(Exception):
    pass


def i32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v


def default_value(t):
    if t in ("int", "byte", "short", "long", "char"):
        return 0
    if t in ("float", "double"):
        return 0.0
    if t == "boolean":
        return False
    return None


class Frame:
    __slots__ = ("this", "cls", "locals")

    def __init__(self, this, cls):
        self.this = this
        self.cls = cls
        self.locals = [{}]


class VM:
    def __init__(self, src_dir, opaque_prefixes=()):
        """opaque_prefixes: classes treated as host code (not interpreted); calls into
        them return an opaque value. Used for the F2F instrumentation (F2FRandom.create
        replaces `new Random()` in game classes)."""
        self.src_dir = src_dir
        self.opaque_prefixes = tuple(opaque_prefixes)
        self.index = {}
        for fn in os.listdir(src_dir):
            if not fn.endswith(".java"):
                continue
            with open(os.path.join(src_dir, fn), encoding="utf-8", errors="replace") as f:
                text = f.read()
            for m in re.finditer(r"\b(?:class|enum|interface)\s+([A-Za-z_]\w*)", text):
                self.index.setdefault(m.group(1), fn)
        self.classes = {}
        self.parsed_files = set()
        self.trace_unsupported = []

    # --- class loading
    def get_class(self, name):
        if self.opaque_prefixes and name.startswith(self.opaque_prefixes):
            return None
        if name in self.classes:
            return self.classes[name]
        fn = self.index.get(name)
        if fn is None or fn in self.parsed_files:
            return None
        self.parsed_files.add(fn)
        with open(os.path.join(self.src_dir, fn), encoding="utf-8", errors="replace") as f:
            toks = tokenize(f.read())
        for c in Parser(toks).parse_file():
            self.classes[c.name] = c
        return self.classes.get(name)

    def chain(self, cls):
        out = []
        while cls is not None:
            out.append(cls)
            cls = self.get_class(cls.sup) if cls.sup else None
        return out

    def is_subclass(self, cls, name):
        return any(c.name == name for c in self.chain(cls))

    def ensure_static(self, cls):
        if cls.static_state is not None:
            return
        cls.static_state = "init"
        if cls.sup:
            sc = self.get_class(cls.sup)
            if sc:
                self.ensure_static(sc)
        for i, name in enumerate(cls.enum_consts):
            cls.statics[name] = EnumConst(cls, name, i)
        for f in cls.sfields:
            cls.statics[f.name] = default_value(f.type)
        for m in cls.static_order:
            fr = Frame(None, cls)
            if m.kind == "field":
                if m.init is not None:
                    cls.statics[m.name] = self.eval_init(m, fr)
            else:
                self.run_body(m, fr)
        cls.static_state = "done"

    def eval_init(self, m, fr):
        if m._ast is None:
            p = Parser(m.init)
            m._ast = p.array_init() if p.at("{") else p.expr()
        v = self.ev(m._ast, fr)
        return self.coerce(m.type, v)

    def run_body(self, m, fr):
        if m._ast is None:
            p = Parser(m.body + [Tok("eof", None)])
            p.expect("{")
            m._ast = p.parse_block_body()
            p.expect("}")
        try:
            for s in m._ast:
                self.ex(s, fr)
        except _Ret as r:
            return r.v
        return None

    def find_static_field(self, cls, name):
        for c in self.chain(cls):
            if any(f.name == name for f in c.sfields) or name in c.enum_consts:
                self.ensure_static(c)
                return c
        return None

    def find_method(self, cls, name, nargs):
        for c in self.chain(cls):
            for m in c.methods.get(name, []):
                if len(m.params) == nargs and m.body is not None:
                    return m
        return None

    def defining_class(self, cls, name, nargs):
        m = self.find_method(cls, name, nargs)
        return m.cls.name if m else None

    # --- objects
    def new_object(self, cls, args):
        self.ensure_static(cls)
        obj = JObject(cls)
        for c in self.chain(cls):
            for f in c.fields:
                if f.name in obj.f:
                    raise Unsupported("shadowed instance field %s in %s" % (f.name, cls.name))
                obj.f[f.name] = default_value(f.type)
        self.construct(cls, obj, args)
        return obj

    def pick_ctor(self, cls, args):
        cands = [c for c in cls.ctors if len(c.params) == len(args)]
        if len(cands) > 1:
            def ok(t, v):
                if t in ("int", "byte", "short", "long", "char"):
                    return isinstance(v, int) and not isinstance(v, bool)
                if t in ("float", "double"):
                    return isinstance(v, (int, float)) and not isinstance(v, bool)
                if t == "boolean":
                    return isinstance(v, bool)
                return not isinstance(v, (int, float, bool))
            cands = [c for c in cands if all(ok(p[0], a) for p, a in zip(c.params, args))]
        if not cands:
            if not cls.ctors and not args:
                return None
            raise Unsupported("no ctor %s/%d" % (cls.name, len(args)))
        return cands[0]

    def construct(self, cls, obj, args):
        ctor = self.pick_ctor(cls, args)
        fr = Frame(obj, cls)
        if ctor is not None:
            for (t, n), a in zip(ctor.params, args):
                fr.locals[0][n] = self.coerce(t, a)
            if ctor._ast is None:
                p = Parser(ctor.body + [Tok("eof", None)])
                p.expect("{")
                ctor._ast = p.parse_block_body()
            body = ctor._ast
        else:
            body = []
        first = body[0] if body else None
        if first and first[0] == "expr" and first[1][0] == "ctorcall":
            kind, cargs = first[1][1], [self.ev(a, fr) for a in first[1][2]]
            body = body[1:]
            if kind == "this":
                self.construct(cls, obj, cargs)
            else:
                self.super_construct(cls, obj, cargs)
                self.field_inits(cls, obj)
        else:
            self.super_construct(cls, obj, [])
            self.field_inits(cls, obj)
        try:
            for s in body:
                self.ex(s, fr)
        except _Ret:
            pass

    def super_construct(self, cls, obj, args):
        if cls.sup:
            sc = self.get_class(cls.sup)
            if sc is None:
                if args:
                    raise Unsupported("super ctor of unknown %s" % cls.sup)
                return
            self.construct(sc, obj, args)

    def field_inits(self, cls, obj):
        fr = Frame(obj, cls)
        for f in cls.fields:
            if f.init is not None:
                obj.f[f.name] = self.eval_init(f, fr)

    def invoke(self, m, this, args):
        fr = Frame(this, m.cls)
        for (t, n), a in zip(m.params, args):
            fr.locals[0][n] = self.coerce(t, a)
        return self.coerce(m.type, self.run_body(m, fr))

    def call_method(self, obj, name, args):
        """Virtual call on an interpreted object (public helper)."""
        m = self.find_method(obj.cls, name, len(args))
        if m is None:
            raise Unsupported("no method %s.%s/%d" % (obj.cls.name, name, len(args)))
        return self.invoke(m, obj, args)

    def static(self, clsname, field):
        cls = self.get_class(clsname)
        self.ensure_static(cls)
        c = self.find_static_field(cls, field)
        return c.statics[field]

    # --- conversions
    def coerce(self, t, v):
        if t is None or v is None:
            return v
        if t in ("int", "short", "long", "char"):
            if isinstance(v, bool):
                raise Unsupported("bool as int")
            return i32(int(v)) if isinstance(v, (int, float)) else v
        if t == "byte":
            v = int(v) & 0xFF
            return v - 256 if v > 127 else v
        if t in ("float", "double"):
            return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else v
        return v

    def cast(self, t, v):
        if t in ("int", "short", "long", "char", "byte"):
            if isinstance(v, float):
                v = int(v)  # truncation toward zero
            return self.coerce(t, v)
        if t in ("float", "double"):
            return float(v)
        return v

    # --- statements
    def ex(self, s, fr):
        k = s[0]
        if k == "expr":
            self.ev(s[1], fr)
        elif k == "decl":
            for t, n, init in s[1]:
                if init is None:
                    v = None
                elif init[0] == "arrlit":
                    v = [self.ev(e, fr) for e in init[1]]
                else:
                    v = self.coerce(t, self.ev(init, fr))
                fr.locals[-1][n] = v
        elif k == "return":
            raise _Ret(None if s[1] is None else self.ev(s[1], fr))
        elif k == "if":
            if self.truth(self.ev(s[1], fr)):
                self.ex_scoped(s[2], fr)
            elif s[3] is not None:
                self.ex_scoped(s[3], fr)
        elif k == "block":
            fr.locals.append({})
            try:
                for x in s[1]:
                    self.ex(x, fr)
            finally:
                fr.locals.pop()
        elif k == "while":
            n = 0
            while self.truth(self.ev(s[1], fr)):
                n += 1
                if n > 1000000:
                    raise Unsupported("loop limit")
                try:
                    self.ex_scoped(s[2], fr)
                except _Break:
                    break
                except _Continue:
                    continue
        elif k == "for":
            fr.locals.append({})
            try:
                for st in s[1]:
                    self.ex(st, fr)
                n = 0
                while s[2] is None or self.truth(self.ev(s[2], fr)):
                    n += 1
                    if n > 1000000:
                        raise Unsupported("loop limit")
                    try:
                        self.ex_scoped(s[4], fr)
                    except _Break:
                        break
                    except _Continue:
                        pass
                    for u in s[3]:
                        self.ev(u, fr)
            finally:
                fr.locals.pop()
        elif k == "throw":
            raise JavaThrow(repr(self.ev(s[1], fr)))
        elif k == "break":
            raise _Break()
        elif k == "continue":
            raise _Continue()
        else:
            raise Unsupported("stmt " + k)

    def ex_scoped(self, s, fr):
        if s[0] == "block":
            self.ex(s, fr)
        else:
            fr.locals.append({})
            try:
                self.ex(s, fr)
            finally:
                fr.locals.pop()

    @staticmethod
    def truth(v):
        if not isinstance(v, bool):
            raise Unsupported("non-boolean condition %r" % (v,))
        return v

    # --- names
    def lookup_local(self, fr, name):
        for scope in reversed(fr.locals):
            if name in scope:
                return scope
        return None

    def load_name(self, fr, name):
        sc = self.lookup_local(fr, name)
        if sc is not None:
            return sc[name]
        kind, c = self.resolve_field(fr, name)
        if kind == "inst":
            return fr.this.f[name]
        if kind == "static":
            return c.statics[name]
        cls = self.get_class(name)
        if cls is not None:
            return ClassRef(cls)
        if name[:1].isupper():
            return Stub(name, True)
        raise Unsupported("name " + name)

    def store(self, target, v, fr):
        k = target[0]
        if k == "name":
            name = target[1]
            sc = self.lookup_local(fr, name)
            if sc is not None:
                sc[name] = v
                return
            kind, c = self.resolve_field(fr, name)
            if kind == "inst":
                fr.this.f[name] = self.coerce(self.field_type(fr.this.cls, name), v)
                return
            if kind == "static":
                c.statics[name] = v
                return
            raise Unsupported("store " + name)
        if k == "field":
            base = self.ev(target[1], fr) if target[1][0] != "this" else fr.this
            if isinstance(base, JObject):
                base.f[target[2]] = self.coerce(self.field_type(base.cls, target[2]), v)
                return
            if isinstance(base, ClassRef):
                c = self.find_static_field(base.cls, target[2])
                c.statics[target[2]] = v
                return
            raise Unsupported("store field on %r" % (base,))
        if k == "index":
            arr = self.ev(target[1], fr)
            i = self.ev(target[2], fr)
            if not isinstance(arr, list):
                raise Unsupported("index store on %r" % (arr,))
            arr[i] = v
            return
        raise Unsupported("store target " + k)

    def resolve_field(self, fr, name):
        """Java simple-name lookup: walk the lexical class and its supers; private
        members of a superclass are not visible."""
        for c in self.chain(fr.cls):
            for f in c.fields:
                if f.name == name and (c is fr.cls or not f.private):
                    if fr.this is None:
                        raise Unsupported("instance field %s from static context" % name)
                    return "inst", c
            for f in c.sfields:
                if f.name == name and (c is fr.cls or not f.private):
                    self.ensure_static(c)
                    return "static", c
            if name in c.enum_consts:
                self.ensure_static(c)
                return "static", c
        return None, None

    def field_type(self, cls, name):
        for c in self.chain(cls):
            for f in c.fields:
                if f.name == name:
                    return f.type
        return None

    # --- expressions
    def ev(self, e, fr):
        k = e[0]
        if k == "lit":
            return e[1]
        if k == "name":
            return self.load_name(fr, e[1])
        if k == "this":
            return fr.this
        if k == "field":
            if e[1][0] == "super":
                return fr.this.f[e[2]]
            base = self.ev(e[1], fr)
            name = e[2]
            if name == "class" and isinstance(base, (ClassRef, Stub)):
                return Stub("Class<%s>" % (base.cls.name if isinstance(base, ClassRef) else base.name))
            if isinstance(base, JObject):
                if name in base.f:
                    return base.f[name]
                raise Unsupported("field %s.%s" % (base.cls.name, name))
            if isinstance(base, ClassRef):
                c = self.find_static_field(base.cls, name)
                if c is None:
                    inner = self.get_class(name)
                    if inner is not None:
                        return ClassRef(inner)
                    raise Unsupported("static %s.%s" % (base.cls.name, name))
                return c.statics[name]
            if isinstance(base, list) and name == "length":
                return len(base)
            if name == "class":
                return Stub("Class<%s>" % getattr(base, "name", getattr(getattr(base, "cls", None), "name", "?")))
            if hasattr(base, "java_field"):
                return base.java_field(name)
            raise Unsupported("field %s on %r" % (name, base))
        if k == "index":
            arr = self.ev(e[1], fr)
            i = self.ev(e[2], fr)
            if not isinstance(arr, list):
                raise Unsupported("index on %r" % (arr,))
            if i < 0 or i >= len(arr):
                raise JavaThrow("ArrayIndexOutOfBounds %d" % i)
            return arr[i]
        if k == "call":
            return self.ev_call(e, fr)
        if k == "new":
            cls = self.get_class(e[1])
            args = [self.ev(a, fr) for a in e[2]]
            if cls is None:
                return Stub(e[1])
            return self.new_object(cls, args)
        if k == "newarr":
            dims = [self.ev(d, fr) if d is not None else None for d in e[2]]

            def mk(level):
                n = dims[level]
                if level + 1 < len(dims) and dims[level + 1] is not None:
                    return [mk(level + 1) for _ in range(n)]
                if level + 1 < len(dims):
                    return [None] * n
                return [default_value(e[1])] * n
            return mk(0)
        if k == "newarrlit" or k == "arrlit":
            lit = e[2] if k == "newarrlit" else e
            return [self.ev(x, fr) if x[0] != "arrlit" else self.ev(x, fr) for x in lit[1]]
        if k == "cond":
            return self.ev(e[2], fr) if self.truth(self.ev(e[1], fr)) else self.ev(e[3], fr)
        if k == "un":
            v = self.ev(e[2], fr)
            op = e[1]
            if op == "!":
                return not self.truth(v)
            if op == "-":
                return i32(-v) if isinstance(v, int) else -v
            if op == "+":
                return v
            if op == "~":
                return i32(~v)
        if k == "cast":
            return self.cast(e[1], self.ev(e[2], fr))
        if k == "bin":
            return self.ev_bin(e, fr)
        if k == "assign":
            op = e[1]
            if op == "=":
                v = self.ev(e[3], fr)
            else:
                v = self.binop(op[:-1], self.ev(e[2], fr), self.ev(e[3], fr))
            self.store(e[2], v, fr)
            return v
        if k in ("preinc", "postinc"):
            old = self.ev(e[2], fr)
            new = self.binop("+" if e[1] == "++" else "-", old, 1)
            self.store(e[2], new, fr)
            return new if k == "preinc" else old
        if k == "ctorcall":
            raise Unsupported("ctor call not at start")
        if k == "type":
            return e[1]
        raise Unsupported("expr " + k)

    def ev_bin(self, e, fr):
        op = e[1]
        if op == "&&":
            return self.truth(self.ev(e[2], fr)) and self.truth(self.ev(e[3], fr))
        if op == "||":
            return self.truth(self.ev(e[2], fr)) or self.truth(self.ev(e[3], fr))
        a = self.ev(e[2], fr)
        if op == "instanceof":
            return isinstance(a, JObject) and self.is_subclass(a.cls, e[3][1])
        b = self.ev(e[3], fr)
        return self.binop(op, a, b)

    def binop(self, op, a, b):
        if op == "+" and (isinstance(a, str) or isinstance(b, str)):
            def s(x):
                if isinstance(x, bool):
                    return "true" if x else "false"
                if x is None:
                    return "null"
                return str(x)
            return s(a) + s(b)
        if op in ("==", "!="):
            if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not (isinstance(a, bool) or isinstance(b, bool)):
                r = a == b
            elif isinstance(a, bool) or isinstance(b, bool):
                r = a == b
            else:
                r = a is b
            return r if op == "==" else not r
        if isinstance(a, bool) and isinstance(b, bool) and op in ("&", "|", "^"):
            return {"&": a and b, "|": a or b, "^": a != b}[op]
        if not isinstance(a, (int, float)) or not isinstance(b, (int, float)) or isinstance(a, bool) or isinstance(b, bool):
            raise Unsupported("binop %s on %r, %r" % (op, a, b))
        ints = isinstance(a, int) and isinstance(b, int)
        if op in ("<", ">", "<=", ">="):
            return {"<": a < b, ">": a > b, "<=": a <= b, ">=": a >= b}[op]
        if op == "+":
            return i32(a + b) if ints else float(a + b)
        if op == "-":
            return i32(a - b) if ints else float(a - b)
        if op == "*":
            return i32(a * b) if ints else float(a * b)
        if op == "/":
            if ints:
                if b == 0:
                    raise JavaThrow("ArithmeticException / by zero")
                q = abs(a) // abs(b)
                return i32(q if (a >= 0) == (b >= 0) else -q)
            return a / b if b != 0 else (float("inf") if a > 0 else float("-inf") if a < 0 else float("nan"))
        if op == "%":
            if ints:
                r = abs(a) % abs(b)
                return r if a >= 0 else -r
            import math
            return math.fmod(a, b)
        if not ints:
            raise Unsupported("bit op on float")
        if op == "&":
            return i32(a & b)
        if op == "|":
            return i32(a | b)
        if op == "^":
            return i32(a ^ b)
        if op == "<<":
            return i32(a << (b & 31))
        if op == ">>":
            return i32(a >> (b & 31))
        if op == ">>>":
            return i32((a & 0xFFFFFFFF) >> (b & 31))
        raise Unsupported("op " + op)

    def ev_call(self, e, fr):
        target, name, argx = e[1], e[2], e[3]
        if target is None:
            args = [self.ev(a, fr) for a in argx]
            if fr.this is not None:
                m = self.find_method(fr.this.cls, name, len(args))
                if m is not None:
                    return self.invoke(m, None if m.static else fr.this, args)
            m = self.find_method(fr.cls, name, len(args))
            if m is not None:
                return self.invoke(m, fr.this, args)
            raise Unsupported("call %s/%d in %s" % (name, len(args), fr.cls.name))
        if target[0] == "super":
            args = [self.ev(a, fr) for a in argx]
            sc = self.get_class(fr.cls.sup)
            m = self.find_method(sc, name, len(args)) if sc else None
            if m is None:
                raise Unsupported("super.%s" % name)
            return self.invoke(m, fr.this, args)
        base = self.ev(target, fr)
        args = [self.ev(a, fr) for a in argx]
        if isinstance(base, JObject):
            m = self.find_method(base.cls, name, len(args))
            if m is None:
                raise Unsupported("method %s.%s/%d" % (base.cls.name, name, len(args)))
            return self.invoke(m, base, args)
        if isinstance(base, ClassRef):
            self.ensure_static(base.cls)
            m = self.find_method(base.cls, name, len(args))
            if m is None:
                raise Unsupported("static %s.%s" % (base.cls.name, name))
            return self.invoke(m, None, args)
        if hasattr(base, "java_call"):
            return base.java_call(name, args)
        if isinstance(base, Stub) and base.is_class:
            key = "%s.%s" % (base.name, name)
            if key in HOST_STATIC:
                return HOST_STATIC[key](*args)
            if self.opaque_prefixes and base.name.startswith(self.opaque_prefixes):
                return Stub("%s(...)" % key)
        raise Unsupported("call %s on %r" % (name, base))
