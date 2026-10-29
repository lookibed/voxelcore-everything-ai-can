// prelude.js — минимальный DOM браузера поверх нативного __dom (html_js.cpp).
// document.getElementById / querySelector(All), Element: innerText / textContent / innerHTML, id,
// className, classList, style, get/setAttribute, onclick, addEventListener, parentElement, children;
// setTimeout / setInterval / clear*, requestAnimationFrame, console.log.
(function (g) {
    "use strict";
    const D = __dom;
    const wrappers = new Map();
    function el(h) {
        if (h === null || h === undefined) return null;
        let w = wrappers.get(h);
        if (!w) { w = new Element(h); wrappers.set(h, w); }
        return w;
    }
    function kebab(n) { return n.replace(/[A-Z]/g, m => "-" + m.toLowerCase()); }
    function parseStyle(s) {
        const m = new Map();
        for (const part of (s || "").split(";")) {
            const i = part.indexOf(":");
            if (i > 0) m.set(part.slice(0, i).trim(), part.slice(i + 1).trim());
        }
        return m;
    }
    function styleProxy(e) {
        return new Proxy({}, {
            get(_, name) {
                if (typeof name !== "string") return undefined;
                if (name === "cssText") return D.getAttr(e._h, "style") || "";
                return parseStyle(D.getAttr(e._h, "style")).get(kebab(name)) || "";
            },
            set(_, name, value) {
                if (name === "cssText") { D.setAttr(e._h, "style", String(value)); return true; }
                const m = parseStyle(D.getAttr(e._h, "style"));
                const k = kebab(String(name));
                if (value === null || value === "") m.delete(k); else m.set(k, String(value));
                D.setAttr(e._h, "style", [...m].map(([a, b]) => a + ":" + b).join(";"));
                return true;
            },
        });
    }
    class ClassList {
        constructor(e) { this._e = e; }
        _get() { return (D.getAttr(this._e._h, "class") || "").split(/\s+/).filter(Boolean); }
        _set(a) { D.setAttr(this._e._h, "class", a.join(" ")); }
        contains(c) { return this._get().includes(c); }
        add(...cs) { const a = this._get(); for (const c of cs) if (!a.includes(c)) a.push(c); this._set(a); }
        remove(...cs) { this._set(this._get().filter(c => !cs.includes(c))); }
        toggle(c, force) {
            const has = this.contains(c);
            const want = force === undefined ? !has : !!force;
            if (want && !has) this.add(c); else if (!want && has) this.remove(c);
            return want;
        }
    }
    class Element {
        constructor(h) { this._h = h; this._listeners = {}; this.onclick = null; }
        get tagName() { return D.tag(this._h); }
        get id() { return D.getAttr(this._h, "id") || ""; }
        set id(v) { D.setAttr(this._h, "id", String(v)); }
        get className() { return D.getAttr(this._h, "class") || ""; }
        set className(v) { D.setAttr(this._h, "class", String(v)); }
        get classList() { return new ClassList(this); }
        get style() { return this._style || (this._style = styleProxy(this)); }
        get innerText() { return D.getText(this._h); }
        set innerText(v) { D.setHTML(this._h, String(v), true); }
        get textContent() { return D.getText(this._h); }
        set textContent(v) { D.setHTML(this._h, String(v), true); }
        set innerHTML(v) { D.setHTML(this._h, String(v), false); }
        get parentElement() { return el(D.parent(this._h)); }
        get children() { return D.children(this._h).map(el); }
        getAttribute(n) { return D.getAttr(this._h, n); }
        hasAttribute(n) { return D.getAttr(this._h, n) !== null; }
        get dataset() {
            const h = this._h;
            return new Proxy({}, {
                get: (_, k) => typeof k === "string" ? (D.getAttr(h, "data-" + kebab(k)) ?? undefined) : undefined,
                set: (_, k, v) => { D.setAttr(h, "data-" + kebab(String(k)), String(v)); return true; },
            });
        }
        matches(s) { const h = this._h; return D.queryAll(s, null).some(x => x === h); }
        closest(s) {
            const all = D.queryAll(s, null);
            for (let e = this; e; e = e.parentElement) if (all.includes(e._h)) return e;
            return null;
        }
        scrollIntoView() { D.scrollTo(Math.max(0, D.rect(this._h).y - D.fixedTop() - 8)); }
        setAttribute(n, v) { D.setAttr(this._h, n, String(v)); }
        querySelector(s) { return el(D.query(s, this._h)); }
        querySelectorAll(s) { return D.queryAll(s, this._h).map(el); }
        getBoundingClientRect() { return D.rect(this._h); }
        addEventListener(t, f) { (this._listeners[t] || (this._listeners[t] = [])).push(f); }
        removeEventListener(t, f) {
            const a = this._listeners[t];
            if (a) this._listeners[t] = a.filter(x => x !== f);
        }
        click() { dispatch(this, "click"); }
    }
    function dispatch(target, type) {
        const ev = {
            type, target, currentTarget: null, defaultPrevented: false, _stop: false,
            preventDefault() { this.defaultPrevented = true; }, stopPropagation() { this._stop = true; },
        };
        let handled = false;
        for (let e = target; e && !ev._stop; e = e.parentElement) {
            ev.currentTarget = e;
            const attr = e.getAttribute("on" + type);
            if (attr) { new Function("event", attr).call(e, ev); handled = true; }
            if (typeof e["on" + type] === "function") { e["on" + type].call(e, ev); handled = true; }
            for (const f of (e._listeners[type] || []).slice()) { f.call(e, ev); handled = true; }
        }
        for (const f of (docListeners[type] || []).slice()) { if (ev._stop) break; f.call(g.document, ev); handled = true; }
        return handled;
    }
    const docListeners = {};
    g.document = {
        getElementById: id => el(D.byId(String(id))),
        querySelector: s => el(D.query(s, null)),
        querySelectorAll: s => D.queryAll(s, null).map(el),
        get body() { return el(D.query("body", null)); },
        get documentElement() { return el(D.query("html", null)); },
        get title() { return D.title(); },
        addEventListener(t, f) { (docListeners[t] || (docListeners[t] = [])).push(f); },
    };
    g.window = g;
    g.localStorage = {
        getItem: k => D.storeGet(String(k)),
        setItem: (k, v) => D.storeSet(String(k), String(v)),
        removeItem: k => D.storeSet(String(k), undefined),
        clear: () => D.storeClear(),
        key: i => D.storeKeys()[i] ?? null,
        get length() { return D.storeKeys().length; },
    };
    g.sessionStorage = g.localStorage;
    g.location = {
        get href() { return D.url(); },
        set href(u) { D.navigate(String(u)); },
        get pathname() { return "/" + D.url(); },
        assign(u) { D.navigate(String(u)); },
        reload() { D.navigate(D.url()); },
    };
    Object.defineProperty(g, "scrollY", { get: () => D.scrollY() });
    Object.defineProperty(g, "pageYOffset", { get: () => D.scrollY() });
    Object.defineProperty(g, "innerWidth", { get: () => D.viewport().width });
    Object.defineProperty(g, "innerHeight", { get: () => D.viewport().height });
    g.scrollTo = (x, y) => D.scrollTo(typeof x === "object" && x ? (x.top || 0) : (y || 0));
    g.addEventListener = (t, f) => g.document.addEventListener(t, f);
    g.console = { log: (...a) => D.log(...a.map(String)), warn: (...a) => D.log("warn:", ...a.map(String)),
                  error: (...a) => D.log("error:", ...a.map(String)) };
    // таймеры: очередь по времени, __tick() зовёт хост каждый кадр
    let timers = new Map(), nextId = 1;
    g.setTimeout = (f, ms, ...a) => { const id = nextId++; timers.set(id, { f, a, at: D.now() + (ms || 0), every: 0 }); return id; };
    g.setInterval = (f, ms, ...a) => { const id = nextId++; ms = Math.max(ms || 0, 1); timers.set(id, { f, a, at: D.now() + ms, every: ms }); return id; };
    g.clearTimeout = g.clearInterval = id => { timers.delete(id); };
    g.requestAnimationFrame = f => g.setTimeout(() => f(D.now()), 0);
    g.performance = { now: () => D.now() };
    g.__tick = function () {
        const now = D.now();
        for (const [id, t] of [...timers]) {
            if (t.at > now || !timers.has(id)) continue;
            if (t.every) t.at = now + t.every; else timers.delete(id);
            try { typeof t.f === "function" ? t.f(...t.a) : new Function(String(t.f))(); }
            catch (e) { D.log("error:", String(e), e && e.stack || ""); }
        }
    };
    g.__dispatchClick = h => dispatch(el(h), "click");
    g.__dispatchDoc = type => {
        const ev = { type, target: g.document, preventDefault() {}, stopPropagation() {} };
        for (const f of (docListeners[type] || []).slice()) {
            try { f.call(g.document, ev); } catch (e) { D.log("error:", String(e), e && e.stack || ""); }
        }
    };
    const KEYS = { up: "ArrowUp", down: "ArrowDown", left: "ArrowLeft", right: "ArrowRight", enter: "Enter",
                   space: " ", escape: "Escape", "page-up": "PageUp", "page-down": "PageDown", home: "Home", end: "End" };
    g.__dispatchKey = name => {
        const key = KEYS[name] || name;
        const ev = { type: "keydown", key, code: key, preventDefault() {}, stopPropagation() {} };
        for (const f of (docListeners.keydown || []).slice()) f.call(g.document, ev);
    };
})(globalThis);
