const db = require('../db');

// 세션 토큰 검증 미들웨어
async function requireAuth(req, res, next) {
  const token = req.headers['x-session-token'];
  if (!token) return res.status(401).json({ error: 'no token' });

  const [rows] = await db.query(
    'SELECT user_id FROM sessions WHERE token = ? AND expires_at > NOW()',
    [token]
  );
  if (rows.length === 0) return res.status(401).json({ error: 'invalid session' });

  req.userId = rows[0].user_id;
  next();
}

module.exports = { requireAuth };
