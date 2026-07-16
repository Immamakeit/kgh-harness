const express = require('express');
const crypto = require('crypto');
const db = require('../db');

const router = express.Router();

router.post('/login', async (req, res) => {
  const { username, password } = req.body;
  const hash = crypto.createHash('sha256').update(password).digest('hex');

  const [rows] = await db.query(
    'SELECT id FROM users WHERE username = ? AND password_hash = ?',
    [username, hash]
  );
  if (rows.length === 0) return res.status(401).json({ error: 'login failed' });

  const token = crypto.randomBytes(32).toString('hex');
  await db.query(
    'INSERT INTO sessions (user_id, token, expires_at) VALUES (?, ?, DATE_ADD(NOW(), INTERVAL 7 DAY))',
    [rows[0].id, token]
  );
  res.json({ token });
});

module.exports = router;
