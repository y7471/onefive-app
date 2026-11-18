// 오륜교회 주보 그림을 우리 앱 서버가 대신 받아서 넘겨주는 코드
// - 휴대폰 브라우저가 다른 사이트 그림을 막아 흰 화면만 보이는 문제를 피하려고 만들었어요.
// - 오륜교회 주보 그림 주소(oryun.org/c/ebook/...)만 받아요. (아무 주소나 대신 받아주지 않게)
module.exports = async (req, res) => {
  const u = String((req.query && req.query.u) || '');
  const okOryun = /^https:\/\/oryun\.org\/c\/ebook\/[\w\/.-]+\.(?:jpg|jpeg|png)$/i.test(u);
  const okDaniel = /^https:\/\/s3\.ap-northeast-2\.amazonaws\.com\/media\.danielprayer\.org\/[^?#]+\.(?:jpg|jpeg|png)$/i.test(u); // 다니엘기도회 포스터
  if (!(okOryun || okDaniel) || u.includes('..')) return res.status(400).send('bad url');
  try {
    const r = await fetch(u, { headers: { 'User-Agent': 'Mozilla/5.0', 'Referer': okDaniel ? 'https://www.danielprayer.org/' : 'https://oryun.org/life/?menu=255' } });
    if (!r.ok) return res.status(502).send('upstream ' + r.status);
    const buf = Buffer.from(await r.arrayBuffer());
    res.setHeader('Content-Type', r.headers.get('content-type') || 'image/jpeg');
    res.setHeader('Cache-Control', 'public, s-maxage=2592000, max-age=604800, immutable');
    return res.status(200).send(buf);
  } catch (e) {
    return res.status(502).send('fail');
  }
};
