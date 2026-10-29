// Эталон Eaglercraft: управление headless Microsoft Edge (Windows) по CDP из Windows-node.
// Запуск (из WSL через powershell, см. edge_ref.py):  node edge_ref.js <файл сценария.json>
// Сценарий — JSON-массив шагов:
//   {"navigate": "http://localhost:8765/index.html"}   {"wait": 3000}
//   {"eval": "document.title"}                          {"screenshot": "ref_menu"}
//   {"click": [427, 236]}   {"key": "Escape"}   {"type": "1234567890"}
//   {"wait_eval": "window.__done", "timeout": 60000}   — ждать истинности выражения
// Координаты — CSS-пиксели страницы (854×480 при --window-size=854,480, dpr 1).
// Результаты eval печатаются в stdout строками "eval <n>: <json>", скриншоты — в artifacts/screens.
const fs = require("fs");
const path = require("path");
const http = require("http");

const CDP_HOST = "127.0.0.1", CDP_PORT = 9222;
const OUT_DIR = process.env.REF_OUT || path.join(__dirname, "..", "..", "artifacts", "screens");

function getJson(p) {
    return new Promise((resolve, reject) => {
        http.get({ host: CDP_HOST, port: CDP_PORT, path: p }, res => {
            let d = ""; res.on("data", c => d += c); res.on("end", () => resolve(JSON.parse(d)));
        }).on("error", reject);
    });
}
function putJson(p) {
    return new Promise((resolve, reject) => {
        const req = http.request({ host: CDP_HOST, port: CDP_PORT, path: p, method: "PUT" }, res => {
            let d = ""; res.on("data", c => d += c); res.on("end", () => resolve(JSON.parse(d)));
        });
        req.on("error", reject); req.end();
    });
}

class Cdp {
    constructor(url) { this.ws = new WebSocket(url); this.id = 0; this.pending = new Map(); this.events = []; }
    open() {
        return new Promise((res, rej) => {
            this.ws.onopen = () => res();
            this.ws.onerror = e => rej(new Error("ws error " + (e.message || "")));
            this.ws.onmessage = m => {
                const msg = JSON.parse(m.data);
                if (msg.id !== undefined) {
                    const p = this.pending.get(msg.id); this.pending.delete(msg.id);
                    if (!p) return;
                    msg.error ? p.reject(new Error(msg.error.message)) : p.resolve(msg.result);
                } else this.events.push(msg);
            };
        });
    }
    send(method, params = {}) {
        const id = ++this.id;
        this.ws.send(JSON.stringify({ id, method, params }));
        return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    }
}
const sleep = ms => new Promise(r => setTimeout(r, ms));

const KEYS = {
    Escape: { keyCode: 27, code: "Escape" }, Enter: { keyCode: 13, code: "Enter", text: "\r" },
    Backspace: { keyCode: 8, code: "Backspace" }, Tab: { keyCode: 9, code: "Tab" },
    Space: { keyCode: 32, code: "Space", text: " " },
    ArrowUp: { keyCode: 38, code: "ArrowUp" }, ArrowDown: { keyCode: 40, code: "ArrowDown" },
    ArrowLeft: { keyCode: 37, code: "ArrowLeft" }, ArrowRight: { keyCode: 39, code: "ArrowRight" },
    F3: { keyCode: 114, code: "F3" },
};

async function main() {
    const script = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const targets = await getJson("/json/list");
    let page = targets.find(t => t.type === "page");
    if (!page) page = await putJson("/json/new?about:blank");
    const cdp = new Cdp(page.webSocketDebuggerUrl);
    await cdp.open();
    await cdp.send("Page.enable"); await cdp.send("Runtime.enable");
    await cdp.send("Emulation.setDeviceMetricsOverride", { width: 854, height: 480, deviceScaleFactor: 1, mobile: false });
    let n = 0;
    for (const step of script) {
        if (step.navigate) { await cdp.send("Page.navigate", { url: step.navigate }); }
        else if (step.wait) { await sleep(step.wait); }
        else if (step.eval) {
            const r = await cdp.send("Runtime.evaluate", { expression: step.eval, returnByValue: true, awaitPromise: true });
            console.log(`eval ${++n}: ${JSON.stringify(r.result.value !== undefined ? r.result.value : r.result.description)}`);
        } else if (step.wait_eval) {
            const t0 = Date.now(); let ok = false;
            while (Date.now() - t0 < (step.timeout || 30000)) {
                const r = await cdp.send("Runtime.evaluate", { expression: step.wait_eval, returnByValue: true });
                if (r.result.value) { ok = true; break; }
                await sleep(250);
            }
            console.log(`wait_eval ${step.wait_eval}: ${ok ? "ok" : "timeout"} ${Date.now() - t0} ms`);
        } else if (step.screenshot) {
            const r = await cdp.send("Page.captureScreenshot", { format: "png" });
            const file = path.join(OUT_DIR, step.screenshot + ".png");
            fs.writeFileSync(file, Buffer.from(r.data, "base64"));
            console.log(`screenshot ${file}`);
        } else if (step.click) {
            const [x, y] = step.click;
            await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
            await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
            await sleep(step.hold || 80);
            await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
        } else if (step.move) {
            const [x, y] = step.move;
            await cdp.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
        } else if (step.key) {
            const k = KEYS[step.key] || { keyCode: step.key.charCodeAt(0), code: "Key" + step.key.toUpperCase(), text: step.key };
            await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: step.key, code: k.code, windowsVirtualKeyCode: k.keyCode, text: k.text });
            await sleep(step.hold || 60);
            await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: step.key, code: k.code, windowsVirtualKeyCode: k.keyCode });
        } else if (step.type) {
            for (const ch of step.type) {
                await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch, windowsVirtualKeyCode: ch.toUpperCase().charCodeAt(0) });
                await sleep(30);
                await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: ch, windowsVirtualKeyCode: ch.toUpperCase().charCodeAt(0) });
                await sleep(30);
            }
        } else console.log("unknown step " + JSON.stringify(step));
    }
    cdp.ws.close();
}
main().catch(e => { console.error("ERROR " + e.message); process.exit(1); });
