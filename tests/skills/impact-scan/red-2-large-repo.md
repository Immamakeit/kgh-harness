# 2차 RED 관찰 — 대형 저장소 (2026-08-20)

1차 관찰(`baseline-results.md`, 2026-07-16)이 열어둔 재검토 조건에 대한 답이다.

> 단, 하네스 통합 후 실사용에서 ④단계 조사 품질 실패가 관찰되면 그 실패를 RED 삼아
> 재검토한다.

**관찰했다. 실패하지 않았다. 기존 결정(impact-scan 미제작)을 유지한다.**

## 왜 다시 봤나

1차 베이스라인은 `tests/fixtures/webapp-legacy` — **파일 8개, 143줄**에서 돌았다.
컨텍스트에 통째로 들어가는 크기다. 그래서 "무도구로 5/5를 찾았다"는 결과가
*대형 저장소에서도 유효한가*는 검증된 적이 없었다.

이 반박이 유효했으므로 실제 대형 저장소에서 다시 관찰했다.

## 설계

| 항목 | 값 |
|---|---|
| 대상 | flow-ai-advisor — 추적 9,298파일 / 942,225줄 |
| 구성 | Java 4,538 · md 1,193 · Vue 1,068 · SQL 587 · JS 535 · TS 364 · Python 131 |
| 질문 | "`AgentType` enum에 `SLACK_NOTIFY` 노드 타입 추가 — 영향도 분석. 수정·신설 파일 전부 나열" |
| A안 | 무도구. 현행 ④ 방식(명시 지시 + 서브에이전트 디스패치) |
| B안 | 동일 + graphify 지식 그래프 (74,309노드 / 211,417엣지, `--code-only`) |
| 모델 | 양쪽 sonnet (컨피그 `defaults.model`) |
| 채점표 | **결과 열람 전 고정.** 초안은 과거 커밋 2건(`31b639243`·`9aecb9ad8`)의 실제 변경 파일 |

### 채점표를 실험 중에 교체했다

과거 커밋 기준 12접점 정답지는 **대상 저장소 자신의 매뉴얼보다 열등**했다.
검증 중 `claudedocs/orchestration/ADDING_NEW_NODE.md` — "신규 노드 추가 가이드
(19단계)"(백엔드 11 + 프론트 8)가 발견되어 이것으로 교체했다.

과거 커밋 기준 항목 2개가 현재 코드에서 무효였다:
- `GraphExecutionEngine.java` — 현재 `AgentType` 참조 0건 (리팩터링으로 소멸)
- `OrchestrationService.js` — 노드 타입 열거 없음 (jsdoc 주석 1줄뿐)

## 결과

| | A안 (무도구) | B안 (graphify) |
|---|---|---|
| 백엔드 11단계 | **11** | 8 |
| 프론트 8단계 | **8** | 7 |
| **합계** | **19 / 19** | **15 / 19** |
| 토큰 | 138,128 | 147,344 |
| 도구 호출 | 75 | 51 |
| 총 벽시계 | **8분 57초** | 11분 15초 (추출 3분 56초 포함) |

B안이 놓친 것: `NodeInputAdapter.PRIMARY_INPUT_KEY`(백4) · `EXECUTOR_CATALOG.md`(백11)
· `NODE_CATALOG.md`(프8) · 트랜잭션 정책 검토(백8).

문서 갱신 2단계를 놓친 이유는 명확하다 — **B안은 `ADDING_NEW_NODE.md`를 끝내 찾지
못했다.** `--code-only` 그래프에 문서가 없으니, 그래프를 신뢰할수록 매뉴얼에서 멀어진다.

### A안이 한 일 (1차 관찰과 같은 패턴)

- 19단계 전부 짚었고, 매뉴얼에 없는 것을 더 찾았다 (`WorkflowLoadModal.vue` 역매핑,
  `manualExecutionFormConstants.js`, `AiGeneratePanel.vue` 4곳, `main.js` 아이콘 미등록,
  `scripts/e2e-matrix/` 감사 스크립트 2종)
- **매뉴얼을 코드와 대조해 매뉴얼이 틀렸다고 보고했다.** 5단계 "nodeType→AgentType
  매핑 3곳"이 실제로는 `AgentTypeResolver` 1곳으로 통합돼 있다는 지적. 직접 확인 결과
  두 위임 메서드 모두 껍데기뿐(`AgentTypeResolver.resolve()` 1줄 위임)이었다 — A안이 맞고
  저장소 문서가 틀렸다.
- 위험을 스스로 발견했다: `LLMRoutingService`가 `AgentType.values()`를 전수 순회하므로
  enum 상수 추가만으로 대화형 라우팅 후보에 자동 편입된다.

B안도 이 마지막 위험을 **독립적으로** 지목했다 (수렴 타당성).

## 왜 도구가 졌나 — 원리적 이유

B안 자신의 조사 메모:

> **프론트엔드 전체**(Vue/JS) — `AgentType`은 Java enum이라 JS 파일과 그래프 엣지가 없고,
> 프론트는 `'slack_notify'` 같은 순수 문자열 키로만 존재하므로 **그래프 순회로는 절대
> 못 찾음.**
>
> 그래프가 알려준 것: `AgentType.java`를 import/reference하는 모든 Java 파일 —
> **grep으로 재확인해도 100% 일치**

독립 측정이 이를 뒷받침한다:

```
Java <-> stt-client 교차 엣지 :  132 / 211,417  =  0.06%
affected "AgentType" --depth 3  ->  641줄, 전부 src/main/java + src/test/java
                                    stt-client 0건, .vue 0건
```

`.vue` 노드는 그래프에 14,434개 있다. **없어서가 아니라 안 이어져서**다.

프론트가 백엔드 enum을 문자열 리터럴로 참조하면 AST가 이을 엣지가 없다. 이건 graphify의
버그가 아니라 AST 파싱의 한계다. 문자열 키로 층위를 잇는 폴리글랏 저장소 전반에 해당한다.

단, 구체 심볼명을 주면 건넌다: `query "ToolPalette ..."`는 `ToolPalette.vue` ↔
`ToolPaletteResponse.java` ↔ `OrchestrationController.getToolPalette()`를 한 번에 반환했다.
능력이 없는 게 아니라 **물어볼 이름을 이미 알아야** 쓸 수 있다(닭-달걀).

## 부수 관찰 — graphify 자체

기본 설치 상태에서 커버리지 결함 3건이 나왔고, **셋 다 경고로 표면화됐다**(silent 아님).

1. **SQL 587파일 전부 누락** — `tree_sitter_sql` 미설치. 이 저장소에서 `.sql`은 세 번째로
   큰 파일군. `graphifyy[sql]` extra가 따로 필요하다.
2. **JSON 308파일 zero-node** — i18n 로케일(`orchestration.json`) 포함. 매뉴얼 프론트
   6단계가 애초에 그래프 밖.
3. `build.gradle` 파싱 실패 (심볼 0개).

코드 추출에 API 키가 필요 없다는 점(`--code-only`)은 광고대로였다.

## 이 관찰이 검증하지 못한 것

- **1회 시행이다.** 재시행 시 흔들릴 수 있다.
- **`--code-only`였다.** 전체 추출(LLM 의미 패스)은 교차 계층 `INFERRED` 엣지를 만들 수
  있다. API 비용 때문에 안 돌렸다. 결론은 **"기본 설치 상태의 graphify"** 에 한정된다.
- **대상 저장소에 매뉴얼이 있었다.** A안이 `ADDING_NEW_NODE.md`를 찾아 이득을 봤다.
  매뉴얼 없는 저장소에선 격차가 줄 수 있다.
- 두 arm 모두 sonnet 단일 시행 — 모델 분산 미측정.

## 결론

**④단계에 도구를 얹지 않는다.** 1차 결정을 유지한다.

사전 등록한 판정 기준은 "B가 A보다 +3 이상 높으면 도입 검토, A가 더 높으면 도입 반대"
였다. **A가 4점 높다.**

1차 관찰의 해석이 대형 저장소에서도 유효한 것으로 확인됐다 — *조사가 판단 질문에 묻혀
있으면 첫 발견에서 멈추지만, "영향도 분석해줘"라고 명시하면 전수 조사를 해낸다.*

재재검토 조건은 1차와 같다: 실사용에서 ④단계 조사 품질 실패가 관찰되면 그 실패를 RED
삼는다. 다만 이제 **8파일과 9,298파일 양쪽에서 실패가 관찰되지 않았다**는 기록이 있다.

---

## 대상 저장소에 전달할 사항 (하네스와 무관)

flow-ai-advisor 쪽 발견이라 여기 남긴다. 두 arm이 독립적으로 지목했다.

- `LLMRoutingService.rankAllAgents()`가 `AgentType.values()`를 필터 없이 전수 순회한다.
  워크플로 구조 노드(`JIRA_CREATE`·`KMS_BULK_UPDATE` 등)가 이미 대화형 라우팅 후보에
  올라가 있다.
- `claudedocs/orchestration/ADDING_NEW_NODE.md` 5단계가 stale하다. "3곳"이 아니라
  `AgentTypeResolver` 1곳이다.
