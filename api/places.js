// 맛집·카페를 카카오맵과 네이버에서 실시간으로 찾아 주는 서버 코드
// - 키(비밀번호 같은 것)는 Vercel 환경 변수에만 넣어요. 앱(폰)에는 절대 보내지 않아요.
//     KAKAO_REST_KEY      : 카카오 developers 앱의 REST API 키
//     NAVER_CLIENT_ID     : 네이버 developers 앱의 Client ID
//     NAVER_CLIENT_SECRET : 네이버 developers 앱의 Client Secret
// - 사용법
//     /api/places?src=kakao&q=둔촌오륜역 삼겹살&type=food&page=1   → 카카오맵 장소 (한 번에 15곳, 최대 3쪽)
//     /api/places?src=naver&q=둔촌오륜역 삼겹살                     → 네이버 지역 검색 (리뷰 많은 순 5곳)
//     /api/places?src=blog&q=보성갈비 본점 성내동                    → 네이버 블로그 후기 3개
//     /api/places?src=near&px=127.13&py=37.52&type=cafe              → 그 가게 좌표 근처 카페 (가까운 순, 가게에서의 거리)
// - 이용자의 현재 위치는 이 서버로 절대 보내지 않아요. 거리 계산은 이용자 폰 안에서만 해요.
//   (src=near 에는 '가게'의 좌표만 넣어요 — 위치정보법상 개인 위치를 받지 않기 위해서예요)
// - 카카오 결과는 저장(캐시)하지 않고 매번 실시간으로 불러와요. (카카오 운영정책)
const clean = s => String(s || '').replace(/<[^>]*>/g, '').replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#39;/g, "'").trim();

async function kakao(q, type, page, near) {
  const key = process.env.KAKAO_REST_KEY;
  if (!key) return { error: 'nokey', src: 'kakao' };
  const u = new URL('https://dapi.kakao.com/v2/local/search/' + (near ? 'category.json' : 'keyword.json'));
  if (near) { u.searchParams.set('x', String(near.x)); u.searchParams.set('y', String(near.y)); u.searchParams.set('radius', '800'); u.searchParams.set('sort', 'distance'); }
  else u.searchParams.set('query', q);
  if (type !== 'any' || near) u.searchParams.set('category_group_code', type === 'food' ? 'FD6' : 'CE7');
  u.searchParams.set('size', '15');
  u.searchParams.set('page', String(page));
  const r = await fetch(u, { headers: { Authorization: 'KakaoAK ' + key } });
  if (!r.ok) {   // 카카오가 알려 주는 이유(키는 들어 있지 않아요)를 그대로 전해요
    let why = ''; try { const e = await r.json(); why = String(e.message || e.msg || e.errorType || '').slice(0, 160); } catch (e) {}
    return { error: 'upstream ' + r.status, why, src: 'kakao' };
  }
  const j = await r.json();
  return {
    src: 'kakao', end: !!(j.meta && j.meta.is_end), total: (j.meta && j.meta.pageable_count) || 0,
    items: (j.documents || []).map(d => ({
      name: d.place_name, cat: (d.category_name || '').split('>').map(x => x.trim()).filter(Boolean).slice(-1)[0] || '',
      catFull: d.category_name || '', addr: d.road_address_name || d.address_name || '', phone: d.phone || '', url: d.place_url || '',
      x: Number(d.x) || null, y: Number(d.y) || null, dist: d.distance ? Number(d.distance) : null,
    })),
  };
}

async function naver(path, q, extra) {
  const id = process.env.NAVER_CLIENT_ID, sec = process.env.NAVER_CLIENT_SECRET;
  if (!id || !sec) return { error: 'nokey' };
  const u = new URL('https://openapi.naver.com/v1/search/' + path);
  u.searchParams.set('query', q);
  Object.entries(extra).forEach(([k, v]) => u.searchParams.set(k, v));
  const r = await fetch(u, { headers: { 'X-Naver-Client-Id': id, 'X-Naver-Client-Secret': sec } });
  if (!r.ok) return { error: 'upstream ' + r.status };
  return r.json();
}

module.exports = async (req, res) => {
  const q = String((req.query && req.query.q) || '').replace(/\s+/g, ' ').trim().slice(0, 40);
  const src = String((req.query && req.query.src) || 'kakao');
  const type = req.query && ['cafe', 'any'].includes(req.query.type) ? req.query.type : 'food';
  const page = Math.min(3, Math.max(1, parseInt((req.query && req.query.page) || '1', 10) || 1));
  // 가게 좌표 (한국 범위만)
  const px = Number(req.query && req.query.px), py = Number(req.query && req.query.py);
  const near = src === 'near' && px > 124 && px < 132 && py > 33 && py < 39 ? { x: px.toFixed(6), y: py.toFixed(6) } : null;
  if (src === 'near' && !near) return res.status(400).json({ error: 'bad place' });
  if (src !== 'near' && q.length < 2) return res.status(400).json({ error: 'short query' });
  try {
    let out;
    if (src === 'kakao') out = await kakao(q, type, page);
    else if (src === 'near') out = await kakao('', type === 'food' ? 'food' : 'cafe', 1, near);
    else if (src === 'naver') {
      const j = await naver('local.json', q, { display: '5', start: '1', sort: 'comment' });
      out = j.error ? { ...j, src: 'naver' } : { src: 'naver', items: (j.items || []).map(d => ({
        name: clean(d.title), cat: clean((d.category || '').split('>').slice(-1)[0]), catFull: clean(d.category), addr: clean(d.roadAddress || d.address),
        phone: clean(d.telephone), link: /^https?:\/\//.test(d.link || '') ? d.link : '' })) };
    } else if (src === 'blog') {
      const j = await naver('blog.json', q, { display: '3', start: '1', sort: 'sim' });
      out = j.error ? { ...j, src: 'blog' } : { src: 'blog', items: (j.items || []).map(d => ({
        title: clean(d.title), desc: clean(d.description).slice(0, 90), link: /^https?:\/\//.test(d.link || '') ? d.link : '',
        by: clean(d.bloggername), date: String(d.postdate || '').replace(/^(\d{4})(\d{2})(\d{2})$/, '$1.$2.$3') })) };
    } else return res.status(400).json({ error: 'bad src' });
    // 카카오 운영정책: 로컬 API 결과는 실시간 호출로만 써야 하고, 서버·CDN에 임시 저장(캐시)하면 안 돼요
    res.setHeader('Cache-Control', 'no-store');
    return res.status(200).json(out);
  } catch (e) {
    res.setHeader('Cache-Control', 'no-store');
    return res.status(200).json({ error: 'fail', src });
  }
};
