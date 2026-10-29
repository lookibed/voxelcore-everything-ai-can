#!/usr/bin/env python3
"""Olife codec generator: tools/olife/protocol/*.yaml -> Lua codecs (pack content/olife_proto/modules) +
Python codecs (tools/olife/olife_proto) + cross-language test vectors (tools/olife/protocol/vectors).

  python3 tools/olife/gen_codecs.py            # generate everything
  python3 tools/olife/gen_codecs.py --check    # fail (exit 1) if generated files are stale

Schema language (see tools/olife/README.md):
  contract, version (u8), magic (u16), max_frame (max body bytes), types: {Name: {fields: {f: T}} |
  {union: {Variant: {tag: n, fields: {...}}}}}, messages: [{id: u16, name, dir, fields: {f: T}}]
  T := u8|u16|u32|i8|i16|i32|f32|f64|bool | str<N> | bytes<N> | array<T, N> | opt<T> | TypeName
Wire: frame = magic u16 | version u8 | type u16 | length u32 | body; body = fields in order, big-endian;
  str = u16 byte length + utf-8; bytes = u32 length + raw; array = u16 count + items; opt = u8 0|1 (+ value);
  union = u8 tag + variant fields; floats must be finite; trailing bytes in a body are an error.
"""
import argparse
import json
import os
import random
import re
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
VC_ROOT = os.path.dirname(os.path.dirname(HERE))
PROTO_DIR = os.path.join(HERE, "protocol")
LUA_OUT = os.path.join(VC_ROOT, "content", "olife_proto", "modules")
PY_OUT = os.path.join(HERE, "olife_proto")
VEC_OUT = os.path.join(PROTO_DIR, "vectors")
TEMPLATES = os.path.join(HERE, "templates")
CONTRACTS = ("client", "internal", "sandbox")

INTS = {"u8": (0, 255), "u16": (0, 65535), "u32": (0, 4294967295),
        "i8": (-128, 127), "i16": (-32768, 32767), "i32": (-2147483648, 2147483647)}
PRIMS = set(INTS) | {"f32", "f64", "bool"}


# ------------------------------------------------------------------------------------------- type parser
def parse_type(s):
    s = s.strip()
    toks = re.findall(r"[A-Za-z_][A-Za-z0-9_]*|\d+|[<>,]", s)
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def take(exp=None):
        t = peek()
        if t is None or (exp is not None and t != exp):
            raise SyntaxError("type %r: expected %r at token %d, got %r" % (s, exp, pos[0], t))
        pos[0] += 1
        return t

    def num():
        t = take()
        if not t.isdigit():
            raise SyntaxError("type %r: number expected, got %r" % (s, t))
        return int(t)

    def ty():
        t = take()
        if t in PRIMS:
            return (t,)
        if t in ("str", "bytes"):
            take("<"); n = num(); take(">")
            return (t, n)
        if t == "array":
            take("<"); inner = ty(); take(","); n = num(); take(">")
            if n > 65535:
                raise SyntaxError("type %r: array max %d > 65535 (u16 count)" % (s, n))
            return ("array", inner, n)
        if t == "opt":
            take("<"); inner = ty(); take(">")
            return ("opt", inner)
        if re.match(r"^[A-Z]", t):
            return ("ref", t)
        raise SyntaxError("type %r: unknown %r" % (s, t))
    out = ty()
    if peek() is not None:
        raise SyntaxError("type %r: trailing %r" % (s, peek()))
    return out


def load_schema(name):
    path = os.path.join(PROTO_DIR, name + ".yaml")
    with open(path, encoding="utf-8") as f:
        d = yaml.safe_load(f)
    assert d["contract"] == name, path
    sch = {"contract": name, "version": int(d["version"]), "magic": int(d["magic"]),
           "max_frame": int(d["max_frame"]), "types": {}, "messages": [], "path": path}
    assert 0 < sch["version"] < 256 and 0 < sch["magic"] < 65536
    for tname, td in (d.get("types") or {}).items():
        if "union" in td:
            vs, tags = [], set()
            for vname, vd in td["union"].items():
                tag = int(vd["tag"])
                assert 0 < tag < 256 and tag not in tags, (tname, vname)
                tags.add(tag)
                vs.append({"name": vname, "tag": tag,
                           "fields": [(k, parse_type(str(v))) for k, v in (vd.get("fields") or {}).items()]})
            sch["types"][tname] = {"kind": "union", "variants": vs}
        else:
            sch["types"][tname] = {"kind": "struct",
                                   "fields": [(k, parse_type(str(v))) for k, v in (td.get("fields") or {}).items()]}
    ids, names = set(), set()
    for m in d["messages"]:
        mid = int(m["id"])
        assert 0 < mid < 65536 and mid not in ids and m["name"] not in names, m
        ids.add(mid); names.add(m["name"])
        sch["messages"].append({"id": mid, "name": m["name"], "dir": m.get("dir", "both"),
                                "fields": [(k, parse_type(str(v))) for k, v in (m.get("fields") or {}).items()]})
    # every ref resolves
    def chk(t, where):
        if t[0] == "ref":
            assert t[1] in sch["types"], "%s: unknown type %s" % (where, t[1])
        elif t[0] in ("array", "opt"):
            chk(t[1], where)
    for tn, td in sch["types"].items():
        for fl in ([v["fields"] for v in td["variants"]] if td["kind"] == "union" else [td["fields"]]):
            for k, t in fl:
                chk(t, tn + "." + k)
    for m in sch["messages"]:
        for k, t in m["fields"]:
            chk(t, m["name"] + "." + k)
    return sch


# ------------------------------------------------------------------------------------------- Lua
class LuaGen:
    def __init__(self, sch):
        self.sch = sch
        self.n = 0

    def tmp(self, p="v"):
        self.n += 1
        return "%s%d" % (p, self.n)

    def enc(self, t, v, path, ind):
        k = t[0]
        P = json.dumps(path)
        if k in INTS:
            lo, hi = INTS[k]
            return ["%sc_int(%s, %d, %d, %s); w_%s(b, %s)" % (ind, v, lo, hi, P, k, v)]
        if k in ("f32", "f64"):
            return ["%sc_%s(%s, %s); w_%s(b, %s)" % (ind, k, v, P, k, v)]
        if k == "bool":
            return ["%sc_bool(%s, %s); w_bool(b, %s)" % (ind, v, P, v)]
        if k == "str":
            return ["%sw_str(b, %s, %d, %s)" % (ind, v, t[1], P)]
        if k == "bytes":
            return ["%sw_bytes(b, %s, %d, %s)" % (ind, v, t[1], P)]
        if k == "array":
            n, i, x = self.tmp("n"), self.tmp("i"), self.tmp("x")
            out = ["%sc_table(%s, %s)" % (ind, v, P),
                   "%sdo" % ind,
                   "%s    local %s = #%s" % (ind, n, v),
                   "%s    c_count(%s, %d, %s); w_u16(b, %s)" % (ind, n, t[2], P, n),
                   "%s    for %s = 1, %s do" % (ind, i, n),
                   "%s        local %s = %s[%s]" % (ind, x, v, i)]
            out += self.enc(t[1], x, path + "[]", ind + "        ")
            out += ["%s    end" % ind, "%send" % ind]
            return out
        if k == "opt":
            out = ["%sif %s == nil then w_u8(b, 0) else" % (ind, v), "%s    w_u8(b, 1)" % ind]
            out += self.enc(t[1], v, path, ind + "    ")
            out += ["%send" % ind]
            return out
        if k == "ref":
            return ["%se_%s(b, %s)" % (ind, t[1], v)]
        raise AssertionError(t)

    def dec(self, t, target, path, ind):
        k = t[0]
        P = json.dumps(path)
        if k in INTS or k in ("f32", "f64", "bool"):
            return ["%s%s = r_%s(r, %s)" % (ind, target, k, P)]
        if k in ("str", "bytes"):
            return ["%s%s = r_%s(r, %d, %s)" % (ind, target, k, t[1], P)]
        if k == "array":
            n, i, a = self.tmp("n"), self.tmp("i"), self.tmp("a")
            out = ["%sdo" % ind,
                   "%s    local %s = r_count(r, %d, %s)" % (ind, n, t[2], P),
                   "%s    local %s = {}" % (ind, a),
                   "%s    for %s = 1, %s do" % (ind, i, n)]
            out += self.dec(t[1], "%s[%s]" % (a, i), path + "[]", ind + "        ")
            out += ["%s    end" % ind, "%s    %s = %s" % (ind, target, a), "%send" % ind]
            return out
        if k == "opt":
            f = self.tmp("f")
            out = ["%sdo" % ind, "%s    local %s = r_u8(r, %s)" % (ind, f, P),
                   "%s    if %s == 1 then" % (ind, f)]
            out += self.dec(t[1], target, path, ind + "        ")
            out += ["%s    elseif %s ~= 0 then fail(%s, \"bad opt flag \" .. %s) end" % (ind, f, P, f),
                    "%send" % ind]
            return out
        if k == "ref":
            return ["%s%s = d_%s(r)" % (ind, target, t[1])]
        raise AssertionError(t)

    def fields_enc(self, fields, owner, ind):
        out = []
        for name, t in fields:
            v = self.tmp("v")
            out.append("%slocal %s = m.%s" % (ind, v, name))
            out += self.enc(t, v, "%s.%s" % (owner, name), ind)
        return out

    def fields_dec(self, fields, owner, ind):
        out = []
        for name, t in fields:
            out += self.dec(t, "m.%s" % name, "%s.%s" % (owner, name), ind)
        return out

    def type_order(self):
        # definition order: dependencies first (Lua locals must be declared before use)
        order, seen = [], set()
        types = self.sch["types"]

        def deps(t, acc):
            if t[0] == "ref":
                acc.add(t[1])
            elif t[0] in ("array", "opt"):
                deps(t[1], acc)

        def visit(n, stack=()):
            if n in seen:
                return
            assert n not in stack, "recursive type %s" % n
            td = types[n]
            acc = set()
            for fl in ([v["fields"] for v in td["variants"]] if td["kind"] == "union" else [td["fields"]]):
                for _, t in fl:
                    deps(t, acc)
            for d in sorted(acc):
                visit(d, stack + (n,))
            seen.add(n)
            order.append(n)
        for n in types:
            visit(n)
        return order

    def module(self, header):
        s = self.sch
        L = [header,
             'local W = require "olife_proto:wire"',
             "local fail, c_int, c_f32, c_f64, c_bool, c_table, c_count = W.fail, W.c_int, W.c_f32, W.c_f64, "
             "W.c_bool, W.c_table, W.c_count",
             "local w_u8, w_u16, w_u32, w_i8, w_i16, w_i32 = W.w_u8, W.w_u16, W.w_u32, W.w_i8, W.w_i16, W.w_i32",
             "local w_f32, w_f64, w_bool, w_str, w_bytes = W.w_f32, W.w_f64, W.w_bool, W.w_str, W.w_bytes",
             "local r_u8, r_u16, r_u32, r_i8, r_i16, r_i32 = W.r_u8, W.r_u16, W.r_u32, W.r_i8, W.r_i16, W.r_i32",
             "local r_f32, r_f64, r_bool, r_str, r_bytes, r_count = W.r_f32, W.r_f64, W.r_bool, W.r_str, "
             "W.r_bytes, W.r_count",
             "local type = type",
             "",
             "local M = {contract = %s, version = %d, magic = %d, max_frame = %d}" % (
                 json.dumps(s["contract"]), s["version"], s["magic"], s["max_frame"]),
             "M.ids, M.names, M.dirs, M.known = {}, {}, {}, {}"]
        for m in s["messages"]:
            L.append("M.ids.%s = %d; M.names[%d] = %s; M.dirs[%d] = %s; M.known[%d] = true" % (
                m["name"], m["id"], m["id"], json.dumps(m["name"]), m["id"], json.dumps(m["dir"]), m["id"]))
        L.append("")
        L.append("-- types")
        for tn in self.type_order():
            td = s["types"][tn]
            L.append("local e_%s, d_%s" % (tn, tn))
            if td["kind"] == "struct":
                L.append("function e_%s(b, m)" % tn)
                L.append('    c_table(m, "%s")' % tn)
                L += self.fields_enc(td["fields"], tn, "    ")
                L.append("end")
                L.append("function d_%s(r)" % tn)
                L.append("    local m = {}")
                L += self.fields_dec(td["fields"], tn, "    ")
                L.append("    return m")
                L.append("end")
            else:
                L.append("function e_%s(b, m)" % tn)
                L.append('    c_table(m, "%s")' % tn)
                L.append("    local k = m.kind")
                first = True
                for v in td["variants"]:
                    L.append("    %s k == %s then" % ("if" if first else "elseif", json.dumps(v["name"])))
                    first = False
                    L.append("        w_u8(b, %d)" % v["tag"])
                    L += self.fields_enc(v["fields"], "%s.%s" % (tn, v["name"]), "        ")
                L.append('    else fail("%s.kind", "unknown variant " .. tostring(k)) end' % tn)
                L.append("end")
                L.append("function d_%s(r)" % tn)
                L.append('    local tag = r_u8(r, "%s.kind")' % tn)
                L.append("    local m = {}")
                first = True
                for v in td["variants"]:
                    L.append("    %s tag == %d then" % ("if" if first else "elseif", v["tag"]))
                    first = False
                    L.append("        m.kind = %s" % json.dumps(v["name"]))
                    L += self.fields_dec(v["fields"], "%s.%s" % (tn, v["name"]), "        ")
                L.append('    else fail("%s.kind", "unknown tag " .. tag) end' % tn)
                L.append("    return m")
                L.append("end")
            L.append("M.e_%s, M.d_%s = e_%s, d_%s" % (tn, tn, tn, tn))
        L.append("")
        L.append("-- messages: E[id](b, msg) appends the body, D[id](r) reads it")
        L.append("local E, D = {}, {}")
        L.append("M.E, M.D = E, D")
        for m in s["messages"]:
            L.append("-- %d %s (%s)" % (m["id"], m["name"], m["dir"]))
            L.append("E[%d] = function(b, m)" % m["id"])
            L.append('    c_table(m, "%s")' % m["name"])
            L += self.fields_enc(m["fields"], m["name"], "    ")
            L.append("end")
            L.append("D[%d] = function(r)" % m["id"])
            L.append("    local m = {}")
            L += self.fields_dec(m["fields"], m["name"], "    ")
            L.append("    return m")
            L.append("end")
        L.append(LUA_TAIL)
        return "\n".join(L) + "\n"


LUA_TAIL = r'''
local function id_of(name_or_id)
    local id = type(name_or_id) == "number" and name_or_id or M.ids[name_or_id]
    if id == nil or E[id] == nil then fail(M.contract, "unknown message " .. tostring(name_or_id)) end
    return id
end
M.id_of = id_of

-- append the body of a message to Bytearray b (no header); raises on a type/range error
function M.encode_body(b, name_or_id, msg)
    E[id_of(name_or_id)](b, msg)
    return b
end

-- body of one message as a new Bytearray
function M.body(name_or_id, msg)
    local b = Bytearray()
    E[id_of(name_or_id)](b, msg)
    return b
end

-- decode a body: bytes[s..e] (1-based, inclusive; default whole array); raises on any error
function M.decode_body(id, bytes, s, e)
    local d = D[id]
    if d == nil then fail(M.contract, "unknown type " .. tostring(id)) end
    local r = {b = bytes, p = s or 1, e = e or #bytes}
    local m = d(r)
    if r.p ~= r.e + 1 then fail(M.names[id], "trailing bytes: " .. (r.e + 1 - r.p)) end
    return m
end

-- append a whole frame (header + body) to b; returns body length
function M.append_frame(b, name_or_id, msg)
    local id = id_of(name_or_id)
    return W.append_frame(b, M.magic, M.version, id, E[id], msg)
end

-- frame of a pre-encoded body (Bytearray) of message id
function M.append_raw(b, id, body)
    local n = #body
    if n > M.max_frame then fail(M.names[id] or tostring(id), "frame too large " .. n) end
    w_u16(b, M.magic); w_u8(b, M.version); w_u16(b, id); w_u32(b, n)
    if n > 0 then b:append(body) end
end

function M.framer(max)
    return W.framer(M.magic, M.version, max or M.max_frame, M.known)
end

-- next decoded message of a framer: name, msg, id | nil (need more) | false, reason (drop the connection)
function M.read(fr)
    local id, s, e = fr:next()
    if not id then return id, s end
    local ok, m = pcall(M.decode_body, id, fr.buf, s, e)
    if not ok then return false, tostring(m) end
    return M.names[id], m, id
end

-- next raw frame: id, body (Bytearray copy) | nil | false, reason
function M.read_raw(fr)
    local id, s, e = fr:next()
    if not id then return id, s end
    if e < s then return id, Bytearray() end
    return id, fr.buf:slice(s, e - s + 1)
end

return M
'''


# ------------------------------------------------------------------------------------------- Python
class PyGen:
    def __init__(self, sch):
        self.sch = sch
        self.n = 0

    def tmp(self, p="v"):
        self.n += 1
        return "%s%d" % (p, self.n)

    def enc(self, t, v, path, ind):
        k = t[0]
        P = repr(path)
        if k in INTS:
            lo, hi = INTS[k]
            return ["%sw_%s(b, c_int(%s, %d, %d, %s))" % (ind, k, v, lo, hi, P)]
        if k in ("f32", "f64"):
            return ["%sc_%s(%s, %s); w_%s(b, %s)" % (ind, k, v, P, k, v)]
        if k == "bool":
            return ["%sc_bool(%s, %s); w_bool(b, %s)" % (ind, v, P, v)]
        if k in ("str", "bytes"):
            return ["%sw_%s(b, %s, %d, %s)" % (ind, k, v, t[1], P)]
        if k == "array":
            x = self.tmp("x")
            out = ["%sif not isinstance(%s, (list, tuple)): fail(%s, 'expected list')" % (ind, v, P),
                   "%sc_count(len(%s), %d, %s); w_u16(b, len(%s))" % (ind, v, t[2], P, v),
                   "%sfor %s in %s:" % (ind, x, v)]
            out += self.enc(t[1], x, path + "[]", ind + "    ")
            return out
        if k == "opt":
            out = ["%sif %s is None:" % (ind, v), "%s    w_u8(b, 0)" % ind, "%selse:" % ind, "%s    w_u8(b, 1)" % ind]
            out += self.enc(t[1], v, path, ind + "    ")
            return out
        if k == "ref":
            return ["%se_%s(b, %s)" % (ind, t[1], v)]
        raise AssertionError(t)

    def dec(self, t, target, path, ind):
        k = t[0]
        P = repr(path)
        if k in INTS or k in ("f32", "f64", "bool"):
            return ["%s%s = r_%s(r, %s)" % (ind, target, k, P)]
        if k in ("str", "bytes"):
            return ["%s%s = r_%s(r, %d, %s)" % (ind, target, k, t[1], P)]
        if k == "array":
            a, x = self.tmp("a"), self.tmp("x")
            out = ["%s%s = []" % (ind, a), "%sfor _ in range(r_count(r, %d, %s)):" % (ind, t[2], P)]
            out += self.dec(t[1], x, path + "[]", ind + "    ")
            out += ["%s    %s.append(%s)" % (ind, a, x), "%s%s = %s" % (ind, target, a)]
            return out
        if k == "opt":
            f = self.tmp("f")
            out = ["%s%s = r_u8(r, %s)" % (ind, f, P), "%sif %s == 1:" % (ind, f)]
            out += self.dec(t[1], target, path, ind + "    ")
            out += ["%selif %s == 0:" % (ind, f), "%s    %s = None" % (ind, target),
                    "%selse:" % ind, "%s    fail(%s, 'bad opt flag %%d' %% %s)" % (ind, P, f)]
            return out
        if k == "ref":
            return ["%s%s = d_%s(r)" % (ind, target, t[1])]
        raise AssertionError(t)

    def fields_enc(self, fields, owner, ind):
        out = []
        for name, t in fields:
            v = self.tmp("v")
            out.append("%s%s = m.get(%r)" % (ind, v, name))
            out += self.enc(t, v, "%s.%s" % (owner, name), ind)
        return out

    def fields_dec(self, fields, owner, ind):
        out = []
        for name, t in fields:
            out += self.dec(t, "m[%r]" % name, "%s.%s" % (owner, name), ind)
        return out

    def module(self, header):
        s = self.sch
        L = [header, "from .wire import *  # noqa: F401,F403", "from . import wire as W", "",
             "CONTRACT = %r" % s["contract"], "VERSION = %d" % s["version"], "MAGIC = 0x%04X" % s["magic"],
             "MAX_FRAME = %d" % s["max_frame"],
             "IDS = %r" % {m["name"]: m["id"] for m in s["messages"]},
             "NAMES = {v: k for k, v in IDS.items()}",
             "DIRS = %r" % {m["name"]: m["dir"] for m in s["messages"]}, ""]
        for tn, td in s["types"].items():
            L.append("def e_%s(b, m):" % tn)
            L.append("    c_dict(m, %r)" % tn)
            if td["kind"] == "struct":
                L += self.fields_enc(td["fields"], tn, "    ") or ["    pass"]
            else:
                L.append("    k = m.get('kind')")
                first = True
                for v in td["variants"]:
                    L.append("    %s k == %r:" % ("if" if first else "elif", v["name"]))
                    first = False
                    L.append("        w_u8(b, %d)" % v["tag"])
                    L += self.fields_enc(v["fields"], "%s.%s" % (tn, v["name"]), "        ")
                L.append("    else:")
                L.append("        fail(%r, 'unknown variant %%r' %% (k,))" % (tn + ".kind"))
            L.append("")
            L.append("def d_%s(r):" % tn)
            L.append("    m = {}")
            if td["kind"] == "struct":
                L += self.fields_dec(td["fields"], tn, "    ")
            else:
                L.append("    tag = r_u8(r, %r)" % (tn + ".kind"))
                first = True
                for v in td["variants"]:
                    L.append("    %s tag == %d:" % ("if" if first else "elif", v["tag"]))
                    first = False
                    L.append("        m['kind'] = %r" % v["name"])
                    L += self.fields_dec(v["fields"], "%s.%s" % (tn, v["name"]), "        ")
                L.append("    else:")
                L.append("        fail(%r, 'unknown tag %%d' %% tag)" % (tn + ".kind"))
            L.append("    return m")
            L.append("")
        L.append("E, D = {}, {}")
        L.append("")
        for m in s["messages"]:
            L.append("def _e_%s(b, m):" % m["name"])
            L.append("    c_dict(m, %r)" % m["name"])
            L += self.fields_enc(m["fields"], m["name"], "    ") or ["    pass"]
            L.append("")
            L.append("def _d_%s(r):" % m["name"])
            L.append("    m = {}")
            L += self.fields_dec(m["fields"], m["name"], "    ")
            L.append("    return m")
            L.append("")
            L.append("E[%d], D[%d] = _e_%s, _d_%s" % (m["id"], m["id"], m["name"], m["name"]))
            L.append("")
        L.append(PY_TAIL)
        return "\n".join(L) + "\n"


PY_TAIL = r'''
def id_of(name_or_id):
    mid = name_or_id if isinstance(name_or_id, int) else IDS.get(name_or_id)
    if mid not in E:
        raise ProtoError("olife_proto: %s: unknown message %r" % (CONTRACT, name_or_id))
    return mid


def body(name_or_id, msg):
    b = bytearray()
    E[id_of(name_or_id)](b, msg)
    return bytes(b)


def decode_body(mid, data, s=0, e=None):
    if mid not in D:
        raise ProtoError("olife_proto: %s: unknown type %r" % (CONTRACT, mid))
    r = Reader(data, s, e)
    m = D[mid](r)
    if r.p != r.e:
        raise ProtoError("olife_proto: %s: trailing bytes: %d" % (NAMES[mid], r.e - r.p))
    return m


def frame(name_or_id, msg):
    mid = id_of(name_or_id)
    bd = body(mid, msg)
    if len(bd) > MAX_FRAME:
        raise ProtoError("olife_proto: %s: frame too large %d" % (NAMES[mid], len(bd)))
    return W.header(MAGIC, VERSION, mid, len(bd)) + bd


def frame_raw(mid, bd):
    if len(bd) > MAX_FRAME:
        raise ProtoError("olife_proto: frame too large %d" % len(bd))
    return W.header(MAGIC, VERSION, mid, len(bd)) + bytes(bd)


def framer(mx=None):
    return W.Framer(MAGIC, VERSION, mx or MAX_FRAME, set(D))
'''


# ------------------------------------------------------------------------------------------- Rust
RUST_KW = {"as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn", "for", "if", "impl",
           "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
           "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while", "async", "await", "dyn",
           "abstract", "become", "box", "do", "final", "macro", "override", "priv", "typeof", "unsized", "virtual",
           "yield", "try"}
RUST_INT = {"u8": "u8", "u16": "u16", "u32": "u32", "i8": "i8", "i16": "i16", "i32": "i32"}


def rid(name):
    return "r#" + name if name in RUST_KW else name


def snake_upper(name):
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"_\1", name).upper()


class RustGen:
    """Typed codecs: struct per type/message (serde for the JSON test vectors), enum per union (serde tag "kind"),
    enum Msg per contract with id/name/dir, encode_body/decode_body/frame, strict checks of templates/wire.rs."""

    def __init__(self, sch):
        self.sch = sch
        self.n = 0

    def tmp(self, p):
        self.n += 1
        return "%s%d" % (p, self.n)

    def rtype(self, t):
        k = t[0]
        if k in RUST_INT:
            return RUST_INT[k]
        if k in ("f32", "f64", "bool"):
            return k
        if k == "str":
            return "String"
        if k == "bytes":
            return "Bytes"
        if k == "array":
            return "Vec<%s>" % self.rtype(t[1])
        if k == "opt":
            return "Option<%s>" % self.rtype(t[1])
        if k == "ref":
            return t[1]
        raise AssertionError(t)

    def enc(self, t, e, path, ind):
        """e: place expression of the value (copyable for primitives, borrowable otherwise)"""
        k = t[0]
        P = json.dumps(path)
        if k in RUST_INT:
            return ["%sw_%s(b, %s);" % (ind, k, e)]
        if k in ("f32", "f64"):
            return ["%sw_%s(b, %s, %s)?;" % (ind, k, e, P)]
        if k == "bool":
            return ["%sw_bool(b, %s);" % (ind, e)]
        if k == "str":
            return ["%sw_str(b, &%s, %d, %s)?;" % (ind, e, t[1], P)]
        if k == "bytes":
            return ["%sw_bytes(b, &%s, %d, %s)?;" % (ind, e, t[1], P)]
        if k == "array":
            x = self.tmp("x")
            out = ["%sc_count(%s.len(), %d, %s)?;" % (ind, e, t[2], P),
                   "%sw_u16(b, %s.len() as u16);" % (ind, e),
                   "%sfor %s in %s.iter() {" % (ind, x, e)]
            out += self.enc(t[1], "(*%s)" % x, path + "[]", ind + "    ")
            out.append("%s}" % ind)
            return out
        if k == "opt":
            x = self.tmp("o")
            out = ["%smatch &%s {" % (ind, e), "%s    None => w_u8(b, 0)," % ind,
                   "%s    Some(%s) => {" % (ind, x), "%s        w_u8(b, 1);" % ind]
            out += self.enc(t[1], "(*%s)" % x, path, ind + "        ")
            out += ["%s    }" % ind, "%s}" % ind]
            return out
        if k == "ref":
            return ["%s%s.enc(b)?;" % (ind, e)]
        raise AssertionError(t)

    def dec(self, t, path):
        """-> Rust expression reading one value from `r` (uses ? inside blocks)"""
        k = t[0]
        P = json.dumps(path)
        if k in RUST_INT or k in ("f32", "f64", "bool"):
            return "r.%s(%s)?" % (k, P)
        if k in ("str", "bytes"):
            return "r.%s(%d, %s)?" % (k, t[1], P)
        if k == "array":
            n, a = self.tmp("n"), self.tmp("a")
            return ("{ let %s = r.count(%d, %s)?; let mut %s = Vec::with_capacity(%s.min(1024)); "
                    "for _ in 0..%s { %s.push(%s); } %s }" % (n, t[2], P, a, n, n, a, self.dec(t[1], path + "[]"), a))
        if k == "opt":
            f = self.tmp("f")
            return ("match r.u8(%s)? { 0 => None, 1 => Some(%s), %s => return fail(%s, format!(\"bad opt flag {}\", %s)) }"
                    % (P, self.dec(t[1], path), f, P, f))
        if k == "ref":
            return "%s::dec(r)?" % t[1]
        raise AssertionError(t)

    def struct(self, name, fields, doc):
        L = ["/// %s" % doc, "#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]", "pub struct %s {" % name]
        for f, t in fields:
            L.append("    pub %s: %s," % (rid(f), self.rtype(t)))
        L.append("}")
        L.append("impl %s {" % name)
        L.append("    pub fn enc(&self, b: &mut Vec<u8>) -> R<()> {")
        for f, t in fields:
            L += self.enc(t, "self.%s" % rid(f), "%s.%s" % (name, f), "        ")
        if not fields:
            L.append("        let _ = b;")
        L.append("        Ok(())")
        L.append("    }")
        L.append("    pub fn dec(r: &mut Reader) -> R<Self> {")
        if not fields:
            L.append("        let _ = r;")
        L.append("        Ok(%s {" % name)
        for f, t in fields:
            L.append("            %s: %s," % (rid(f), self.dec(t, "%s.%s" % (name, f))))
        L.append("        })")
        L.append("    }")
        L.append("}")
        return L

    def union(self, name, variants):
        L = ["/// union %s: u8 tag + variant fields (JSON: {\"kind\": variant, ...})" % name,
             "#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]", "#[serde(tag = \"kind\")]",
             "pub enum %s {" % name]
        for v in variants:
            L.append("    %s { %s }," % (v["name"], ", ".join("%s: %s" % (rid(f), self.rtype(t)) for f, t in v["fields"])))
        L.append("}")
        L.append("impl %s {" % name)
        L.append("    pub fn enc(&self, b: &mut Vec<u8>) -> R<()> {")
        L.append("        match self {")
        for v in variants:
            binds = ", ".join("%s: f_%s" % (rid(f), f) for f, _ in v["fields"])
            L.append("            %s::%s { %s } => {" % (name, v["name"], binds))
            L.append("                w_u8(b, %d);" % v["tag"])
            for f, t in v["fields"]:
                L += self.enc(t, "(*f_%s)" % f, "%s.%s.%s" % (name, v["name"], f), "                ")
            L.append("            }")
        L.append("        }")
        L.append("        Ok(())")
        L.append("    }")
        L.append("    pub fn dec(r: &mut Reader) -> R<Self> {")
        L.append("        let tag = r.u8(%s)?;" % json.dumps(name + ".kind"))
        L.append("        Ok(match tag {")
        for v in variants:
            L.append("            %d => %s::%s {" % (v["tag"], name, v["name"]))
            for f, t in v["fields"]:
                L.append("                %s: %s," % (rid(f), self.dec(t, "%s.%s.%s" % (name, v["name"], f))))
            L.append("            },")
        L.append("            t => return fail(%s, format!(\"unknown tag {}\", t))," % json.dumps(name + ".kind"))
        L.append("        })")
        L.append("    }")
        L.append("}")
        return L

    def module(self, header):
        s = self.sch
        ms = s["messages"]
        L = [header, "#![allow(clippy::all, unused_mut, unused_variables, unused_parens, non_snake_case)]",
             "use super::wire::*;", "use serde::{Deserialize, Serialize};", "",
             "pub const CONTRACT: &str = %s;" % json.dumps(s["contract"]),
             "pub const VERSION: u8 = %d;" % s["version"],
             "pub const MAGIC: u16 = 0x%04X;" % s["magic"],
             "pub const MAX_FRAME: u32 = %d;" % s["max_frame"], "",
             "/// message ids", "pub mod ids {"]
        for m in ms:
            L.append("    pub const %s: u16 = %d;" % (snake_upper(m["name"]), m["id"]))
        L.append("}")
        L.append("")
        L.append("pub fn is_known(id: u16) -> bool {")
        L.append("    matches!(id, %s)" % " | ".join(str(m["id"]) for m in ms))
        L.append("}")
        L.append("pub fn name_of(id: u16) -> Option<&'static str> {")
        L.append("    Some(match id {")
        for m in ms:
            L.append("        %d => %s," % (m["id"], json.dumps(m["name"])))
        L.append("        _ => return None,")
        L.append("    })")
        L.append("}")
        L.append("pub fn id_of(name: &str) -> Option<u16> {")
        L.append("    Some(match name {")
        for m in ms:
            L.append("        %s => %d," % (json.dumps(m["name"]), m["id"]))
        L.append("        _ => return None,")
        L.append("    })")
        L.append("}")
        L.append("/// direction from the schema (\"c2s\", \"s2c\", \"g2w\", \"w2g\", \"w2s\", \"s2w\", \"both\")")
        L.append("pub fn dir_of(id: u16) -> Option<&'static str> {")
        L.append("    Some(match id {")
        for m in ms:
            L.append("        %d => %s," % (m["id"], json.dumps(m["dir"])))
        L.append("        _ => return None,")
        L.append("    })")
        L.append("}")
        L.append("")
        L.append("// ------------------------------------------------------------ types")
        for tn, td in s["types"].items():
            if td["kind"] == "struct":
                L += self.struct(tn, td["fields"], "type %s" % tn)
            else:
                L += self.union(tn, td["variants"])
            L.append("")
        L.append("// ------------------------------------------------------------ messages")
        for m in ms:
            L += self.struct(m["name"], m["fields"], "%d %s (%s)" % (m["id"], m["name"], m["dir"]))
            L.append("")
        L.append("/// one message of contract %s" % s["contract"])
        L.append("#[derive(Debug, Clone, PartialEq)]")
        L.append("pub enum Msg {")
        for m in ms:
            L.append("    %s(%s)," % (m["name"], m["name"]))
        L.append("}")
        L.append("impl Msg {")
        L.append("    pub fn id(&self) -> u16 {")
        L.append("        match self {")
        for m in ms:
            L.append("            Msg::%s(_) => %d," % (m["name"], m["id"]))
        L.append("        }")
        L.append("    }")
        L.append("    pub fn name(&self) -> &'static str {")
        L.append("        name_of(self.id()).unwrap_or(\"?\")")
        L.append("    }")
        L.append("    pub fn dir(&self) -> &'static str {")
        L.append("        dir_of(self.id()).unwrap_or(\"?\")")
        L.append("    }")
        L.append("    /// append the body (no header); errors leave `b` in an unspecified state — use body()/frame()")
        L.append("    pub fn encode_body(&self, b: &mut Vec<u8>) -> R<()> {")
        L.append("        match self {")
        for m in ms:
            L.append("            Msg::%s(m) => m.enc(b)," % m["name"])
        L.append("        }")
        L.append("    }")
        L.append("    pub fn body(&self) -> R<Vec<u8>> {")
        L.append("        let mut b = Vec::new();")
        L.append("        self.encode_body(&mut b)?;")
        L.append("        Ok(b)")
        L.append("    }")
        L.append("    /// whole frame: header + body; body over MAX_FRAME is an error")
        L.append("    pub fn frame(&self) -> R<Vec<u8>> {")
        L.append("        let mut b = Vec::with_capacity(64);")
        L.append("        b.extend_from_slice(&[0u8; HEADER]);")
        L.append("        self.encode_body(&mut b)?;")
        L.append("        let n = b.len() - HEADER;")
        L.append("        if n > MAX_FRAME as usize {")
        L.append("            return fail(self.name(), format!(\"frame too large {}\", n));")
        L.append("        }")
        L.append("        b[..HEADER].copy_from_slice(&header(MAGIC, VERSION, self.id(), n as u32));")
        L.append("        Ok(b)")
        L.append("    }")
        L.append("    /// strict decode of a body: unknown type, truncation, trailing bytes, ranges -> error")
        L.append("    pub fn decode_body(id: u16, body: &[u8]) -> R<Msg> {")
        L.append("        let mut r = Reader::new(body);")
        L.append("        let m = match id {")
        for m in ms:
            L.append("            %d => Msg::%s(%s::dec(&mut r)?)," % (m["id"], m["name"], m["name"]))
        L.append("            _ => return fail(CONTRACT, format!(\"unknown type {}\", id)),")
        L.append("        };")
        L.append("        r.finish(name_of(id).unwrap_or(CONTRACT))?;")
        L.append("        Ok(m)")
        L.append("    }")
        L.append("    /// message from its JSON form (test vectors): {field: value}, bytes as {\"$bytes\": hex}")
        L.append("    pub fn from_json(name: &str, v: &serde_json::Value) -> R<Msg> {")
        L.append("        let e = |x: serde_json::Error| ProtoError(format!(\"olife_proto: {}: json: {}\", name, x));")
        L.append("        Ok(match name {")
        for m in ms:
            L.append("            %s => Msg::%s(serde_json::from_value(v.clone()).map_err(e)?)," % (
                json.dumps(m["name"]), m["name"]))
        L.append("            _ => return fail(CONTRACT, format!(\"unknown message {}\", name)),")
        L.append("        })")
        L.append("    }")
        L.append("    pub fn to_json(&self) -> serde_json::Value {")
        L.append("        match self {")
        for m in ms:
            L.append("            Msg::%s(m) => serde_json::to_value(m).unwrap_or(serde_json::Value::Null)," % m["name"])
        L.append("        }")
        L.append("    }")
        L.append("}")
        L.append("")
        for m in ms:
            L.append("impl From<%s> for Msg {" % m["name"])
            L.append("    fn from(m: %s) -> Msg {" % m["name"])
            L.append("        Msg::%s(m)" % m["name"])
            L.append("    }")
            L.append("}")
        L.append("")
        L.append("/// frame of a pre-encoded body of message `id` (forwarding without re-encoding)")
        L.append("pub fn frame_raw(id: u16, body: &[u8]) -> R<Vec<u8>> {")
        L.append("    if body.len() > MAX_FRAME as usize {")
        L.append("        return fail(CONTRACT, format!(\"frame too large {}\", body.len()));")
        L.append("    }")
        L.append("    let mut b = Vec::with_capacity(HEADER + body.len());")
        L.append("    b.extend_from_slice(&header(MAGIC, VERSION, id, body.len() as u32));")
        L.append("    b.extend_from_slice(body);")
        L.append("    Ok(b)")
        L.append("}")
        L.append("")
        L.append("/// stream framer of this contract; `max` lowers the body limit (e.g. 64 KiB for client->gateway)")
        L.append("pub fn framer(max: Option<u32>) -> Framer {")
        L.append("    Framer::new(MAGIC, VERSION, max.unwrap_or(MAX_FRAME), is_known)")
        L.append("}")
        return "\n".join(L) + "\n"


# ------------------------------------------------------------------------------------------- vectors
def sample(sch, t, rng, mode):
    k = t[0]
    if k in INTS:
        lo, hi = INTS[k]
        if mode == "lo":
            return lo
        if mode == "hi":
            return hi
        return rng.randint(lo, hi)
    if k == "f32":
        return rng.randint(-80000, 80000) / 8.0
    if k == "f64":
        return rng.randint(-10 ** 12, 10 ** 12) / 1024.0
    if k == "bool":
        return mode == "hi" or (mode == "rnd" and rng.random() < 0.5)
    if k == "str":
        if mode == "lo":
            return ""
        alpha = "abcxyz09 _-é жЖ€"
        s = "".join(rng.choice(alpha) for _ in range(rng.randint(1, 10)))
        while len(s.encode()) > t[1]:
            s = s[:-1]
        return s
    if k == "bytes":
        if mode == "lo":
            return b""
        return bytes(rng.randint(0, 255) for _ in range(min(t[1], rng.randint(1, 40))))
    if k == "array":
        n = 0 if mode == "lo" else (min(t[2], 3) if mode == "hi" else rng.randint(0, min(t[2], 3)))
        return [sample(sch, t[1], rng, "rnd" if mode != "lo" else mode) for _ in range(n)]
    if k == "opt":
        if mode == "lo" or (mode == "rnd" and rng.random() < 0.4):
            return None
        return sample(sch, t[1], rng, mode)
    if k == "ref":
        td = sch["types"][t[1]]
        if td["kind"] == "struct":
            return {f: sample(sch, ft, rng, mode) for f, ft in td["fields"]}
        v = rng.choice(td["variants"]) if mode == "rnd" else td["variants"][0 if mode == "lo" else -1]
        out = {"kind": v["name"]}
        out.update({f: sample(sch, ft, rng, mode) for f, ft in v["fields"]})
        return out
    raise AssertionError(t)


def to_json(v):
    if isinstance(v, (bytes, bytearray)):
        return {"$bytes": bytes(v).hex()}
    if isinstance(v, dict):
        return {k: to_json(x) for k, x in v.items()}
    if isinstance(v, list):
        return [to_json(x) for x in v]
    return v


def vectors(sch, codec):
    rng = random.Random("olife:" + sch["contract"])
    out = []
    for m in sch["messages"]:
        for mode in ("lo", "hi", "rnd", "rnd"):
            v = {f: sample(sch, t, rng, mode) for f, t in m["fields"]}
            fr = codec.frame(m["name"], v)
            out.append({"name": m["name"], "id": m["id"], "mode": mode, "value": to_json(v), "frame": fr.hex()})
    return out


# ------------------------------------------------------------------------------------------- main
def header_comment(prefix, sch):
    rel = os.path.relpath(sch["path"], VC_ROOT).replace(os.sep, "/")
    return ("%s GENERATED by tools/olife/gen_codecs.py from %s (contract %s v%d) — do not edit.\n"
            "%s Regenerate: python3 tools/olife/gen_codecs.py" % (prefix, rel, sch["contract"], sch["version"],
                                                                prefix))


def render():
    files = {}
    with open(os.path.join(TEMPLATES, "wire.lua"), encoding="utf-8") as f:
        files[os.path.join(LUA_OUT, "wire.lua")] = ("-- GENERATED by tools/olife/gen_codecs.py from "
                                                    "tools/olife/templates/wire.lua — do not edit.\n" + f.read())
    with open(os.path.join(TEMPLATES, "wire.py"), encoding="utf-8") as f:
        files[os.path.join(PY_OUT, "wire.py")] = ("# GENERATED by tools/olife/gen_codecs.py from "
                                                  "tools/olife/templates/wire.py — do not edit.\n" + f.read())
    files[os.path.join(PY_OUT, "__init__.py")] = ('"""Olife protocol codecs (generated by tools/olife/gen_codecs.py)."""\n'
                                                  "from . import wire, %s  # noqa: F401\n" % ", ".join(CONTRACTS))
    schemas = {c: load_schema(c) for c in CONTRACTS}
    for c, sch in schemas.items():
        files[os.path.join(LUA_OUT, c + ".lua")] = LuaGen(sch).module(header_comment("--", sch))
        files[os.path.join(PY_OUT, c + ".py")] = PyGen(sch).module(header_comment("#", sch))
    return files, schemas


def render_rust(out):
    """Rust codecs for the production gateway (<olife-src>/gateway): <out>/{mod,wire,client,internal,sandbox}.rs +
    a copy of the cross-language vectors (<out>/vectors/*.json) for the Rust tests (byte-for-byte)."""
    files = {}
    with open(os.path.join(TEMPLATES, "wire.rs"), encoding="utf-8") as f:
        files[os.path.join(out, "wire.rs")] = ("// GENERATED by tools/olife/gen_codecs.py --lang rust from "
                                               "tools/olife/templates/wire.rs — do not edit.\n" + f.read())
    files[os.path.join(out, "mod.rs")] = (
        "// GENERATED by tools/olife/gen_codecs.py --lang rust — do not edit.\n"
        "//! Olife protocol codecs generated from tools/olife/protocol/*.yaml (same schema as the Lua/Python codecs).\n"
        + "".join("pub mod %s;\n" % m for m in ("wire",) + CONTRACTS))
    schemas = {c: load_schema(c) for c in CONTRACTS}
    for c, sch in schemas.items():
        files[os.path.join(out, c + ".rs")] = RustGen(sch).module(
            header_comment("//", sch).replace("gen_codecs.py\n", "gen_codecs.py --lang rust\n").replace(
                "gen_codecs.py from", "gen_codecs.py --lang rust from"))
        vp = os.path.join(VEC_OUT, c + ".json")
        if os.path.exists(vp):
            with open(vp, encoding="utf-8") as f:
                files[os.path.join(out, "vectors", c + ".json")] = f.read()
    return files, schemas


def write_files(files, check):
    stale = []
    for path, text in files.items():
        old = None
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                old = f.read()
        if old != text:
            stale.append(path)
            if not check:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8", newline="\n") as f:
                    f.write(text)
    return stale


RUST_OUT = os.environ.get("OLIFE_RUST_OUT", "<olife-src>/gateway/src/proto")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--lang", choices=("luapy", "rust", "all"), default="luapy",
                    help="luapy (default): Lua + Python + vectors; rust: Rust codecs for the gateway; all: both")
    ap.add_argument("--rust-out", default=RUST_OUT, help="Rust output dir (default %(default)s)")
    a = ap.parse_args()
    rc = 0
    if a.lang in ("luapy", "all"):
        rc = main_luapy(a)
    if a.lang in ("rust", "all") and rc == 0:
        files, schemas = render_rust(a.rust_out)
        stale = write_files(files, a.check)
        if a.check:
            if stale:
                print("stale:", *stale, sep="\n  ")
                return 1
            print("rust codecs up to date (%d files in %s)" % (len(files), a.rust_out))
            return 0
        for p in stale:
            print("wrote", p)
        print("rust: %d files (%d changed) in %s, messages: %s" % (
            len(files), len(stale), a.rust_out, ", ".join("%s %d" % (c, len(s["messages"])) for c, s in schemas.items())))
    return rc


def main_luapy(a):
    files, schemas = render()
    stale = []
    for path, text in files.items():
        old = None
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                old = f.read()
        if old != text:
            stale.append(path)
            if not a.check:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w", encoding="utf-8", newline="\n") as f:
                    f.write(text)
    if a.check:
        if stale:
            print("stale:", *stale, sep="\n  ")
            return 1
        print("codecs up to date (%d files)" % len(files))
        return 0
    # vectors from the freshly written Python codecs
    sys.path.insert(0, HERE)
    import importlib
    import olife_proto
    importlib.reload(olife_proto.wire)
    os.makedirs(VEC_OUT, exist_ok=True)
    nvec = 0
    for c, sch in schemas.items():
        mod = importlib.reload(importlib.import_module("olife_proto." + c))
        vec = vectors(sch, mod)
        nvec += len(vec)
        with open(os.path.join(VEC_OUT, c + ".json"), "w", encoding="utf-8", newline="\n") as f:
            json.dump({"contract": c, "version": sch["version"], "vectors": vec}, f, ensure_ascii=False, indent=0)
    for p in stale:
        print("wrote", os.path.relpath(p, VC_ROOT))
    print("%d files (%d changed), %d vectors, messages: %s" % (
        len(files), len(stale), nvec, ", ".join("%s %d" % (c, len(s["messages"])) for c, s in schemas.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
