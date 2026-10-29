// Демо: вкладки, счётчик, форма из кнопок, таймер, тема, модальное окно, аккордеон.
const $ = id => document.getElementById(id);

// ---- вкладки
const tabs = document.querySelectorAll(".tab");
function openTab(name) {
    tabs.forEach(t => t.classList.toggle("on", t.dataset.tab === name));
    document.querySelectorAll(".tab-body").forEach(b => b.classList.toggle("on", b.id === "body-" + name));
    localStorage.setItem("demo-tab", name);
}
tabs.forEach(t => t.addEventListener("click", () => openTab(t.dataset.tab)));
if (localStorage.getItem("demo-tab")) openTab(localStorage.getItem("demo-tab"));

// ---- счётчик
const GOAL = 10;
let count = 0;
function renderCount() {
    $("count").innerText = String(count);
    const p = Math.max(0, Math.min(100, count * 100 / GOAL));
    $("count-bar").style.width = p + "%";
    $("count-hint").innerText = count >= GOAL ? "Цель достигнута! 🎉" : "Осталось " + (GOAL - count) + ".";
    $("count").style.color = count >= GOAL ? "var(--ok)" : "";
}
$("inc").onclick = () => { count++; renderCount(); if (count === GOAL) Site.toast("Цель: 10 из 10"); };
$("dec").onclick = () => { if (count > 0) count--; renderCount(); };
$("reset").onclick = () => { count = 0; renderCount(); };

// ---- форма из кнопок
let seats = 1;
function price() {
    let sum = Number(document.querySelector("#plans .on").dataset.price);
    document.querySelectorAll(".check.on").forEach(c => { sum += Number(c.dataset.price); });
    return sum * seats;
}
function renderForm() {
    $("seats").innerText = String(seats);
    $("total").innerText = price().toLocaleString("ru-RU") + " ₽";
}
document.querySelectorAll("#plans span").forEach(p => p.addEventListener("click", () => {
    document.querySelectorAll("#plans span").forEach(x => x.classList.toggle("on", x === p));
    $("form-ok").classList.add("hidden");
    renderForm();
}));
document.querySelectorAll(".check").forEach(c => c.addEventListener("click", () => {
    const on = c.classList.toggle("on");
    c.querySelector(".box").innerText = on ? "✓" : "";
    $("form-ok").classList.add("hidden");
    renderForm();
}));
$("seat-inc").onclick = () => { if (seats < 99) seats++; renderForm(); };
$("seat-dec").onclick = () => { if (seats > 1) seats--; renderForm(); };
$("form-clear").onclick = () => {
    seats = 1;
    document.querySelectorAll("#plans span").forEach((x, i) => x.classList.toggle("on", i === 0));
    document.querySelectorAll(".check").forEach((c, i) => {
        c.classList.toggle("on", i === 0);
        c.querySelector(".box").innerText = i === 0 ? "✓" : "";
    });
    $("form-ok").classList.add("hidden");
    renderForm();
};
$("form-send").onclick = () => {
    const plan = document.querySelector("#plans .on").innerText;
    const opts = document.querySelectorAll(".check.on").length;
    $("form-ok").innerText = "✓ Заявка принята: «" + plan + "», опций " + opts + ", мест " + seats +
        ", " + price().toLocaleString("ru-RU") + " ₽ в месяц.";
    $("form-ok").classList.remove("hidden");
    Site.toast("Заявка отправлена");
};
renderForm();

// ---- таймер
let running = false, elapsed = 0, last = 0, tick = 0;
function fmt(ms) {
    const s = Math.floor(ms / 1000), m = Math.floor(s / 60);
    return String(m).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0") + "." + Math.floor(ms % 1000 / 100);
}
function renderTimer() {
    $("clock").innerText = fmt(elapsed);
    $("timer-bar").style.width = (elapsed % 10000) / 100 + "%";
}
$("timer-go").onclick = () => {
    running = !running;
    if (running) {
        last = performance.now();
        tick = setInterval(() => {
            const now = performance.now();
            elapsed += now - last;
            last = now;
            renderTimer();
        }, 100);
    } else clearInterval(tick);
    $("timer-go").innerText = running ? "Пауза" : "Старт";
    $("timer-state").innerText = running ? "Идёт · setInterval 100 мс" : "Пауза · " + fmt(elapsed);
};
$("timer-reset").onclick = () => { elapsed = 0; last = performance.now(); renderTimer(); };

// ---- тема (переключатель повторяет кнопку в шапке)
$("theme-switch").onclick = () => Site.toggleTheme();

// ---- модальное окно
let opened = 0;
function openModal() {
    opened++;
    $("modal-info").innerText = "Открыто " + opened + " раз(а). Esc — закрыть.";
    $("modal").classList.add("open");
}
function closeModal() { $("modal").classList.remove("open"); }
$("open-modal").onclick = openModal;
$("modal-close").onclick = closeModal;
$("modal-ok").onclick = closeModal;
$("modal-toast").onclick = () => Site.toast("Уведомление из модального окна");
$("modal").addEventListener("click", e => { if (e.target === $("modal")) closeModal(); });
document.addEventListener("keydown", e => { if (e.key === "Escape") closeModal(); });

// ---- аккордеон: открыт один пункт
document.querySelectorAll(".acc-item").forEach(item => {
    item.querySelector(".acc-head").addEventListener("click", () => {
        const open = !item.classList.contains("open");
        document.querySelectorAll(".acc-item").forEach(x => {
            x.classList.toggle("open", x === item && open);
            x.querySelector(".acc-head i").innerText = x === item && open ? "−" : "+";
        });
    });
});
console.log("demo.js ready");
