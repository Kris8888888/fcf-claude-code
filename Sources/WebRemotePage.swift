// 网页远程的页面：一个文件，不依赖外网资源（公司网络里也能打开）
// 配色从电脑上的客户端读（/api/theme），和客户端用同一套主题
enum WebRemotePage {
    static let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>FCF启动claude code · 网页远程</title>
<style>
:root{
  --canvas:#F4F5F7;--paper:#FFFFFF;--sunk:#EEF0F3;--ink:#1D1F24;--muted:#6B7080;--line:#E1E4EA;
  --accent:#4558CC;--run:#4558CC;--ok:#2E9E6A;--err:#D64545;--on-accent:#fff;--fs:14px;
}
*{box-sizing:border-box}
html,body{height:100%;margin:0}
html{font-size:var(--fs)}
body{background:var(--paper);color:var(--ink);font:1rem/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;-webkit-font-smoothing:antialiased}
button,input,textarea{font:inherit;color:inherit}
button{cursor:pointer}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.hidden{display:none!important}

/* 登录 */
#login{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;background:var(--canvas);padding:16px}
#login form{width:min(360px,100%);background:var(--paper);border:1px solid var(--line);border-radius:14px;padding:28px 24px}
#login h1{font-size:1.267rem;margin:0 0 4px;font-weight:600}
#login p{margin:0 0 20px;color:var(--muted);font-size:0.8667rem}
#code{width:100%;font-size:1.733rem;letter-spacing:.35em;text-align:center;padding:10px;border:1px solid var(--line);border-radius:10px;background:var(--sunk)}
#login .btn{width:100%;margin-top:14px}
#loginErr{color:var(--err);font-size:0.8667rem;min-height:20px;margin-top:8px}

.btn{border:0;border-radius:8px;padding:8px 14px;background:var(--accent);color:var(--on-accent);font-weight:500}
.btn.quiet{background:transparent;color:var(--muted);padding:8px 10px}
.btn.line{background:transparent;border:1px solid var(--line);color:var(--ink)}
.btn:disabled{opacity:.5;cursor:default}

/* 主界面 */
#app{display:grid;grid-template-columns:280px minmax(0,1fr);height:100%}
aside{background:var(--canvas);border-right:1px solid var(--line);display:flex;flex-direction:column;min-height:0}
aside .top{padding:14px 12px 8px;display:flex;flex-direction:column;gap:8px}
#newBtn{width:100%;padding:9px;border:1px solid var(--line);background:var(--paper);color:var(--ink);border-radius:10px;font-weight:500}
#search{width:100%;padding:7px 10px;border:1px solid transparent;border-radius:8px;background:var(--sunk)}
#rows{overflow:auto;padding:4px 8px 16px;flex:1}
.group{margin-top:10px}
.gname{font-size:0.8rem;color:var(--muted);padding:4px 8px}
.row{display:flex;align-items:center;gap:6px;width:100%;text-align:left;border:0;background:transparent;padding:7px 8px;border-radius:7px;font-size:0.9333rem}
.row:hover{background:color-mix(in srgb,var(--line) 55%,transparent)}
.row.on{background:var(--line);font-weight:500}
.row .t{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.row time{font-size:0.8rem;color:var(--muted)}
.dot{width:6px;height:6px;border-radius:50%;flex:none}
.dot.busy{background:var(--run)}.dot.att{background:var(--accent)}

main{display:flex;flex-direction:column;min-width:0;min-height:0;overflow:hidden}
header{display:flex;align-items:center;gap:10px;padding:10px 18px;border-bottom:1px solid var(--line);min-height:56px}
#sizeBtn{flex:none;border:1px solid var(--line);background:transparent;border-radius:999px;padding:2px 9px;font-size:.8rem;color:var(--muted)}
#menuBtn{display:none;border:0;background:transparent;font-size:1.333rem;padding:4px 6px}
header .ttl{flex:1;min-width:0}
header .ttl b{display:block;font-size:1rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
header .ttl span{font-size:0.8rem;color:var(--muted)}
/* 连接状态：一眼看出还连着这台电脑没有 */
#link{display:flex;flex:none;max-width:46%;overflow:hidden;text-overflow:ellipsis;align-items:center;gap:6px;font-size:0.8rem;color:var(--muted);border:1px solid var(--line);border-radius:999px;padding:3px 10px;white-space:nowrap}
#link i{width:7px;height:7px;border-radius:50%;background:var(--ok)}
#link.off i{background:var(--err)}

#scroll{flex:1;overflow:auto;padding:22px 18px 8px}
#items{max-width:780px;margin:0 auto}
.empty{color:var(--muted);text-align:center;margin-top:20vh}
.u{display:flex;justify-content:flex-end;margin:18px 0}
.u .b{max-width:82%;background:color-mix(in srgb,var(--accent) 14%,var(--paper));border-radius:14px;padding:9px 14px;white-space:pre-wrap;word-break:break-word}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin-top:6px}
.chip{font-size:0.8rem;border:1px solid var(--line);border-radius:6px;padding:2px 8px;background:var(--paper);color:var(--muted)}
.rail{border-left:1.5px solid var(--line);padding:2px 0 2px 18px;margin-left:6px}
.a{margin:6px 0 14px}
.step{display:flex;gap:8px;align-items:baseline;color:var(--muted);font-size:0.9rem;padding:3px 0;cursor:pointer;user-select:none}
.step .s{width:7px;height:7px;border-radius:50%;background:var(--muted);flex:none;transform:translateY(-1px)}
.step .s.running{background:var(--run);animation:pulse 1.2s ease-in-out infinite}
.step .s.failed{background:var(--err)}
.step .lbl{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.detail{margin:4px 0 8px 15px}
pre{background:var(--sunk);border:1px solid var(--line);border-radius:8px;padding:10px 12px;overflow:auto;font:0.8333rem/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word;max-height:420px;margin:6px 0}
code{font:.9em ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--sunk);border-radius:4px;padding:1px 5px}
pre code{background:none;padding:0}
.md p{margin:.5em 0}.md h1,.md h2,.md h3,.md h4{margin:1em 0 .4em;line-height:1.35}.md h1{font-size:1.3em}.md h2{font-size:1.18em}.md h3{font-size:1.06em}
.md ul,.md ol{padding-left:1.4em;margin:.4em 0}.md li{margin:.15em 0}
.md table{border-collapse:collapse;margin:.6em 0;display:block;overflow:auto}.md th,.md td{border:1px solid var(--line);padding:5px 9px;text-align:left}.md th{background:var(--sunk)}
.md blockquote{margin:.5em 0;padding-left:12px;border-left:3px solid var(--line);color:var(--muted)}
.md a{color:var(--accent)}
.notice{color:var(--muted);font-size:0.8667rem;text-align:center;margin:10px 0}
.error{color:var(--err);font-size:0.9rem;white-space:pre-wrap;margin:8px 0}
.card{border:1px solid var(--line);background:var(--paper);border-radius:12px;padding:14px;margin:8px 0}
.card.ask{border-color:color-mix(in srgb,var(--accent) 45%,var(--line))}
.card h4{margin:0 0 8px;font-size:0.9667rem}
.card .acts{display:flex;flex-wrap:wrap;gap:8px;justify-content:flex-end;margin-top:10px}
.done{color:var(--muted);font-size:0.8667rem}
.opt{display:block;width:100%;text-align:left;border:1px solid var(--line);background:var(--paper);border-radius:9px;padding:8px 12px;margin:6px 0}
.opt small{display:block;color:var(--muted)}
.opt.on{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 10%,var(--paper))}
.busy{display:flex;align-items:center;gap:8px;color:var(--run);font-size:0.9rem;margin:6px 0 14px}
.spin{width:12px;height:12px;border:2px solid color-mix(in srgb,var(--run) 30%,transparent);border-top-color:var(--run);border-radius:50%;animation:spin .8s linear infinite}
.more{display:block;margin:0 auto 14px;font-size:0.8333rem}

.composer{padding:10px 18px 16px;border-top:1px solid transparent}
.box{max-width:780px;margin:0 auto;border:1px solid var(--line);border-radius:14px;background:var(--paper);padding:10px 12px}
#input{width:100%;border:0;outline:0;resize:none;background:transparent;min-height:26px;max-height:200px;line-height:1.55}
.bar{display:flex;align-items:center;gap:10px;margin-top:6px}
.bar .mode{font-size:0.8rem;color:var(--muted);flex:1}
#sendBtn,#stopBtn{border-radius:999px;width:34px;height:34px;padding:0;display:grid;place-items:center}
#stopBtn{background:var(--ink)}
#stopBtn span{width:11px;height:11px;background:var(--paper);border-radius:2px}

@keyframes spin{to{transform:rotate(360deg)}}
@keyframes pulse{50%{opacity:.35}}
@media (prefers-reduced-motion:reduce){.spin,.step .s.running{animation:none}}
@media (max-width:760px){
  #app{grid-template-columns:minmax(0,1fr)}
  aside{position:fixed;inset:0 25% 0 0;z-index:5;transform:translateX(-102%);transition:transform .2s;box-shadow:0 0 0 100vmax transparent}
  aside.open{transform:none;box-shadow:0 0 0 100vmax rgba(0,0,0,.35)}
  #menuBtn{display:block}
  #scroll{padding:16px 12px 6px}.composer{padding:8px 10px 12px}
  .u .b{max-width:90%}
}
</style>
</head>
<body>
<div id="login" class="hidden">
  <form id="loginForm" autocomplete="off">
    <h1 id="loginHost">连接这台电脑</h1>
    <p>输入电脑上「设置 → 网页远程」里显示的 6 位访问码。</p>
    <input id="code" inputmode="numeric" maxlength="6" placeholder="······" aria-label="访问码">
    <button class="btn" type="submit">进入</button>
    <div id="loginErr"></div>
  </form>
</div>

<div id="app" class="hidden">
  <aside id="side">
    <div class="top">
      <button id="newBtn">＋ 新对话</button>
      <input id="search" placeholder="搜索对话" aria-label="搜索对话">
    </div>
    <div id="rows"></div>
  </aside>
  <main>
    <header>
      <button id="menuBtn" aria-label="对话列表">☰</button>
      <div class="ttl"><b id="title">选一个对话</b><span id="folder"></span></div>
      <button id="sizeBtn" aria-label="切换字号">Aa</button>
      <div id="link"><i></i><span id="linkText">已连着电脑</span></div>
    </header>
    <div id="scroll"><div id="items"><div class="empty">从左边选一个对话，或新建一个。</div></div></div>
    <div class="composer">
      <div class="box">
        <textarea id="input" rows="1" placeholder="给 Claude 发消息（回车发送，Shift+回车换行）" disabled></textarea>
        <div class="bar">
          <span class="mode" id="mode"></span>
          <button class="btn hidden" id="stopBtn" title="停止"><span></span></button>
          <button class="btn" id="sendBtn" title="发送" disabled>↑</button>
        </div>
      </div>
    </div>
  </main>
</div>

<script>
const $ = s => document.querySelector(s);
let LIST = null, CUR = null, SNAP = null, OPEN = new Set(), PICKS = {}, ES = null, loadingSess = false, pendingSess = false;

async function api(path, body){
  const r = await fetch(path, body ? {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body), credentials:'same-origin'} : {credentials:'same-origin'});
  if (r.status === 401) { showLogin(); throw new Error('401'); }
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(j.error || ('出错了：' + r.status));
  return j;
}
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

// ---------- 主题：和电脑上的客户端一样 ----------
function hexLum(h){ const n = parseInt(h.slice(1),16); const c=[n>>16&255,n>>8&255,n&255].map(v=>{v/=255;return v<=.03928?v/12.92:Math.pow((v+.055)/1.055,2.4)}); return .2126*c[0]+.7152*c[1]+.0722*c[2]; }
// 字号跟着这台设备走：小 / 标准 / 大，浏览器记住
const SIZES = [['小',13],['标准',14],['大',15.5]];
function curSize(){ try { const v = +localStorage.getItem('fcfrc-size'); return SIZES.findIndex(x=>x[1]===v) >= 0 ? v : 14; } catch(_) { return 14; } }
function applySize(){ const v = curSize(); document.documentElement.style.setProperty('--fs', v + 'px'); const b = document.getElementById('sizeBtn'); if (b) b.title = '字号：' + SIZES.find(x=>x[1]===v)[0] + '（点一下切换）'; }
function nextSize(){ const i = SIZES.findIndex(x=>x[1]===curSize()); try { localStorage.setItem('fcfrc-size', SIZES[(i+1)%SIZES.length][1]); } catch(_){} applySize(); }
async function applyTheme(){
  try{
    const t = await (await fetch('/api/theme', {credentials:'same-origin'})).json();
    const dark = t.scheme === 'dark' || (t.scheme === 'auto' && matchMedia('(prefers-color-scheme: dark)').matches);
    const p = dark ? t.dark : t.light, r = document.documentElement.style;
    for (const k in p) r.setProperty('--' + k, p[k]);
    r.setProperty('--on-accent', hexLum(p.accent) > .5 ? '#111' : '#fff');
    applySize();
    document.querySelector('meta[name=viewport]');
  }catch(e){}
}

// ---------- 登录 ----------
function showLogin(){ $('#app').classList.add('hidden'); $('#login').classList.remove('hidden'); setTimeout(()=>$('#code').focus(), 50); if (ES){ ES.close(); ES=null; } }
$('#loginForm').onsubmit = async e => {
  e.preventDefault(); $('#loginErr').textContent = '';
  try {
    const r = await fetch('/api/login', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({code:$('#code').value}), credentials:'same-origin'});
    const j = await r.json().catch(()=>({}));
    if (!r.ok) { $('#loginErr').textContent = j.error || '进不去，请再试一次'; return; }
    $('#code').value = ''; start();
  } catch(err){ $('#loginErr').textContent = '连不上这台电脑：' + err.message; }
};

// ---------- 实时推送 ----------
function connect(){
  if (ES) ES.close();
  ES = new EventSource('/api/events');
  ES.addEventListener('hello', () => setLink(true));
  ES.addEventListener('list', () => loadList());
  ES.addEventListener('session', e => { try { if (JSON.parse(e.data).id === CUR) loadSession(); } catch(_){} });
  ES.addEventListener('logout', () => showLogin());
  ES.onerror = () => setLink(false);
  ES.onopen = () => { setLink(true); loadList(); if (CUR) loadSession(); };
}
function setLink(ok){ $('#link').classList.toggle('off', !ok); $('#linkText').textContent = ok ? '已连着 ' + (HOST||'电脑') : '连接断了，正在重连…'; }

// ---------- 列表 ----------
function rel(ts){ const d = (Date.now()/1000 - ts); if (d < 60) return '刚刚'; if (d < 3600) return Math.floor(d/60)+'分钟'; if (d < 86400) return Math.floor(d/3600)+'小时'; return Math.floor(d/86400)+'天'; }
async function loadList(){ try { LIST = await api('/api/list'); renderList(); } catch(_){} }
function renderList(){
  if (!LIST) return;
  const q = $('#search').value.trim().toLowerCase();
  const row = r => `<button class="row ${r.id===CUR?'on':''}" data-id="${esc(r.id)}">${r.attention?'<span class="dot att"></span>':r.busy?'<span class="dot busy"></span>':''}<span class="t">${esc(r.title)}</span><time>${rel(r.date)}</time></button>`;
  const f = rs => rs.filter(r => !q || r.title.toLowerCase().includes(q));
  let h = '';
  const pin = f(LIST.pinned);
  if (pin.length) h += `<div class="group"><div class="gname">置顶</div>${pin.map(row).join('')}</div>`;
  for (const g of LIST.groups){ const rs = f(g.rows); if (rs.length) h += `<div class="group"><div class="gname">${esc(g.name)}</div>${rs.map(row).join('')}</div>`; }
  $('#rows').innerHTML = h || '<div class="gname">没有对话</div>';
}
$('#rows').onclick = e => { const b = e.target.closest('.row'); if (b) select(b.dataset.id); };
$('#search').oninput = renderList;
$('#newBtn').onclick = async () => { try { const r = await api('/api/new', {}); select(r.id); loadList(); } catch(err){ alert(err.message); } };
$('#sizeBtn').onclick = e => { e.stopPropagation(); nextSize(); };
applySize();
$('#menuBtn').onclick = e => { e.stopPropagation(); $('#side').classList.toggle('open'); };
document.querySelector('main').addEventListener('click', () => $('#side').classList.remove('open'));

function select(id){
  CUR = id; SNAP = null; OPEN = new Set(); PICKS = {};
  history.replaceState(null, '', '#' + id);
  $('#side').classList.remove('open');
  $('#items').innerHTML = '<div class="notice">正在打开…</div>';
  renderList(); loadSession(true);
}

// ---------- 对话 ----------
async function loadSession(jump){
  if (!CUR) return;
  if (loadingSess) { pendingSess = true; return; }
  loadingSess = true;
  try {
    const sc = $('#scroll'), atBottom = jump || sc.scrollHeight - sc.scrollTop - sc.clientHeight < 120;
    SNAP = await api('/api/session?id=' + encodeURIComponent(CUR) + '&limit=' + LIMIT);
    if (SNAP.id !== CUR) { CUR = SNAP.id; history.replaceState(null,'','#'+CUR); renderList(); }
    renderSession();
    if (atBottom) sc.scrollTop = sc.scrollHeight;
  } catch(e){ if (e.message !== '401') $('#items').innerHTML = `<div class="error">${esc(e.message)}</div>`; }
  loadingSess = false;
  if (pendingSess) { pendingSess = false; loadSession(); }
}
let LIMIT = 160, HOST = '';

function md(src){
  // 精简的 Markdown：代码块、标题、列表、表格、引用、加粗、斜体、行内代码、链接
  const lines = String(src).replace(/\r/g,'').split('\n'); let out = '', i = 0;
  const inline = s => esc(s)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>')
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  while (i < lines.length){
    let l = lines[i];
    if (/^```/.test(l)){ let buf=[]; i++; while(i<lines.length && !/^```/.test(lines[i])) buf.push(lines[i++]); i++; out += `<pre><code>${esc(buf.join('\n'))}</code></pre>`; continue; }
    if (/^#{1,6}\s/.test(l)){ const n = Math.min(4, l.match(/^#+/)[0].length); out += `<h${n}>${inline(l.replace(/^#+\s*/,''))}</h${n}>`; i++; continue; }
    if (/^\s*\|.*\|\s*$/.test(l) && i+1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i+1])){
      const cells = s => s.trim().replace(/^\||\|$/g,'').split('|').map(c=>c.trim());
      let h = `<table><thead><tr>${cells(l).map(c=>`<th>${inline(c)}</th>`).join('')}</tr></thead><tbody>`; i += 2;
      while (i<lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) h += `<tr>${cells(lines[i++]).map(c=>`<td>${inline(c)}</td>`).join('')}</tr>`;
      out += h + '</tbody></table>'; continue;
    }
    if (/^\s*([-*+]|\d+\.)\s+/.test(l)){
      const ordered = /^\s*\d+\./.test(l); let h = ordered ? '<ol>' : '<ul>';
      while (i<lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) h += `<li>${inline(lines[i++].replace(/^\s*([-*+]|\d+\.)\s+/,''))}</li>`;
      out += h + (ordered ? '</ol>' : '</ul>'); continue;
    }
    if (/^>\s?/.test(l)){ let buf=[]; while(i<lines.length && /^>\s?/.test(lines[i])) buf.push(lines[i++].replace(/^>\s?/,'')); out += `<blockquote>${inline(buf.join(' '))}</blockquote>`; continue; }
    if (!l.trim()){ i++; continue; }
    let buf=[l]; i++;
    while (i<lines.length && lines[i].trim() && !/^(```|#{1,6}\s|>|\s*([-*+]|\d+\.)\s|\s*\|)/.test(lines[i])) buf.push(lines[i++]);
    out += `<p>${buf.map(inline).join('<br>')}</p>`;
  }
  return out;
}

function stepHTML(it){
  const open = OPEN.has(it.id);
  if (it.kind === 'thinking'){
    const lbl = it.streaming ? '思考中…' : (it.duration != null ? `思考了 ${Math.max(1,Math.round(it.duration))} 秒` : '思考过程');
    return `<div class="step" data-toggle="${it.id}"><span class="s ${it.streaming?'running':''}"></span><span class="lbl">${lbl}</span></div>` +
      (open ? `<div class="detail">${it.text ? `<div class="md" style="color:var(--muted)">${md(it.text)}</div>` : '<span class="done">这次的思考内容没有显示，只记录了用时。</span>'}</div>` : '');
  }
  const st = it.state === 'running' ? 'running' : it.state === 'failed' ? 'failed' : '';
  return `<div class="step" data-toggle="${it.id}"><span class="s ${st}"></span><span class="lbl">${esc(it.text)}${it.sub?` · ${esc(it.sub)}`:''}</span></div>` +
    (open ? `<div class="detail">${it.detail?`<pre>${esc(it.detail)}</pre>`:''}${it.result?`<pre>${esc(it.result)}</pre>`:(it.state==='running'?'<span class="done">还在运行…</span>':'')}</div>` : '');
}

function renderSession(){
  const s = SNAP; if (!s) return;
  $('#title').textContent = s.title; $('#folder').textContent = `在「${s.folder}」里工作`;
  $('#mode').textContent = '权限：' + s.mode;
  $('#input').disabled = false; $('#sendBtn').disabled = false;
  $('#stopBtn').classList.toggle('hidden', !s.busy);
  $('#input').placeholder = s.busy ? 'Claude 在忙，可以继续输入，会排在后面处理' : '给 Claude 发消息（回车发送，Shift+回车换行）';
  let h = s.hidden > 0 ? `<button class="btn line more" id="moreBtn">显示更早的内容（还有 ${s.hidden} 条）</button>` : '';
  if (s.loading) h += '<div class="notice">正在载入对话记录…</div>';
  const items = s.items; let i = 0;
  while (i < items.length){
    const it = items[i];
    if (it.kind === 'tool' || it.kind === 'thinking'){
      let run = []; while (i < items.length && (items[i].kind === 'tool' || items[i].kind === 'thinking')) run.push(items[i++]);
      const tools = run.filter(x => x.kind === 'tool');
      if (tools.length >= 4){
        const gid = 'g' + run[0].id, open = OPEN.has(gid), last = tools[tools.length-1];
        const anyRun = run.some(x => x.state === 'running' || x.streaming);
        h += `<div class="rail"><div class="step" data-toggle="${gid}"><span class="s ${anyRun?'running':''}"></span><span class="lbl">执行了 ${tools.length} 个步骤 · 最后：${esc(last.text)}</span></div>${open ? run.map(stepHTML).join('') : ''}</div>`;
      } else h += `<div class="rail">${run.map(stepHTML).join('')}</div>`;
      continue;
    }
    i++;
    switch (it.kind){
      case 'user': {
        const files = (it.files||[]).map(f=>`<span class="chip" title="${esc(f.path)}">📄 ${esc(f.name)}</span>`).join('') + (it.images ? `<span class="chip">🖼 ${it.images} 张图片</span>` : '');
        h += `<div class="u"><div class="b">${esc(it.text)}${files?`<div class="chips">${files}</div>`:''}</div></div>`; break; }
      case 'assistant': h += `<div class="rail a"><div class="md">${md(it.text || (it.streaming?'…':''))}</div></div>`; break;
      case 'notice': h += `<div class="notice">${esc(it.text)}</div>`; break;
      case 'error': h += `<div class="rail"><div class="error">${esc(it.text)}</div></div>`; break;
      case 'local': h += `<div class="rail"><div class="card"><div class="md">${md(it.text)}</div></div></div>`; break;
      case 'login': h += `<div class="rail"><div class="card ask"><h4>电脑上的 Claude 登录已过期</h4><div class="done">需要在那台电脑上点「重新登录」，登录后刚才的消息会自动重发。</div></div></div>`; break;
      case 'artifacts': h += `<div class="rail"><div class="chips">${(it.files||[]).map(f=>`<span class="chip" title="${esc(f.path)}">${f.created?'新建':'修改'} · ${esc(f.name)}</span>`).join('')}</div></div>`; break;
      case 'permission': h += permissionHTML(it); break;
      case 'question': h += questionHTML(it); break;
    }
  }
  const last = items[items.length-1];
  if (s.busy && !(last && last.streaming)) h += `<div class="rail busy"><span class="spin"></span>${esc(s.status || '处理中')}</div>`;
  $('#items').innerHTML = h || '<div class="empty">还没有内容，发一条消息开始。</div>';
  const mb = $('#moreBtn'); if (mb) mb.onclick = () => { LIMIT += 200; loadSession(); };
}

function permissionHTML(it){
  const isPlan = it.tool === 'ExitPlanMode';
  const head = isPlan ? 'Claude 做好了计划，要开始执行吗？' : 'Claude 想执行：' + esc(it.text);
  let body = isPlan && it.plan ? `<div class="md">${md(it.plan)}</div>` : (it.detail ? `<pre>${esc(it.detail)}</pre>` : '');
  if (it.resolved) return `<div class="rail"><div class="card"><h4>${head}</h4>${body}<div class="done">${esc(it.resolved)}</div></div></div>`;
  return `<div class="rail"><div class="card ask"><h4>${head}</h4>${body}<div class="acts">
    <button class="btn quiet" data-act="deny" data-item="${it.id}">${isPlan?'继续改计划':'拒绝'}</button>
    ${isPlan?'':`<button class="btn line" data-act="always" data-item="${it.id}">本次对话都允许</button>`}
    <button class="btn" data-act="allow" data-item="${it.id}">${isPlan?'按计划执行':'允许'}</button></div></div></div>`;
}

function questionHTML(it){
  if (it.resolved) return `<div class="rail"><div class="card"><div class="done">你的回答：${esc(it.resolved)}</div></div></div>`;
  const picks = PICKS[it.id] || (PICKS[it.id] = {});
  const qs = it.questions || [];
  let h = '<div class="rail"><div class="card ask">';
  qs.forEach((q, qi) => {
    h += `<h4>${esc(q.question)}${q.multi?'（可多选）':''}</h4>`;
    q.options.forEach(o => { const on = (picks[qi]||[]).includes(o.label);
      h += `<button class="opt ${on?'on':''}" data-q="${it.id}" data-qi="${qi}" data-multi="${q.multi?1:0}" data-label="${esc(o.label)}">${esc(o.label)}${o.description?`<small>${esc(o.description)}</small>`:''}</button>`; });
  });
  const ready = qs.every((q, qi) => (picks[qi]||[]).length);
  h += `<div class="acts"><button class="btn quiet" data-act="skip" data-item="${it.id}">跳过</button><button class="btn" data-act="answer" data-item="${it.id}" ${ready?'':'disabled'}>提交回答</button></div></div></div>`;
  return h;
}

$('#items').onclick = async e => {
  const t = e.target.closest('[data-toggle]');
  if (t){ const id = t.dataset.toggle; OPEN.has(id) ? OPEN.delete(id) : OPEN.add(id); renderSession(); return; }
  const o = e.target.closest('.opt');
  if (o){ const p = PICKS[o.dataset.q] || (PICKS[o.dataset.q] = {}); const qi = o.dataset.qi; let cur = p[qi] || [];
    if (o.dataset.multi === '1') cur = cur.includes(o.dataset.label) ? cur.filter(x=>x!==o.dataset.label) : [...cur, o.dataset.label]; else cur = [o.dataset.label];
    p[qi] = cur; renderSession(); return; }
  const b = e.target.closest('[data-act]'); if (!b) return;
  const item = b.dataset.item, act = b.dataset.act;
  try {
    if (act === 'allow') await api('/api/allow', {id:CUR, item});
    if (act === 'always') await api('/api/allow', {id:CUR, item, always:true});
    if (act === 'deny'){ const reason = prompt('为什么不行？（可以不填）') ?? null; if (reason === null) return; await api('/api/deny', {id:CUR, item, reason}); }
    if (act === 'skip') await api('/api/deny', {id:CUR, item, reason:'用户没有回答，跳过了这个问题'});
    if (act === 'answer'){ const it = SNAP.items.find(x=>x.id===item), p = PICKS[item]||{}, answers = {};
      it.questions.forEach((q,qi)=>{ answers[q.question] = (p[qi]||[]).join(', '); }); await api('/api/answer', {id:CUR, item, answers}); }
    loadSession();
  } catch(err){ alert(err.message); }
};

// ---------- 输入框 ----------
const input = $('#input');
function grow(){ input.style.height = 'auto'; input.style.height = Math.min(200, input.scrollHeight) + 'px'; }
input.oninput = grow;
input.onkeydown = e => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229){ e.preventDefault(); send(); } };
$('#sendBtn').onclick = send;
$('#stopBtn').onclick = async () => { try { await api('/api/stop', {id:CUR}); } catch(err){ alert(err.message); } };
async function send(){
  const text = input.value.trim(); if (!text || !CUR) return;
  input.value = ''; grow();
  try { await api('/api/send', {id:CUR, text}); loadSession(true); } catch(err){ input.value = text; alert(err.message); }
}

// ---------- 启动 ----------
async function start(){
  try {
    const me = await api('/api/me'); HOST = me.host || '';
    $('#login').classList.add('hidden'); $('#app').classList.remove('hidden');
    document.title = (HOST ? HOST + ' · ' : '') + 'Claude 网页远程';
    await applyTheme(); await loadList(); connect(); setLink(true);
    const want = location.hash.slice(1);
    if (want) select(want);
  } catch(e){ if (e.message !== '401') { showLogin(); $('#loginErr').textContent = '连不上这台电脑：' + e.message; } }
}
applyTheme().then(start);
</script>
</body>
</html>
"""#
}
