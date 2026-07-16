const express = require('express');
const authRoutes = require('./routes/auth');
const orderRoutes = require('./routes/orders');

const app = express();
app.use(express.json());

app.use('/api/auth', authRoutes);
app.use('/api/orders', orderRoutes);

app.listen(8002, () => {
  console.log('webapp-legacy listening on :8002');
});
