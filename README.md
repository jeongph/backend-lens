# backend-lens

[![version](https://img.shields.io/github/v/release/jeongph/backend-lens?label=version&color=blue)](https://github.com/jeongph/backend-lens/releases)
[![license](https://img.shields.io/github/license/jeongph/backend-lens?color=lightgrey)](LICENSE)

Spring 백엔드 변경을 트랜잭션, 쿼리, 마이그레이션, API 호환, 책임 분리, 변경 대응 관점의 에이전트로 나눠 리뷰합니다.

일반 코드 리뷰가 잘 보지 않는, 백엔드에서 실제로 장애를 내는 결함을 찾는 데 집중합니다. 프록시가 걸리지 않는 `@Transactional`, 동시 요청에서 사라지는 갱신, N+1 쿼리, 큰 테이블을 오래 잠그는 마이그레이션, 구버전 앱을 깨는 응답 변경 같은 것들입니다. 지적마다 어떤 요청이 어떤 순서로 오면 무엇이 깨지는지를 코드 위치와 함께 보여 줍니다. 코드는 고치지 않습니다.

## 설치

[jeongph/claude-plugins 마켓플레이스](https://github.com/jeongph/claude-plugins)에서 설치한다.

마켓플레이스 등록(최초 1회):

```sh
/plugin marketplace add jeongph/claude-plugins
```

플러그인 설치:

```sh
/plugin install backend-lens@jeongph-claude-plugins
```

설치 후 Claude Code를 재시작하면 플러그인이 자동 활성화된다.

## 사용법

```
/backend-lens:review                      기본 브랜치와 갈라진 지점부터 작업 트리까지, 정확성 관점 자동 선택
/backend-lens:review design               책임 분리와 변경 대응만
/backend-lens:review all                  6개 관점 모두 자동 선택
/backend-lens:review transaction query    지정한 관점만
/backend-lens:review #42                  PR 42
/backend-lens:review --base develop       develop과 갈라진 지점부터
/backend-lens:review --suggestions        Suggestion까지 모두 보여 준다
```

| 인자 | 뜻 |
|------|-----|
| (없음) | 정확성 관점 4개(트랜잭션, 쿼리, 마이그레이션, API) 중 바뀐 코드에 해당하는 것을 고른다 |
| `transaction`, `query`, `migration`, `api`, `responsibility`, `change` | 그 관점만 돌린다. 여러 개를 줄 수 있다 |
| `design` | 책임 분리와 변경 대응 두 관점을 돌린다 |
| `all` | 6개 관점 모두를 후보로 바뀐 코드에 해당하는 것을 고른다 |
| `#<번호>` | 그 PR의 diff를 리뷰한다. 로컬 체크아웃이 PR head와 다르면 머리말에 알린다 |
| `--base <ref>` | 그 ref와 갈라진 지점을 기준으로 삼는다 |
| `--suggestions` | Suggestion도 모두 보여 준다 |

기본 범위는 커밋한 변경, 커밋하지 않은 변경, 아직 `git add`하지 않은 새 파일을 모두 포함한다. 기본 브랜치는 `origin/HEAD`로 찾고, `feature/` 브랜치에서 `develop`이 있으면 develop을 쓴다. 기본 브랜치를 찾지 못하면 추측하지 않고 `--base`를 달라고 한다.

결과는 Critical(데이터 손실, 장애, 정합성 깨짐), Important(조건이 맞으면 문제가 됨), Suggestion(구조 개선) 순으로 보여 준다. Suggestion은 기본으로 개수만 적는다. 같은 대화에서 "Suggestion 보여 줘"라고 하면 다시 돌리지 않고 보여 주고, 처음부터 보려면 `--suggestions`를 붙인다. 설계 관점을 이름(`responsibility`, `change`, `design`)으로 요청하면 Suggestion도 함께 보여 준다. `all`은 설계 관점까지 돌리지만 Suggestion은 숨기므로, 설계 관점 결과를 보려면 `design`을 쓰거나 `--suggestions`를 붙인다.

## 관점

| 에이전트 | 보는 것 | 기본 실행 |
|----------|---------|-----------|
| `transaction-concurrency` | 트랜잭션 경계와 프록시, 롤백 규칙, 커밋 전 부수 효과, 갱신 손실, 중복 생성, 잠금 순서와 데드락, 여러 인스턴스에서 겹치는 스케줄 | 예 |
| `query-performance` | N+1, 컬렉션 fetch join과 페이징, 루프 안 쿼리, 상한 없는 조회, 조회 조건에 맞는 인덱스, JDBC 배치 | 예 |
| `migration-safety` | 적용된 마이그레이션 수정, 버전 충돌, 오래 잠그는 DDL, 데이터 손실, 롤링 배포 중 구버전 코드와의 충돌, 엔티티 매핑과 스키마 불일치 | 예 |
| `api-compatibility` | 응답 필드 삭제와 타입 변경, 필수 요청 값 추가, enum 값, 오류 형식, 경로, 날짜와 숫자 형식, 직렬화 전역 설정, 엔티티 직접 노출 | 예 |
| `responsibility-boundary` | 계층과 모듈의 의존 방향, 서비스나 컨트롤러로 새는 도메인 규칙, 엔티티 노출, 격리되지 않은 외부 연동 | 요청할 때만 |
| `change-resilience` | 타입 분기 연쇄, 코드에 박힌 정책 값, 흩어진 같은 규칙, 확장점 부재, 쓰이지 않는 과한 추상화 | 요청할 때만 |

설계 관점 두 개는 지적 대부분이 Suggestion이고, 검증에서 "맞지만 고칠 가치가 없는" 지적이 많았다. 그래서 기본으로는 돌리지 않는다. 모든 에이전트는 opus로 돈다.

## 동작 방식

1. 바뀐 파일을 모으고, 백엔드 루트(Spring Boot를 쓰는 Gradle이나 Maven 프로젝트) 아래의 운영 코드, 빌드 파일, 설정, 마이그레이션만 리뷰 대상으로 고른다. 모노레포의 웹과 모바일 클라이언트 변경은 "그 밖의 변경"으로 따로 넘긴다.
2. 빌드 파일에서 쓰는 기술을 감지해 맞는 참조 문서를 고른다.
3. 바뀐 파일의 디렉토리부터 홈 디렉토리까지 올라가며 `CLAUDE.md`와 `AGENTS.md`를 모으고, 거기서 링크한 문서도 읽는다.
4. 해당하는 관점의 에이전트를 동시에 돌린다. 에이전트는 diff만 보지 않고 호출자, 엔티티 매핑, 기존 마이그레이션, 설정을 따라가 읽는다.
5. 같은 위치의 같은 문제는 하나로 합치고 심각도 순으로 보여 준다.

판단 기준은 이렇다.

- 프로젝트 규칙 문서, 참조 문서, 일반 원칙 순으로 따른다. 프로젝트가 규칙으로 정한 방식은 일반론과 달라도 지적하지 않는다.
- 확신도 80 미만은 보고하지 않는다. 실패 시나리오를 코드 위치로 보일 수 없는 지적도 내지 않는다.
- 테이블 크기, 롤링 배포 여부, 구버전 클라이언트처럼 코드만으로 알 수 없는 운영 사실은 먼저 규칙 문서에서 찾는다. 없으면 가정을 적고 조건부로 보고한다.
- 같은 변경의 설계 문서나 결정 기록이 이미 검토하고 미룬 대안은 지적하지 않는다.

## 지원 기술

| 기술 | 참조 문서 |
|------|-----------|
| Spring Boot 3.x, 4.x(트랜잭션, Web MVC) | `spring-transaction.md`, `spring-web.md` |
| Jackson 2, 3 | `jackson.md` |
| JPA와 Hibernate 6, 7, QueryDSL | `jpa-hibernate.md` |
| Spring JDBC(JdbcTemplate, JdbcClient) | `spring-jdbc.md` |
| Flyway | `flyway.md` |
| PostgreSQL | `postgresql.md` |
| Kotlin, Java | `kotlin.md`, `java.md` |

참조 문서는 항목마다 의심할 코드, 실패 시나리오, 문제가 아닌 경우, 고치는 방향, 공식 출처를 갖는다. Liquibase, MySQL, MyBatis, jOOQ, WebFlux와 R2DBC, Exposed, MongoDB는 감지하면 머리말에 "참조 문서 없이 일반 원칙으로 본 기술"로 알린다.

새 기술을 더할 때는 `references/`에 문서 하나를 만들고 `references/INDEX.md` 표에 행 하나를 더한다. 기술 지식은 참조 문서에만 둔다. 다만 마이그레이션 파일 경로처럼 커맨드의 선택 조건에 적힌 패턴은 기술에 따라 함께 더해야 할 수 있다.

## 예시

MIT 라이선스 공개 프로젝트 [ministryofjustice/visit-scheduler](https://github.com/ministryofjustice/visit-scheduler)의 머지된 PR [#1361](https://github.com/ministryofjustice/visit-scheduler/pull/1361)에 기본 실행으로 돌린 결과 중 하나를 줄였다. 출력 형식을 보여 주려는 예시다.

```
## Important (1)

1. **기존 알림 조회가 쓰기 트랜잭션 밖으로 빠져서, 같은 이벤트가 동시에 처리되면 중복 알림이 남는다** `.../VisitNotificationEventService.kt:624-653` [transaction-concurrency] 확신도 80
   - 문제와 실패 시나리오: 변경 전에는 핸들러에 @Transactional이 있어 기존 알림 조회, 삭제,
     새 알림 저장이 한 트랜잭션이었다. 지금은 조회가 트랜잭션 밖에서 돌고 준영속 엔티티가 쓰기
     트랜잭션으로 넘어간다. deleteAll은 준영속 엔티티를 다시 찾고 행이 없으면 그냥 넘어가므로,
     변경 전에는 충돌로 롤백되던 중복 저장이 이제 조용히 성공한다. 테이블에 유니크 제약도 없다.
     같은 약속의 update 요청 A와 B가 거의 동시에 오면, 둘 다 기존 알림 N1을 읽고, A가 N1을
     지우고 N2를 저장해 커밋한 뒤, B의 삭제는 지울 행이 없어 넘어가고 N3을 저장한다. 같은 방문에
     알림이 두 개 남는다.
   - 가정: 상위 이벤트 소비자가 같은 이벤트를 동시에 두 번 보낼 수 있다(메시지 중복 전달 등).
   - 고치는 방향: 기존 알림 조회를 트랜잭션 메서드 안으로 옮기고, 엔티티 목록 대신 식별자를 넘긴다.
```

## 검증

개발 중에 아래처럼 확인했다. 지적이 맞는지는 리뷰 과정을 모르는 별도 에이전트가 코드를 직접 읽고 판정했다.

- 비공개 Spring 백엔드 세 곳(Kotlin과 JPA, Java와 JPA와 QueryDSL, Kotlin과 JDBC)에 관점마다 두 개 이상, 모두 13개의 결함을 심었다. 13개 모두 Critical이나 Important로 찾았다.
- 이미 머지된 실제 PR 5개(비공개 3개, 공개 2개)에 기본 실행으로 돌렸다. 지적 8개 중 사실 오류는 없었다. Critical과 Important 3개는 모두 고칠 가치가 있었고, Suggestion 5개 중에서는 2개만 고칠 가치가 있었다. 그래서 Suggestion을 기본으로 숨긴다.
- 개발 중 여러 회차를 합치면 정확성 관점의 Important 이상 지적 7개가 모두 맞았다. 설계 관점은 22개 중 10개만 고칠 가치가 있었다.
- 표본이 작다. 숫자는 경향으로만 본다.

## 비용

API 정가(Opus 5.5)로 환산한 실측값이다. 구독 요금제에서는 사용 한도에서 나간다.

| 실행 | 1회 비용 | 측정 |
|------|----------|------|
| 기본 실행(정확성 관점 2~4개) | $5~$10, 중앙값 약 $7 | 실제 PR 5개 |
| `all`(설계 관점 포함) | $10~$15 | 실제 PR 3개 |

바뀐 파일과 읽는 규칙 문서가 많을수록 늘어난다. 백엔드 변경이 없거나 기준 브랜치를 찾지 못해 멈추면 $0.3 안팎이다.

## 한계

- JVM(Java, Kotlin) 위의 Spring 스택만 다룬다. 마이그레이션과 락 판단은 PostgreSQL 기준이다.
- 보안 취약점, 테스트 커버리지, 코드 스타일은 보지 않는다.
- 에이전트는 읽기 전용으로 지시받지만, Bash 도구 자체를 막지는 않는다. 실제로 무엇을 실행할 수 있는지는 사용자의 권한 설정을 따른다.
- 지적은 판단이다. 특히 Suggestion은 프로젝트 상황에 따라 고칠 가치가 없을 수 있다.
- 같은 변경이라도 실행마다 지적이 달라질 수 있다. 위 예시의 지적도 같은 PR을 다시 돌렸을 때 Suggestion으로만 나온 적이 있다. 중요한 변경은 한 번 더 돌려 보는 편이 안전하다.

## 라이선스

MIT ([LICENSE](LICENSE) 참조)
