# webapp-legacy

주문 관리 웹앱. Express + MySQL.

- `server.js` — 엔트리
- `routes/` — auth(로그인), orders(주문 조회·상태 변경)
- `middleware/auth.js` — 세션 검증 미들웨어
- `legacy/notifier.js` — 이메일 알림

테스트는 아직 없음. 배포는 서버에서 `git pull && pm2 restart`.
