const nodemailer = require('nodemailer');

// SMTP 직접 발송. 평균 1~3초 걸림. 타임아웃 없음.
// TODO: 언젠가 큐로 빼야 하는데... (2022-03 메모)
const transporter = nodemailer.createTransport({
  host: process.env.SMTP_HOST,
  port: 587,
  auth: { user: process.env.SMTP_USER, pass: process.env.SMTP_PASS }
});

async function sendOrderEmail(to, orderId, status) {
  await transporter.sendMail({
    from: 'noreply@webapp.example',
    to,
    subject: `주문 #${orderId} 상태 변경`,
    text: `주문 상태가 '${status}'(으)로 변경되었습니다.`
  });
}

module.exports = { sendOrderEmail };
