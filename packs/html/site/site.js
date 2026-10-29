// Общий скрипт сайта: тема (светлая / тёмная, хранится в localStorage между страницами) и всплывающее
// уведомление. Выполняется QuickJS-NG внутри wasm; DOM — prelude.js поверх litehtml.
const Site = {
    theme() { return localStorage.getItem("theme") || "light"; },
    applyTheme(t) {
        const dark = t === "dark";
        document.body.classList.toggle("dark", dark);
        document.documentElement.classList.toggle("dark", dark);
        const b = document.getElementById("theme");
        if (b) b.innerText = dark ? "☀" : "☾";
        const l = document.getElementById("theme-label");
        if (l) l.innerText = dark ? "Тёмная тема" : "Светлая тема";
    },
    toggleTheme() {
        const t = this.theme() === "dark" ? "light" : "dark";
        localStorage.setItem("theme", t);
        this.applyTheme(t);
        this.toast(t === "dark" ? "Включена тёмная тема" : "Включена светлая тема");
    },
    _toastTimer: 0,
    toast(text) {
        const t = document.getElementById("toast");
        if (!t) return;
        t.innerText = text;
        t.classList.add("show");
        clearTimeout(this._toastTimer);
        this._toastTimer = setTimeout(() => t.classList.remove("show"), 3500);
    },
};
if (Site.theme() === "dark") Site.applyTheme("dark");
document.getElementById("theme").onclick = () => Site.toggleTheme();
console.log("site.js:", document.title, "theme", Site.theme());
