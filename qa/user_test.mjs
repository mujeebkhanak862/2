// "Ek user ki tarah" test: asli Chromium (Playwright) mein website kholte hain,
// asli click/type/scroll karte hain. Backend (Dart server) yahan chal nahi
// sakta (no Dart runtime, no network in this sandbox), isliye use mock karte
// hain — HTTP aur WebSocket dono — lekin website ka JS bilkul waisa hi chalta
// hai jaisa real browser mein chalega. Maqsad: UI bugs, galat field names,
// galat coordinate math, crash/console errors pakadna — jo sirf syntax-check
// se nahi pakde ja sakte.
import { chromium } from 'playwright';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const DASH_DIR = path.resolve('/home/claude/uda/universal_device_agent/web_dashboard');
const PORT = 8731;
const MOCK_HOST = 'mock-server.test';
const TOKEN = 'a'.repeat(40);
const JPEG = readFileSync('/tmp/mockframe.jpg');

const results = [];
function check(name, cond, detail) {
  results.push({ name, pass: !!cond, detail: detail || '' });
  console.log((cond ? 'PASS' : 'FAIL') + '  ' + name + (detail ? '  -- ' + detail : ''));
}

const devicesPayload = {
  devices: [
    { id: 'dev_1', name: 'Pixel Test Phone', platform: 'android', state: 'idle',
      battery_percent: 77, connected: true, active_task_count: 1,
      active_tasks: [{ task_id: 'tsk_123456789', state: 'running', originating_capability: 'input' }] },
    { id: 'dev_2', name: 'Office PC', platform: 'windows', state: 'idle',
      battery_percent: null, connected: false, active_task_count: 0, active_tasks: [] },
  ],
};

async function main() {
  const server = spawn('python3', ['-m', 'http.server', String(PORT), '--directory', DASH_DIR]);
  await new Promise((r) => setTimeout(r, 500));

  const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] });
  const page = await browser.newPage();
  const consoleErrors = [];
  page.on('console', (msg) => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
  page.on('pageerror', (err) => consoleErrors.push('pageerror: ' + err.message));

  const sentControl = [];     // {id, device_id, capability, action, params}
  let screenSocketOpened = false, audioSocketOpened = false, controlSocketOpened = false;
  let screenFramesSent = 0, audioChunksSent = 0;

  await page.routeWebSocket(new RegExp('^wss?://' + MOCK_HOST), (ws) => {
    const url = ws.url();
    if (url.includes('/admin/control')) {
      controlSocketOpened = true;
      ws.onMessage((raw) => {
        let m; try { m = JSON.parse(raw); } catch { return; }
        sentControl.push(m);
        let result = {};
        if (m.capability === '__ping') result = { pong: true };
        else if (m.action === 'screen.watch_live') result = { started: true, first_frame_received: true, screen: { width: 1080, height: 2400 }, fps: m.params.fps || 20, quality: m.params.quality || 'high' };
        else if (m.action === 'audio.watch_live') result = { started: true, sample_rate: 16000, channels: 1, format: 'pcm_s16le' };
        else if (m.action === 'clipboard.read') result = { text: 'mock-clipboard-text' };
        setTimeout(() => ws.send(JSON.stringify({ id: m.id, ok: true, result })), 15);
      });
    } else if (url.includes('/screen/')) {
      screenSocketOpened = true;
      const t = setInterval(() => { ws.send(JEPG_BIN()); screenFramesSent++; }, 80);
      ws.onClose(() => clearInterval(t));
    } else if (url.includes('/audio/')) {
      audioSocketOpened = true;
      const pcm = Buffer.alloc(640);
      const t = setInterval(() => { ws.send(pcm); audioChunksSent++; }, 20);
      ws.onClose(() => clearInterval(t));
    }
  });
  function JEPG_BIN() { return JPEG; }

  await page.route('http://' + MOCK_HOST + '/**', async (route) => {
    const req = route.request();
    const u = new URL(req.url());
    const headers = {
      'access-control-allow-origin': 'http://127.0.0.1:' + PORT,
      'access-control-allow-headers': 'Authorization, Content-Type',
      'access-control-allow-methods': 'GET, POST, OPTIONS',
      'content-type': 'application/json',
    };
    if (req.method() === 'OPTIONS') return route.fulfill({ status: 204, headers });
    const auth = req.headers()['authorization'] || '';
    if (auth !== 'Bearer ' + TOKEN) return route.fulfill({ status: 401, headers, body: JSON.stringify({ message: 'bad token' }) });
    if (u.pathname === '/admin/devices') return route.fulfill({ status: 200, headers, body: JSON.stringify(devicesPayload) });
    if (u.pathname === '/admin/ws-ticket') return route.fulfill({ status: 200, headers, body: JSON.stringify({ ticket: 't-' + Math.random(), expires_in: 60 }) });
    return route.fulfill({ status: 404, headers, body: '{}' });
  });

  // ---- 1. Login page loads ----
  await page.goto('http://127.0.0.1:' + PORT + '/index.html');
  check('Login screen title visible', await page.locator('#login h2').isVisible());

  // ---- 2. Wrong token -> rejected, clear error shown ----
  await page.fill('#srv', 'http://' + MOCK_HOST);
  await page.fill('#tok', 'wrong-token-wrong-token-wrong-token-xx');
  await page.click('#loginBtn');
  await page.waitForTimeout(400);
  const loginErr = await page.locator('#loginErr').textContent();
  check('Wrong token shows an error (not silent/crash)', loginErr && loginErr.trim().length > 0, loginErr);
  check('Still on login screen after wrong token', await page.locator('#login').isVisible());
  // Is step ka 401 Chromium khud ek "failed resource load" console error ke
  // roop mein log karta hai — yeh expected hai (hum jaan-boojh kar galat token
  // bhej rahe hain), JS crash nahi. Isliye yahan se aage ka hi hisaab rakhte hain.
  consoleErrors.length = 0;

  // ---- 3. Correct login ----
  await page.fill('#tok', TOKEN);
  await page.click('#loginBtn');
  await page.waitForSelector('#app', { state: 'visible', timeout: 5000 });
  check('App screen visible after correct login', true);

  // ---- 4. Device list ----
  await page.waitForTimeout(300);
  const devCount = await page.locator('#devList .dev').count();
  check('Both mock devices rendered', devCount === 2, 'got ' + devCount);
  const firstName = await page.locator('#devList .dev .name').first().textContent();
  check('Connected device (dev_1) listed first', firstName === 'Pixel Test Phone', firstName);
  const taskLine = await page.locator('#devList .dev .task').first().textContent();
  check('Active task shown under device', /running/.test(taskLine || ''), taskLine);

  // ---- 5. Select device ----
  await page.locator('#devList .dev').first().click();
  check('Device card gets selected style', await page.locator('#devList .dev').first().evaluate(el => el.classList.contains('sel')));
  check('Watch Live button enabled for online device', await page.locator('#watchBtn').isEnabled());
  await page.waitForTimeout(200);
  check('Control WebSocket opened on device select', controlSocketOpened);

  // ---- 6. Watch Live ----
  await page.click('#watchBtn');
  await page.waitForTimeout(400);
  const watchMsg = sentControl.find((m) => m.action === 'screen.watch_live');
  check('screen.watch_live sent with session_id/fps/quality', !!(watchMsg && watchMsg.params.session_id && watchMsg.params.fps && watchMsg.params.quality), JSON.stringify(watchMsg && watchMsg.params));
  check('Screen WebSocket connected after watch_live', screenSocketOpened);
  await page.waitForTimeout(500);
  check('Canvas visible (frames flowing)', await page.locator('#screen').isVisible());
  const canvasSize = await page.locator('#screen').evaluate((c) => ({ w: c.width, h: c.height }));
  check('Canvas got real pixel dimensions from decoded JPEG frame', canvasSize.w === 270 && canvasSize.h === 600, JSON.stringify(canvasSize));
  check('At least one frame was actually sent by mock', screenFramesSent > 0, 'frames=' + screenFramesSent);
  await page.waitForTimeout(1200);
  const statsText = await page.locator('#stats').textContent();
  check('FPS/KB-s stats counter updates (not stuck at —)', /fps/.test(statsText || ''), statsText);
  await page.screenshot({ path: '/home/claude/uda/qa/screenshot_live_view.png' });

  // ---- 7. Tap on canvas -> coordinate mapping ----
  const box = await page.locator('#screen').boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.up();
  await page.waitForTimeout(300);
  const tapMsg = [...sentControl].reverse().find((m) => m.action === 'input.tap');
  const expectedX = Math.round(1080 / 2), expectedY = Math.round(2400 / 2);
  const tapOk = tapMsg && Math.abs(tapMsg.params.x - expectedX) <= 2 && Math.abs(tapMsg.params.y - expectedY) <= 2;
  check('Center click maps to center of real device screen (1080x2400)', tapOk,
        'got ' + JSON.stringify(tapMsg && tapMsg.params) + ' expected ~(' + expectedX + ',' + expectedY + ')');

  // ---- 8. Swipe ----
  await page.mouse.move(box.x + box.width * 0.1, box.y + box.height * 0.1);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.9, box.y + box.height * 0.9, { steps: 8 });
  await page.mouse.up();
  await page.waitForTimeout(300);
  const swipeMsg = [...sentControl].reverse().find((m) => m.action === 'input.swipe');
  check('Drag produces input.swipe (not a tap)', !!swipeMsg, JSON.stringify(swipeMsg && swipeMsg.params));

  // ---- 9. Keys ----
  await page.click('button.keyBtn[data-key="back"]');
  await page.waitForTimeout(250);
  check('Back button sends input.key back', sentControl.some((m) => m.action === 'input.key' && m.params.key === 'back'));

  // ---- 10. Type text ----
  await page.fill('#typeBox', 'hello from the web dashboard');
  await page.click('#typeBtn');
  await page.waitForTimeout(300);
  const typeMsg = [...sentControl].reverse().find((m) => m.action === 'input.type_text');
  check('Typed text forwarded as input.type_text', typeMsg && typeMsg.params.text === 'hello from the web dashboard', JSON.stringify(typeMsg && typeMsg.params));
  check('Text box clears after sending', (await page.locator('#typeBox').inputValue()) === '');
  check('Success toast shown for typing', await page.locator('.toast.ok').count() > 0);

  // ---- 11. Clipboard send + read ----
  await page.fill('#clipBox', 'copied-from-pc');
  await page.click('#clipSendBtn');
  await page.waitForTimeout(250);
  check('Clipboard text sent as clipboard.write', sentControl.some((m) => m.action === 'clipboard.write' && m.params.text === 'copied-from-pc'));
  await page.click('#clipReadBtn');
  await page.waitForTimeout(250);
  check('Device clipboard read back into the textbox', (await page.locator('#clipBox').inputValue()) === 'mock-clipboard-text');

  // ---- 12. Audio ----
  await page.click('#audioBtn');
  await page.waitForTimeout(400);
  check('audio.watch_live sent on Audio toggle', sentControl.some((m) => m.action === 'audio.watch_live'));
  check('Audio WebSocket connected', audioSocketOpened);
  await page.waitForTimeout(300);
  check('PCM audio chunks actually flowing', audioChunksSent > 3, 'chunks=' + audioChunksSent);
  const audioBtnText = await page.locator('#audioBtn').textContent();
  check('Audio button reflects ON state', /Audio on/.test(audioBtnText || ''), audioBtnText);

  // ---- 13. Ping meter ----
  await page.waitForTimeout(1200);
  const pingText = await page.locator('#pingPill').textContent();
  check('Signal/ping meter shows a measured value', /ms$/.test((pingText || '').trim()), pingText);

  // ---- 14. Stop live ----
  await page.click('#stopBtn');
  await page.waitForTimeout(400);
  check('screen.stop_live sent on Stop', sentControl.some((m) => m.action === 'screen.stop_live'));
  check('audio.stop_live ALSO sent on Stop (audio tied to live view lifecycle)', sentControl.some((m) => m.action === 'audio.stop_live'));
  check('Canvas hidden again after Stop', !(await page.locator('#screen').isVisible()));
  check('Watch Live re-enabled after Stop', await page.locator('#watchBtn').isEnabled());

  // ---- 15. Offline device shows disabled controls ----
  await page.locator('#devList .dev').nth(1).click();
  check('Offline device: Watch Live disabled', !(await page.locator('#watchBtn').isEnabled()));
  check('Offline device: key buttons disabled', !(await page.locator('button.keyBtn').first().isEnabled()));

  // ---- 16. Logout ----
  await page.click('#logoutBtn');
  await page.waitForTimeout(200);
  check('Back to login screen after logout', await page.locator('#login').isVisible());
  check('App screen hidden after logout', !(await page.locator('#app').isVisible()));

  // ---- 17. No console/page errors the whole session ----
  check('Zero uncaught console/page errors during the whole session', consoleErrors.length === 0, consoleErrors.join(' | '));

  await browser.close();
  server.kill();

  const failed = results.filter((r) => !r.pass);
  console.log('\n' + '='.repeat(60));
  console.log(`RESULT: ${results.length - failed.length}/${results.length} passed`);
  if (failed.length) {
    console.log('FAILED:');
    for (const f of failed) console.log('  - ' + f.name + (f.detail ? ' :: ' + f.detail : ''));
  }
  process.exit(failed.length ? 1 : 0);
}
main().catch((e) => { console.error('HARNESS CRASH:', e); process.exit(2); });
