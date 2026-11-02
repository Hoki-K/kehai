// Run from the repo root:  python3 -m http.server 8765 &  then  node test/file_test.js
const { chromium } = require('playwright');
const path = require('path');
const URL = 'http://localhost:8765/docs/index.html';
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const logs = [];
  page.on('console', m => logs.push(m.text()));
  page.on('pageerror', e => logs.push('PAGEERROR ' + e.message));
  await page.goto(URL);
  await page.waitForTimeout(500);
  // raw detector events over the test file
  const evs = await page.evaluate(async () => {
    const K = window.__kehai;
    const buf = await (await fetch('../test/test.wav')).arrayBuffer();
    const ab = await new OfflineAudioContext(1, K.SR, K.SR).decodeAudioData(buf);
    const x = ab.getChannelData(0);
    const det = new K.Detector();
    const out = [];
    for (let p = 0; p < x.length; p += 4096) for (const e of det.feed(x.subarray(p, p + 4096))) out.push([+(e.at / K.SR).toFixed(1), e.type, +e.score.toFixed(2)]);
    // compress: first/last per contiguous run
    const runs = []; for (const e of out) { const r = runs[runs.length - 1]; if (r && r.type === e[1] && e[0] - r.end < 1) { r.end = e[0]; r.max = Math.max(r.max, e[2]); r.n++; } else runs.push({ start: e[0], end: e[0], type: e[1], max: e[2], n: 1 }); }
    return runs;
  });
  console.log('detector runs:', JSON.stringify(evs));
  await page.setInputFiles('#fileIn', path.join(__dirname, 'test.wav'));
  await page.waitForFunction(() => /拾いました|見つかりません|読み込めません/.test(document.querySelector('#fileMsg').textContent), null, { timeout: 120000 });
  console.log('msg:', await page.textContent('#fileMsg'));
  const ms = await page.evaluate(() => window.__kehai.moments.map(m => ({ tag: m.tag, score: m.score, dur: +m.dur.toFixed(1), bytes: m.blob.size })));
  console.log('moments:', JSON.stringify(ms));
  await page.click('.tabs button[data-view="log"]');
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(__dirname, 'log.png'), fullPage: true });
  console.log(logs.join('\n'));
  await browser.close();
})();
