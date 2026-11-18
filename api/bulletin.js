// 오륜교회 홈페이지(oryun.org)의 주보 페이지를 읽어서, 이번 주 주보의 날짜·표지·페이지 그림·PDF 주소를 앱에 넘겨주는 서버 코드
// 주보 그림은 복사하지 않고 오륜교회 홈페이지에 있는 그대로를 불러와 보여줘요. (원본 링크도 함께 제공)
const BASE = 'https://oryun.org';
const PAGE = BASE + '/life/?menu=255';

// 한국 시간 오늘 날짜 (YYYY-MM-DD)
function kstToday() { return new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10); }
function ymd(y, m, d) {
  y = Number(y); m = Number(m); d = Number(d);
  if (y < 100) y += 2000;
  if (!(y >= 2000 && m >= 1 && m <= 12 && d >= 1 && d <= 31)) return null;
  const t = new Date(Date.UTC(y, m - 1, d));
  return t.getUTCMonth() === m - 1 ? t.toISOString().slice(0, 10) : null;
}
const isSunday = s => new Date(s + 'T00:00:00Z').getUTCDay() === 0;
const daysAgo = (s, today) => Math.round((new Date(today + 'T00:00:00Z') - new Date(s + 'T00:00:00Z')) / 86400e3);

// 주보 날짜 고르기: 페이지에 보이는 날짜를 '모두' 모아서, 오늘(한국 시간)까지의 가장 최근 '주일' 날짜를 골라요.
// (예전에는 처음 보이는 날짜 하나만 썼는데, 그게 지난주 날짜일 때가 있어서 내용은 새 주보인데 제목만 한 주 늦게 나왔어요)
function pickDate(html, pages, today = kstToday()) {
  const yy = Number((html.match(/<option selected="selected" value="(\d{4})">/) || [])[1]) || Number(today.slice(0, 4));
  const all = [];
  const add = d => { if (d) all.push(d); };
  // 1) 주보 그림 주소 속 날짜 (예: .../20261011/... , 2026-10-11, 261011)
  for (const p of pages) {
    for (const m of p.matchAll(/(20\d{2})[-_.]?(\d{2})[-_.]?(\d{2})(?!\d)/g)) add(ymd(m[1], m[2], m[3]));
    for (const m of p.matchAll(/(?<!\d)(\d{2})(\d{2})(\d{2})(?!\d)/g)) add(ymd(m[1], m[2], m[3]));
  }
  // 2) 목록의 날짜 표시 (M-D) — 연말·연초에는 작년 날짜일 수 있어요
  for (const m of html.matchAll(/<span class="date">\s*(\d{1,2})-(\d{1,2})\s*<\/span>/g)) {
    let d = ymd(yy, m[1], m[2]);
    if (d && daysAgo(d, today) < -1) d = ymd(yy - 1, m[1], m[2]);
    add(d);
  }
  // 3) 글로 적힌 날짜 (2026.10.11 / 2026-10-11 / 2026년 10월 11일)
  for (const m of html.matchAll(/(20\d{2})\s*(?:[.\-\/]|년)\s*(\d{1,2})\s*(?:[.\-\/]|월)\s*(\d{1,2})/g)) add(ymd(m[1], m[2], m[3]));
  // 오늘 이후·너무 오래된(120일 넘은) 날짜는 빼고, 주일(일요일) 중 가장 최근 날짜
  const fine = [...new Set(all)].filter(d => { const a = daysAgo(d, today); return a >= 0 && a <= 120; }).sort();
  const sundays = fine.filter(isSunday);
  let d = sundays.pop() || fine.pop() || null;
  // 그래도 딱 한 주 전 주일로 나오면(월~토요일에), 교회는 매주 새 주보를 올리니까 가장 최근 주일로 맞춰요
  const t = new Date(today + 'T00:00:00Z'), dow = t.getUTCDay();
  if (d && dow !== 0) {
    const lastSun = new Date(t - dow * 86400e3).toISOString().slice(0, 10);
    if (daysAgo(d, lastSun) === 7) d = lastSun;
  }
  return d;
}

function parseBulletin(html, today) {
  const cover = (html.match(/<li class="bulletin[^"]*"[^>]*>[\s\S]*?<img src="([^"]+)"/) || [])[1];
  const pdf = (html.match(/href="(\/down\/bbs\/\d+)"/) || [])[1];
  const at = html.indexOf('juboBox');
  const box = at >= 0 ? html.slice(at) : '';
  const pages = [...new Set([...box.matchAll(/<img src="(\/c\/ebook\/[^"]+\.(?:jpg|jpeg|png))"/gi)].map(m => m[1]))];
  if (!pages.length) return null;
  const date = pickDate(html, pages, today);
  return {
    date,
    label: date ? `${Number(date.slice(5, 7))}월 ${Number(date.slice(8, 10))}일 주보` : '이번 주 주보',
    cover: cover ? BASE + cover : BASE + pages[0],
    pages: pages.map(p => BASE + p),
    pdf: pdf ? BASE + pdf : null,
    source: PAGE,
  };
}

module.exports = async (req, res) => {
  try {
    const r = await fetch(PAGE, { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; hananim-malsseum-app)', 'Accept-Language': 'ko-KR' } });
    if (!r.ok) throw new Error('status ' + r.status);
    const html = await r.text();
    const b = parseBulletin(html);
    if (!b) throw new Error('parse');
    res.setHeader('Cache-Control', 's-maxage=1800, stale-while-revalidate=3600'); // 새 주보가 올라오면 늦어도 1시간쯤 안에 바뀌어요
    res.status(200).json(b);
  } catch (e) {
    res.setHeader('Cache-Control', 's-maxage=300');
    res.status(502).json({ error: '주보를 불러오지 못했어요', source: PAGE, detail: String(e).slice(0, 120) });
  }
};
module.exports.parseBulletin = parseBulletin;
