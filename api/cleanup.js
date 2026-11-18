// 청소 코드: 매일 새벽 3시(한국 시간) Vercel이 자동으로 불러요 (vercel.json의 crons)
// - 온라인 게임방 중 마지막 활동 후 3시간이 지난 방(마니또 방은 14일)을 지워요.
// - 개인정보처리방침에 적은 "늦어도 다음 날 안에 삭제"를 지키기 위한 장치예요.
// - 공개용(publishable) 키만 써요. 이 함수는 오래된 방을 지우는 일만 할 수 있어요.
const SUPABASE_URL = '__SB_URL__';
const SUPABASE_PUBLISHABLE_KEY = '__SB_KEY__';
module.exports = async (req, res) => {
  try {
    const r = await fetch(SUPABASE_URL + '/rest/v1/rpc/gr_cleanup', {
      method: 'POST', headers: { apikey: SUPABASE_PUBLISHABLE_KEY, 'Content-Type': 'application/json' }, body: '{}',
    });
    const n = await r.json().catch(() => null);
    res.setHeader('Cache-Control', 'no-store');
    return res.status(r.ok ? 200 : 502).json({ ok: r.ok, removed: r.ok ? n : 0 });
  } catch (e) {
    res.setHeader('Cache-Control', 'no-store');
    return res.status(502).json({ ok: false });
  }
};
