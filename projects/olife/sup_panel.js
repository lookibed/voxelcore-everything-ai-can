// Панель supervisor: секции проекта olife (кнопки оператора, вайтлист, антифрод). Вынесено из ядра (labcore/supervise.py
// рабочего каталога) в волне 1; ядро вставляет sup_panel.js каждого загруженного проекта в /sup/panel (vclab/supervise.py
// panel_html). Проект olife переезжает в волне 6 — до тех пор этот файл не загружается (нет project.toml).
(function(){ const ext = document.getElementById("ext");
  ext.insertAdjacentHTML("beforeend", '<div id="wl" class="card"></div><div id="fr" class="card"></div>'); })();
// ---- olife-ops-a2 (UX A2): per-player / per-mob operator buttons -> POST /call/olife.op {group, text, via: panel};
// the world runs the same command as an admin's chat "/..." and audits it (via=panel)
const btn = (g, label, text, ask) => '<button onclick="op(' + esc(q(g)) + ',' + esc(q(text)) + ',' + (ask ? esc(q(ask)) : 'null') + ')">' + label + '</button> ';
async function op(group, text, ask){
  if (ask) { const v = prompt(ask, ""); if (v === null) return; text = text + " " + v; }
  else if (/^(kill|killall|kick)/.test(text) && !confirm(text + " ?")) return;
  const el = document.getElementById("opmsg");
  try {
    const r = await fetch(BASE + "/call/olife.op", {method: "POST", headers: {"Content-Type": "application/json", "X-Lab-Client": "panel"},
      body: JSON.stringify({owner: "panel", args: {group, text, via: "panel", by: "panel"}})});
    const j = await r.json(); const x = j.result || j;
    el.textContent = text + " -> " + (x.code === 0 ? "ok: " : "code " + (x.code ?? "?") + ": ") + (x.text || x.error || x.message || JSON.stringify(j));
    el.className = x.code === 0 ? "ok" : "bad";
  } catch (e) { el.textContent = text + " -> " + e; el.className = "bad"; }
  tick();
}
function opsHtml(g, o){
  let h = '<h3>Operator (chat commands of an admin, audited)</h3>' + btn(g, "Kill all mobs", "killall") + btn(g, "Say", "say", "text:");
  h += table(o.players, [["eid",x=>fmt(x.eid)],["name",x=>esc(x.name)+(x.admin?' <span class="warn">admin</span>':'')],["account",x=>esc(x.account)],
    ["state",x=>x.frozen?'<span class="warn">FROZEN</span>':'ok'],
    ["actions",x=>btn(g,"Kill mobs","killall "+x.account)+(x.frozen?btn(g,"Unfreeze","unfreeze "+x.account):btn(g,"Freeze","freeze "+x.account))+
      btn(g,"Limits","limits "+x.account,"key value (fuel 20000 | bucket 0 | memory 32 | actions 8 | text 512 | fuel default):")+
      btn(g,"Kick","kick "+x.account)+btn(g,"Ban","ban "+x.account,"minutes reason (0 = permanent):")]]);
  h += table(o.mobs, [["eid",x=>fmt(x.eid)],["name",x=>esc(x.name)],["owner",x=>esc(x.owner)+' <span class="mut">#'+esc(x.owner_id)+'</span>'],
    ["status",x=>'<span class="'+({RUN:"ok",ERROR:"bad",THROTTLED:"warn",FROZEN:"warn"}[x.status]||"mut")+'">'+esc(x.status)+'</span>'],
    ["credits/min",x=>fmt(x.credits_min)],["limits",x=>x.lim?'<code>'+esc(JSON.stringify(x.lim))+'</code>':''],
    ["actions",x=>btn(g,"Kill","kill #"+x.eid)+(x.frozen?btn(g,"Unfreeze","unfreeze #"+x.eid):btn(g,"Freeze","freeze #"+x.eid))+
      btn(g,"Limits","limits #"+x.eid,"key value (actions 4 | text 256 world-side; fuel/bucket/memory -> owner VM):")]]);
  if ((o.bans||[]).length) h += table(o.bans, [["banned",b=>esc(b.account)],["until",b=>b.until_ms?new Date(b.until_ms).toLocaleString():'permanent'],["reason",b=>esc(b.reason)],["by",b=>esc(b.by)],["",b=>btn(g,"Unban","unban "+b.account)]]);
  h += '<div class="mut">audit '+fmt(o.audit_total)+' records · sandbox control '+esc((o.ctl||{}).state)+' :'+fmt((o.ctl||{}).port)+'</div>';
  h += table((o.audit||[]).slice().reverse(), [["n",r=>fmt(r.n)],["time",r=>tm((r.ms||0)/1000)],["by",r=>esc(r.by)+' <span class="mut">'+esc(r.via)+'</span>'],["cmd",r=>'<code>'+esc(r.cmd+' '+(r.args||[]).join(' '))+'</code>'],["code",r=>'<span class="'+(r.code===0?'ok':'bad')+'">'+fmt(r.code)+'</span>'],["result",r=>esc(r.result)]]);
  return h;
}
// ---- olife-whitelist-b (UX B, olife_menu): whitelist by nick (login by nick without a token) -> POST /call/olife.whitelist
// {op, name, scope, via: panel}; scope = gateway id of the tickets (gw-olife-play = the user's server, * = all gateways)
let WL_SCOPE = "gw-olife-play";
async function wl(op, name){
  if (op === "add") { name = prompt("nick to add to " + WL_SCOPE + ":", ""); if (!name) return; }
  if (op === "scope") { const v = prompt("whitelist scope (gateway id; * = all):", WL_SCOPE); if (!v) return; WL_SCOPE = v; op = "list"; }
  try {
    const r = await fetch(BASE + "/call/olife.whitelist", {method: "POST", headers: {"Content-Type": "application/json", "X-Lab-Client": "panel"},
      body: JSON.stringify({owner: "panel", args: {op, name, scope: WL_SCOPE, via: "panel", by: "panel"}})});
    const j = await r.json(); const x = j.result || {};
    if (!j.ok) { document.getElementById("wl").innerHTML = '<h3>Whitelist</h3><div class="mut">plugin olife not loaded: ' + esc(j.error || j.message) + '</div>'; return; }
    let h = '<h3>Whitelist by nick <span class="mut">(scope <code>' + esc(x.scope) + '</code> · olife-whitelist-b)</span></h3>';
    h += '<div>' + (x.enabled ? '<b class="ok">on</b>: only listed nicks log in by nick' : '<b class="mut">off</b>: any free nick logs in') +
         (x.scope !== "*" ? ' · global * ' + (x.global_enabled ? 'on' : 'off') + ' (' + (x.global_names||[]).length + ')' : '') + '</div>';
    h += '<button onclick="wl(\'' + (x.enabled ? 'off' : 'on') + '\')">' + (x.enabled ? 'Turn off' : 'Turn on') + '</button> ' +
         '<button onclick="wl(\'add\')">Add nick</button> <button onclick="wl(\'scope\')">Scope…</button>';
    h += table((x.names||[]).map(n => ({n})), [["nick", e => esc(e.n)], ["", e => '<button onclick="wl(\'remove\',' + esc(q(e.n)) + ')">Remove</button>'],
      ["CLI", e => '<code>lab olife whitelist remove ' + esc(e.n) + '</code>']]);
    h += '<div class="mut">CLI: <code>lab olife whitelist [list|add &lt;nick&gt;|remove &lt;nick&gt;|on|off] [--gw ID|--session S|--all]</code> · chat of an admin: <code>/whitelist ...</code></div>';
    document.getElementById("wl").innerHTML = h;
  } catch (e) { document.getElementById("wl").textContent = "whitelist: " + e; }
}
// ---- olife-antifraud (16.10, olife_antifraud): scores, autobans, IP bans, events, live knobs -> POST /call/olife.fraud
async function frcall(args){
  const r = await fetch(BASE + "/call/olife.fraud", {method: "POST", headers: {"Content-Type": "application/json", "X-Lab-Client": "panel"},
    body: JSON.stringify({owner: "panel", args: Object.assign({via: "panel", by: "panel"}, args)})});
  return await r.json();
}
async function fra(action, extra){
  const args = Object.assign({action}, extra || {});
  if (action === "set") { const v = prompt("fraud " + args.key + " = (default = back to the default):", args.cur ?? ""); if (v === null) return; args.value = v; delete args.cur; }
  if (action === "ipban") { const v = prompt("IP or CIDR to ban (127.0.0.1 / exempt networks are refused):", ""); if (!v) return;
    const m = prompt("minutes (0 = permanent) and reason:", "10 operator"); if (m === null) return; const p = m.split(" ");
    args.value = v; args.minutes = parseFloat(p[0]) || 0; args.reason = p.slice(1).join(" ") || "operator"; }
  const el = document.getElementById("opmsg");
  try { const j = await frcall(args); const x = j.result || {};
    el.textContent = "fraud " + action + " -> " + (x.ok === false ? (x.code + ": " + x.reason) : (x.text || "ok")); el.className = x.ok === false ? "bad" : "ok"; }
  catch (e) { el.textContent = "fraud " + action + " -> " + e; el.className = "bad"; }
  fr();
}
async function fr(){
  try {
    const j = await frcall({action: "status", last: 15});
    if (!j.ok) { document.getElementById("fr").innerHTML = '<h3>Antifraud</h3><div class="mut">plugin olife without olife.fraud: ' + esc(j.error || j.message) + '</div>'; return; }
    const x = j.result || {};
    const b = (f, label, ex) => '<button onclick="fra(' + esc(q(f)) + ',' + esc(JSON.stringify(ex || {})).replace(/"/g, "&quot;") + ')">' + label + '</button> ';
    let h = '<h3>Antifraud <span class="mut">(olife-antifraud · ' + (x.enabled ? '<b class="ok">on</b>' : '<b class="bad">OFF</b>') + ' · ' + (x.online || []).length + ' sessions seen by gateways)</span></h3>';
    h += b("set", x.enabled ? "Turn off" : "Turn on", {key: "enabled", cur: x.enabled ? "0" : "1"}) + b("ipban", "Ban IP/CIDR…");
    h += '<h3>Scores (worlds)</h3>' + table(x.scores, [["account", s => esc(s.account)], ["score", s => fmt(s.score)], ["level", s => esc(s.level) + (s.throttled ? ' <span class="warn">THROTTLED</span>' : '')],
      ["trust", s => 'x' + fmt(s.trust)], ["why", s => esc(s.why)], ["", s => b("clear", "Снять", {target: s.account})]]);
    h += '<h3>Autobans (by fraud)</h3>' + table(x.autobans, [["kind", r => esc(r.kind)], ["value", r => esc(r.value)], ["until", r => r.until ? new Date(r.until*1000).toLocaleString() : 'permanent'],
      ["reason", r => esc(r.reason)], ["", r => b("clear", "Снять", {target: r.kind === "ip" ? "ip:" + r.value : r.value})]]);
    h += '<h3>IP bans</h3>' + table(x.ip_bans, [["net", r => '<code>' + esc(r.value) + '</code>'], ["until", r => r.until ? new Date(r.until*1000).toLocaleString() : 'permanent'],
      ["reason", r => esc(r.reason)], ["by", r => esc(r.by)], ["", r => b("unban", "Unban", {value: r.value})]]);
    h += '<h3>Knobs</h3>' + table(Object.entries(x.cfg || {}).map(([k, v]) => ({k, v, o: (x.overrides || {})[k] !== undefined})), [["key", e => '<code>' + esc(e.k) + '</code>'],
      ["value", e => (e.o ? '<b>' : '') + esc(e.v) + (e.o ? '</b>' : ' <span class="mut">default</span>')], ["", e => b("set", "Set", {key: e.k, cur: String(e.v)})],
      ["CLI", e => '<code>lab olife fraud set ' + esc(e.k) + ' &lt;v|default&gt;</code>']]);
    h += '<h3>Last events</h3>' + table((x.events || []).slice().reverse(), [["time", e => tm(e.ts)], ["event", e => esc(e.kind)],
      ["detail", e => '<code>' + esc(JSON.stringify(Object.fromEntries(Object.entries(e).filter(([k]) => !["ts", "kind", "n"].includes(k))))).slice(0, 200) + '</code>']]);
    h += '<div class="mut">CLI: <code>lab olife fraud [status|events|set k v|clear &lt;acct|ip:A|nick:N&gt;|trust a x]</code> · <code>lab olife ban --ip &lt;addr|cidr&gt; &lt;min&gt; &lt;reason&gt;</code> · chat of an admin: <code>/fraud ...</code>, <code>/ban ip ...</code>, <code>/bans</code></div>';
    document.getElementById("fr").innerHTML = h;
  } catch (e) { document.getElementById("fr").textContent = "antifraud: " + e; }
}
EXT_TICKS.push(() => { wl("list"); fr(); });
