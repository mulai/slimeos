// The Slime OS desktop window. Everything real happens in the Go core
// (desktop/core, `serve`), started here as a Tauri sidecar and spoken to
// over its stdin/stdout, one JSON object per line (see serve.go's header).

'use strict';

const DASHBOARD = 'https://www.slimeos.com/dashboard';
const tauri = window.__TAURI__;

// ── core ──────────────────────────────────────────────────────────────────

let child = null;
let nextId = 1;
const pending = new Map();

async function startCore() {
  const cmd = tauri.shell.Command.sidecar('binaries/slimeos-desktop-core', ['serve']);
  cmd.stdout.on('data', (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.event) return onEvent(msg);
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.ok) p.resolve(msg.data);
    else p.reject(Object.assign(new Error(msg.error || 'Something went wrong.'), { code: msg.code }));
  });
  cmd.on('close', () => {
    child = null;
    for (const p of pending.values()) p.reject(Object.assign(new Error('The Slime OS core stopped.'), { code: 'core' }));
    pending.clear();
    if (!quitting) showError('Slime OS stopped unexpectedly.', 'Close the app and open it again.', null, {});
  });
  child = await cmd.spawn();
}

function call(cmd, args = {}) {
  if (!child) return Promise.reject(Object.assign(new Error('The Slime OS core isn’t running.'), { code: 'core' }));
  const id = nextId++;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    child.write(JSON.stringify({ id, cmd, ...args }) + '\n');
  });
}

function onEvent(msg) {
  if (msg.event === 'stage' && ui.screen === 'connecting') {
    ui.stage = msg.text;
    const el = document.getElementById('stage');
    if (el) el.textContent = msg.text;
  } else if (msg.event === 'session') {
    if (msg.state === 'open') {
      ui.inSession = true;
      ui.screen = 'session';
      render();
    } else {
      ui.inSession = false;
    }
  }
}

// ── state ─────────────────────────────────────────────────────────────────

const ui = {
  screen: 'loading',
  core: { paired: false, tunnelIP: null, signedIn: null, version: '', platform: '' },
  brains: [],
  brainsError: null,
  code: null,          // Slime ID device code
  pairFor: null,       // the Brain a pairing was asked for
  pairError: null,
  target: null,        // the Brain being connected
  signIn: null,        // {error, username} while asking for the Brain's Windows sign-in
  stage: '',
  error: null,
  inSession: false,
  modal: null,
};
let quitting = false;

async function refreshCore() {
  ui.core = await call('state');
}

async function showHome() {
  ui.modal = null;
  renderModal();
  if (!ui.core.signedIn) {
    ui.screen = 'welcome';
    return render();
  }
  ui.screen = 'picker';
  render();
  try {
    ui.brains = (await call('brains')).brains;
    ui.brainsError = null;
  } catch (e) {
    if (e.code === 'signed_out') {
      ui.core.signedIn = null;
      ui.screen = 'welcome';
    } else {
      ui.brainsError = e.message;
    }
  }
  render();
}

async function signIn() {
  try {
    ui.code = await call('slimeIdStart');
  } catch (e) {
    return showError('Couldn’t start the sign-in.', e.message, null, { back: true });
  }
  ui.screen = 'slimeId';
  render();
  try {
    const who = await call('slimeIdWait');
    ui.core.signedIn = who;
    ui.code = null;
    showHome();
  } catch (e) {
    if (e.code === 'cancelled') return;
    showError('Sign-in didn’t finish.', e.message, null, { retry: signIn, back: true });
  }
}

async function signOut() {
  await call('slimeIdLogout').catch(() => {});
  ui.core.signedIn = null;
  ui.brains = [];
  showHome();
}

function showPair(brain, hint) {
  ui.pairFor = brain || null;
  ui.pairError = null;
  ui.pairHint = hint || null;
  ui.modal = null;
  renderModal();
  ui.screen = 'pair';
  render();
}

async function submitPair(code) {
  ui.pairError = null;
  ui.screen = 'pairing';
  render();
  try {
    await call('pair', { code });
    await refreshCore();
  } catch (e) {
    ui.pairError = e.message;
    ui.screen = 'pair';
    return render();
  }
  if (ui.pairFor) connect(ui.pairFor);
  else showHome();
}

// creds: {username, password, remember} from the sign-in form, else the
// core uses Slime ID's or a remembered one, or answers needs_signin.
async function connect(brain, creds) {
  ui.target = brain;
  if (!ui.core.paired) {
    return showPair(brain, `To reach “${brain.name}”, this ${ui.core.platform === 'darwin' ? 'Mac' : 'PC'} needs a pairing code. Make one on your dashboard.`);
  }
  ui.screen = 'connecting';
  ui.stage = 'Opening the secure tunnel…';
  render();
  const wasFullscreen = await leaveFullscreen();
  try {
    const scale = Math.round((window.devicePixelRatio || 1) * 100);
    await call('connect', { brainId: brain.id, scale, ...creds });
    showHome();
  } catch (e) {
    ui.inSession = false;
    switch (e.code) {
      case 'cancelled':
        return showHome();
      case 'not_paired':
        return showPair(brain, e.message);
      case 'needs_signin':
        return showSignIn(null, '');
      case 'signin_rejected':
        return showSignIn(e.message, creds?.username || '');
      case 'signed_out':
        ui.core.signedIn = null;
        return showHome();
      case 'unreachable':
        return showError(`Can’t reach “${brain.name}”.`, e.message, null, {
          retry: () => connect(brain), pair: () => showPair(brain), back: true,
        });
      default:
        return showError(`Couldn’t connect to “${brain.name}”.`, e.message, e.code, {
          retry: () => connect(brain), back: true,
        });
    }
  } finally {
    if (wasFullscreen && !quitting) tauri.window.getCurrentWindow().setFullscreen(true).catch(() => {});
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// On macOS the session takes a full-screen Space of its own: step out of
// this window's first, so the two don't stack. True if it was full screen.
async function leaveFullscreen() {
  if (ui.core.platform !== 'darwin') return false;
  const win = tauri.window.getCurrentWindow();
  try {
    if (!(await win.isFullscreen())) return false;
    await win.setFullscreen(false);
    for (let i = 0; i < 20 && (await win.isFullscreen()); i++) await sleep(100);
    await sleep(800); // the Space's slide-out animation
    return true;
  } catch {
    return false;
  }
}

function showSignIn(error, username) {
  ui.signIn = { error, username };
  ui.screen = 'signIn';
  render();
}

function cancel() {
  call('cancel').catch(() => {});
}

function showError(title, body, detail, opts) {
  ui.error = { title, body, detail, opts };
  ui.screen = 'error';
  render();
}

// ── rendering ─────────────────────────────────────────────────────────────

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function maskEmail(email) {
  const [local, domain] = String(email || '').split('@');
  if (!domain || !local) return email || '';
  const masked = local.length <= 2 ? local[0] + '*' : local[0] + '***' + local[local.length - 1];
  return masked + '@' + domain;
}

const AVATARS = [
  'linear-gradient(150deg,#00F2FE,#00C2A8)',
  'linear-gradient(150deg,#4FACFE,#00C2A8)',
  'linear-gradient(150deg,#5FE6D2,#00FF87)',
  'linear-gradient(150deg,#f5b955,#ff8f8f)',
];
function avatar(name) {
  let h = 0;
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return AVATARS[h % AVATARS.length];
}

function foot() {
  if (!ui.core.signedIn) return '';
  return `<div class="foot">Signed in as ${esc(maskEmail(ui.core.signedIn.email))} ·
    <button class="btn-ghost" data-act="signOut">Sign out</button></div>`;
}

const screens = {
  loading: () => `<section class="screen"><span class="spinner"></span></section>`,

  welcome: () => `<section class="screen">
      <h1 class="title">Welcome to Slime OS</h1>
      <p class="subtitle">Your Brain is a computer in the cloud that does the heavy lifting.
        Sign in to open it on this ${ui.core.platform === 'darwin' ? 'Mac' : 'PC'}.</p>
      <div class="actions" style="width:280px">
        <button class="btn-primary" data-act="signIn">Sign in with Slime ID</button>
      </div>
      <p class="muted" style="margin-top:24px">No account yet? <a class="link" data-href="https://www.slimeos.com/pricing">See the plans</a></p>
    </section>`,

  slimeId: () => {
    const c = ui.code;
    const url = c.verificationUri || 'https://www.slimeos.com/device';
    const code = c.userCode.length === 8 ? c.userCode.slice(0, 4) + '-' + c.userCode.slice(4) : c.userCode;
    return `<section class="screen"><div class="card">
      <h2 class="title">Sign in with Slime ID</h2>
      <p class="muted">Scan this code with your phone, or visit
        <a class="link" data-href="${esc(url)}">${esc(url.replace(/^https:\/\//, ''))}</a> and enter the code below.</p>
      ${c.qr ? `<img class="qr" alt="" src="${esc(c.qr)}">` : ''}
      <div class="user-code">${esc(code)}</div>
      <div class="waiting"><span class="spinner"></span> Waiting for approval…</div>
      <div class="actions"><button class="btn-secondary" data-act="cancelSignIn">Cancel</button></div>
    </div></section>`;
  },

  picker: () => {
    let body;
    if (ui.brainsError && ui.brains.length === 0) {
      body = `<p class="subtitle">${esc(ui.brainsError)}</p>
        <div class="actions" style="width:220px"><button class="btn-secondary" data-act="home">Try again</button></div>`;
    } else if (ui.brains.length === 0) {
      body = `<p class="subtitle">There are no Brains on your account yet.
        Add one on your <a class="link" data-href="${DASHBOARD}">dashboard</a>, then come back.</p>
        <div class="actions" style="width:220px"><button class="btn-secondary" data-act="home">Refresh</button></div>`;
    } else {
      body = `<div class="picker-list">${ui.brains.map((b, i) => `
        <button class="brain-card" data-brain="${i}">
          <div class="brain-id">
            <div class="brain-avatar" style="background:${avatar(b.name)}">${esc(b.name.trim()[0] || 'B').toUpperCase()}</div>
            <div style="min-width:0">
              <div class="brain-name">${esc(b.name)}${b.kind === 'paid' ? '<span class="badge">Cloud</span>' : ''}</div>
              <div class="brain-host">${esc(b.host)}</div>
            </div>
          </div>
          <div class="brain-meta"><span class="last">${b.kind === 'paid' ? 'Wakes up when you connect' : ''}</span><span class="connect">Connect →</span></div>
        </button>`).join('')}</div>`;
    }
    return `<section class="screen">
      <h1 class="title" style="font-size:26px">Choose a Brain</h1>
      ${ui.brains.length ? '<p class="muted" style="margin-top:4px">Click a card to connect</p>' : ''}
      ${body}
      ${foot()}
    </section>`;
  },

  pair: () => `<section class="screen"><div class="card">
      <h2 class="title">Pair this ${ui.core.platform === 'darwin' ? 'Mac' : 'PC'}</h2>
      <p class="muted">On your <a class="link" data-href="${DASHBOARD}">slimeos.com dashboard</a>, choose
        <b>Pair a device</b> next to your Brain, then enter the code here.</p>
      ${ui.pairHint ? `<div class="hint">${esc(ui.pairHint)}</div>` : ''}
      <form id="pairForm">
        <label class="field-label" for="code">Pairing code</label>
        <input class="field" id="code" autocomplete="off" spellcheck="false" placeholder="XXXX-XXXX" maxlength="16">
        ${ui.pairError ? `<div class="field-error">${esc(ui.pairError)}</div>` : ''}
        <div class="actions">
          <button class="btn-primary" type="submit">Pair</button>
          <button class="btn-secondary" type="button" data-act="home">Cancel</button>
        </div>
      </form>
    </div></section>`,

  signIn: () => `<section class="screen"><div class="card">
      <h2 class="title">Sign in to ${esc(ui.target.name)}</h2>
      <p class="muted">The username and password you use for Windows on this Brain.</p>
      <form id="signInForm">
        <label class="field-label" for="user">Username</label>
        <input class="field plain" id="user" autocomplete="off" spellcheck="false" autocapitalize="off" value="${esc(ui.signIn.username)}">
        <label class="field-label tight" for="pass">Password</label>
        <input class="field plain" id="pass" type="password" autocomplete="off">
        <label class="check"><input type="checkbox" id="remember" checked>
          Remember on this ${ui.core.platform === 'darwin' ? 'Mac' : 'PC'}</label>
        ${ui.signIn.error ? `<div class="field-error">${esc(ui.signIn.error)}</div>` : ''}
        <div class="actions">
          <button class="btn-primary" type="submit">Connect</button>
          <button class="btn-secondary" type="button" data-act="home">Cancel</button>
        </div>
      </form>
    </div></section>`,

  pairing: () => `<section class="screen">
      <div class="ring-wrap"><div class="ring"></div><div class="ring inner"></div><div class="ring-core"></div></div>
      <h2 class="title">Pairing</h2>
      <div class="stage">Fetching your secure tunnel…</div>
    </section>`,

  connecting: () => `<section class="screen">
      <div class="ring-wrap"><div class="ring"></div><div class="ring inner"></div><div class="ring-core"></div></div>
      <h2 class="title">Connecting to ${esc(ui.target.name)}</h2>
      <div class="stage" id="stage">${esc(ui.stage)}</div>
      <div class="actions" style="width:220px"><button class="btn-tertiary" data-act="cancel">Cancel</button></div>
    </section>`,

  session: () => `<section class="screen">
      <div class="ring-wrap"><div class="ring-core still"></div></div>
      <h2 class="title">Connected to ${esc(ui.target.name)}</h2>
      <p class="subtitle">Your Brain is open full screen. ${ui.core.platform === 'darwin'
        ? 'Press <b>Right Shift + Return</b> to switch it to a window and back.'
        : 'Use the bar at the top of the screen to make it a window.'}
        Close it, or sign out of Windows there, to end the session.</p>
      <div class="actions" style="width:220px"><button class="btn-secondary" data-act="cancel">Disconnect</button></div>
    </section>`,

  error: () => {
    const { title, body, detail, opts } = ui.error;
    return `<section class="screen"><div class="error-card">
      <div class="error-icon">!</div>
      <h2 class="title">${esc(title)}</h2>
      ${body ? `<p class="muted">${esc(body)}</p>` : ''}
      <div class="actions">
        ${opts.retry ? '<button class="btn-primary" data-act="retry">Try again</button>' : ''}
        ${opts.pair ? '<button class="btn-secondary" data-act="errPair">Enter a pairing code</button>' : ''}
        ${opts.back ? '<button class="btn-tertiary" data-act="home">Back</button>' : ''}
      </div>
      ${detail ? `<p class="muted" style="margin-top:18px;font-family:var(--font-mono);font-size:11px;color:var(--text-dim)">${esc(detail)}</p>` : ''}
    </div></section>`;
  },
};

function render() {
  document.getElementById('root').innerHTML = screens[ui.screen]();
  const tunnel = document.getElementById('tunnel');
  const up = ui.inSession || ui.screen === 'connecting';
  tunnel.innerHTML = ui.core.paired
    ? `<span class="tunnel-dot ${up ? 'up' : ''}"></span>${up ? 'Secure tunnel' : 'Paired'}`
    : (ui.screen === 'loading' ? '' : `<span class="tunnel-dot"></span>Not paired`);
  if (ui.screen === 'pair') {
    const input = document.getElementById('code');
    input.focus();
    document.getElementById('pairForm').addEventListener('submit', (ev) => {
      ev.preventDefault();
      const code = input.value.trim().toUpperCase();
      if (!code) {
        ui.pairError = 'Enter the pairing code from your dashboard.';
        return render();
      }
      submitPair(code);
    });
  }
  if (ui.screen === 'signIn') {
    const user = document.getElementById('user');
    const pass = document.getElementById('pass');
    (user.value ? pass : user).focus();
    document.getElementById('signInForm').addEventListener('submit', (ev) => {
      ev.preventDefault();
      const username = user.value.trim();
      if (!username || !pass.value) {
        ui.signIn = { error: 'Enter the username and password.', username };
        return render();
      }
      connect(ui.target, { username, password: pass.value, remember: document.getElementById('remember').checked });
    });
  }
}

function renderModal() {
  const root = document.getElementById('modal');
  if (!ui.modal) {
    root.innerHTML = '';
    return;
  }
  let inner = '';
  if (ui.modal === 'settings') {
    const c = ui.core;
    inner = `<h2 class="title">Settings</h2>
      <div class="row"><span class="k">Slime ID</span><span class="v">${c.signedIn ? esc(maskEmail(c.signedIn.email)) : 'Not signed in'}</span></div>
      <div class="row"><span class="k">Pairing</span><span class="v">${c.paired ? 'Paired · ' + esc(c.tunnelIP) : 'Not paired'}</span></div>
      <div class="row"><span class="k">Version</span><span class="v">${esc(c.version)}</span></div>
      <p class="muted" style="font-size:12.5px;margin-top:14px">The pairing is this ${c.platform === 'darwin' ? 'Mac' : 'PC'}’s own secure tunnel to your Brains.
        Pairing again replaces it.</p>
      <div class="modal-buttons">
        <button class="btn-secondary" data-act="pairAgain">${c.paired ? 'Pair again' : 'Pair this device'}</button>
        ${c.paired ? '<button class="btn-danger" data-act="forget">Forget pairing</button>' : ''}
      </div>
      <div class="modal-buttons"><button class="btn-tertiary" data-act="closeModal">Close</button></div>`;
  } else if (ui.modal === 'confirmClose') {
    inner = `<h2 class="title">End your session?</h2>
      <p class="muted">Closing Slime OS disconnects you from ${esc(ui.target?.name || 'your Brain')}. Your Brain keeps your open apps.</p>
      <div class="modal-buttons">
        <button class="btn-secondary" data-act="closeModal">Keep it open</button>
        <button class="btn-danger" data-act="quit">Close Slime OS</button>
      </div>`;
  }
  root.innerHTML = `<div class="modal-overlay" data-act="overlay"><div class="modal-card">${inner}</div></div>`;
}

// ── events ────────────────────────────────────────────────────────────────

const actions = {
  signIn,
  signOut,
  home: showHome,
  cancel,
  cancelSignIn: () => { cancel(); ui.code = null; showHome(); },
  retry: () => ui.error.opts.retry(),
  errPair: () => ui.error.opts.pair(),
  closeModal: () => { ui.modal = null; renderModal(); },
  overlay: () => {},
  pairAgain: () => showPair(null),
  forget: async () => {
    await call('forgetPairing').catch(() => {});
    await refreshCore();
    ui.modal = null;
    renderModal();
    render();
  },
  quit: async () => {
    quitting = true;
    cancel();
    await tauri.window.getCurrentWindow().close();
  },
};

document.addEventListener('click', (ev) => {
  const link = ev.target.closest('[data-href]');
  if (link) {
    ev.preventDefault();
    tauri.shell.open(link.dataset.href);
    return;
  }
  const card = ev.target.closest('[data-brain]');
  if (card) return connect(ui.brains[Number(card.dataset.brain)]);
  const el = ev.target.closest('[data-act]');
  if (el && actions[el.dataset.act]) {
    if (el.dataset.act === 'overlay' && ev.target !== el) return;
    actions[el.dataset.act]();
  }
});

document.getElementById('gear').addEventListener('click', async () => {
  await refreshCore().catch(() => {});
  ui.modal = 'settings';
  renderModal();
});

async function main() {
  if (!tauri) {
    document.getElementById('root').innerHTML = '<section class="screen"><p class="subtitle">Open this inside the Slime OS app.</p></section>';
    return;
  }
  // Closing the window mid-session would cut the session: ask first.
  tauri.window.getCurrentWindow().onCloseRequested((ev) => {
    if (quitting || !(ui.inSession || ui.screen === 'connecting')) return;
    ev.preventDefault();
    ui.modal = 'confirmClose';
    renderModal();
  });
  render();
  try {
    await startCore();
    await refreshCore();
  } catch (e) {
    return showError('Slime OS couldn’t start.', String(e.message || e), null, {});
  }
  showHome();
}

main();
