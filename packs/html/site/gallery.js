// Галерея: фильтр по видам (classList «hidden»), просмотр в модальном окне с переходом по стрелкам.
const shots = document.querySelectorAll(".shot");
const chips = document.querySelectorAll(".chip");
let current = -1;

function visible() { return shots.filter(s => !s.classList.contains("hidden")); }

chips.forEach(chip => chip.addEventListener("click", () => {
    const f = chip.dataset.f;
    chips.forEach(c => c.classList.toggle("on", c === chip));
    shots.forEach(s => s.classList.toggle("hidden", f !== "all" && s.dataset.kind !== f));
    Site.toast("Показано: " + visible().length);
}));

function show(shot) {
    const list = visible();
    current = list.indexOf(shot);
    const w = shot.dataset.w, h = shot.dataset.h;
    document.getElementById("lb-img").innerHTML =
        '<img src="' + shot.dataset.src + '" width="' + w + '" height="' + h + '">';
    document.getElementById("lb-title").innerText = shot.querySelector("b").innerText;
    document.getElementById("lb-desc").innerText =
        shot.querySelector(".cap span").innerText + " · " + (current + 1) + " из " + list.length;
    document.getElementById("lightbox").classList.add("open");
}
function step(d) {
    const list = visible();
    if (current < 0) return;
    show(list[(current + d + list.length) % list.length]);
}
function close() {
    document.getElementById("lightbox").classList.remove("open");
    current = -1;
}
shots.forEach(s => s.addEventListener("click", () => show(s)));
document.getElementById("lb-close").onclick = close;
document.getElementById("lb-prev").onclick = () => step(-1);
document.getElementById("lb-next").onclick = () => step(1);
document.getElementById("lightbox").addEventListener("click", e => {
    if (e.target === document.getElementById("lightbox")) close();
});
document.addEventListener("keydown", e => {
    if (current < 0) return;
    if (e.key === "Escape") close();
    else if (e.key === "ArrowLeft") step(-1);
    else if (e.key === "ArrowRight") step(1);
});
