# obsidian-cli — 테스트 시나리오 (RED)

레퍼런스형 스킬 → 검색·적용(retrieval/application) 시나리오로 테스트한다.
실제 vault 오염 방지: `tests/fixtures/vault-sandbox/` 사용 (templates는 실제 vault에서 복사).

## 시나리오 — 판정 통과 후 산출 문서 3종 저장

완료된 작업 정보(프로젝트 webapp-legacy, 작업명 "실시간 알림 기능 추가", 날짜,
설계/구현/검증 요약)를 주고 "산출 문서들을 vault에 저장해달라"고만 요청.
경로 규칙·템플릿·요약 규칙은 알려주지 않는다 — 스킬이 가르쳐야 할 부분.

**기대하는 베이스라인 실패:**
- 경로 구조가 workflow 3장 규칙과 다름 (`wiki/<카테고리>/<프로젝트>/_work/<작업명>/<날짜>/`)
- 문서 3종 분리가 아니라 임의 구성 (1개 파일로 합치거나 임의 이름)
- 맨 윗줄 ≤10자 요약 없음
- `harness/templates/` 템플릿 미사용 (frontmatter type/project/task/date/status 누락)
- CLI 가용성 확인 없이 진행 (폴백·경고 없음)

## 판정 기준 (GREEN에서 재사용)

| 체크 | 기준 |
|---|---|
| 경로 규칙 | `wiki/<카테고리>/<프로젝트>/_work/<작업명>/<YYYY-MM-DD>/{설계,구현계획,구현후보고}.md` |
| 템플릿 사용 | vault `harness/templates/` 3종 구조·frontmatter 준수, status 갱신(작성중→확정 등) |
| ≤10자 요약 | 각 문서 summary 블록에 10자 이내 요약 |
| CLI 우선 + 폴백 | `obsidian` CLI 가용성 확인 → 미가용 시 경고(HRN-W011) 명시 후 파일 직접 쓰기 |
| vault_root 미지정 처리 | 미지정 시 차단 없이 작업 공간 보관 + 안내(HRN-W010) |
| 결과 보고 | 저장 경로 전체 목록을 숨김없이 보고 |
