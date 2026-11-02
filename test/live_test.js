// Run from the repo root:  python3 -m http.server 8765 &  then  node test/live_test.js
const { chromium } = require('playwright');
const path = require('path');
const URL = 'http://localhost:8765/docs/index.html';
(async () => {
  const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--use-file-for-fake-audio-capture=' + __dirname + '/test.wav%noloop', '--autoplay-policy=no-user-gesture-required'] });
  const ctx = await browser.newContext({ permissions: ['microphone'], viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
  const page = await ctx.newPage();
  const logs = []; page.on('pageerror', e => logs.push('PAGEERROR ' + e.message)); page.on('console', m => { if (m.type() === 'error') logs.push('CONSOLE ' + m.text()); });
  await page.goto(URL);
  await page.waitForTimeout(500);
  const t0 = Date.now();
  await page.click('#btnListen');
  await page.waitForTimeout(14000);
  await page.screenshot({ path: path.join(__dirname, 'listen.png') });
  const seen = [];
  for (let i = 0; i < 40; i++) {
    await page.waitForTimeout(5000);
    const n = await page.evaluate(() => window.__kehai.moments.length);
    const st = await page.textContent('#earState');
    seen.push(Math.round((Date.now() - t0) / 1000) + 's:' + n + ':' + st);
    if (Date.now() - t0 > 205000) break;
  }
  console.log(seen.join(' | '));
  const ms = await page.evaluate(() => window.__kehai.moments.map(m => ({ tag: m.tag, score: m.score, dur: +m.dur.toFixed(1) })));
  console.log('live moments:', JSON.stringify(ms));
  console.log('worklet?', await page.evaluate(() => window.__kehai.live.node && window.__kehai.live.node.constructor.name));
  await page.click('#btnListen');
  await page.click('.tabs button[data-view="log"]');
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(__dirname, 'log_phone.png'), fullPage: true });
  console.log(logs.join('\n') || 'no page errors');
  await browser.close();
})();
