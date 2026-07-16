const mysql = require('mysql2/promise');

const pool = mysql.createPool({
  host: process.env.DB_HOST || 'localhost',
  user: 'app',
  password: process.env.DB_PASS,
  database: 'webapp',
  connectionLimit: 5
});

module.exports = pool;
