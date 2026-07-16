const express = require('express');
const db = require('../db');
const { sendOrderEmail } = require('../legacy/notifier');

const router = express.Router();

// NOTE: 미들웨어 안 거치고 여기서 직접 세션 체크함 (2019년부터 이렇게 씀)
async function checkSession(req) {
  const token = req.headers['x-session-token'];
  if (!token) return null;
  const [rows] = await db.query(
    'SELECT user_id FROM sessions WHERE token = ?', [token]
  );
  return rows.length > 0 ? rows[0].user_id : null;
}

router.get('/', async (req, res) => {
  const userId = await checkSession(req);
  if (!userId) return res.status(401).json({ error: 'unauthorized' });

  const [orders] = await db.query('SELECT * FROM orders WHERE user_id = ?', [userId]);
  res.json(orders);
});

// 주문 상태 변경 (관리자 콘솔에서 호출)
router.put('/:id/status', async (req, res) => {
  const userId = await checkSession(req);
  if (!userId) return res.status(401).json({ error: 'unauthorized' });

  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();

    await conn.query('UPDATE orders SET status = ? WHERE id = ?', [
      req.body.status, req.params.id
    ]);

    const [[order]] = await conn.query(
      'SELECT o.*, u.email FROM orders o JOIN users u ON o.user_id = u.id WHERE o.id = ?',
      [req.params.id]
    );

    // 상태 바뀌면 이메일 알림 — 발송 실패하면 롤백됨 (배송팀 요청으로 2021년에 넣음)
    await sendOrderEmail(order.email, order.id, req.body.status);

    await conn.commit();
    res.json({ ok: true });
  } catch (e) {
    await conn.rollback();
    res.status(500).json({ error: e.message });
  } finally {
    conn.release();
  }
});

module.exports = router;
