# 참조 문서 목록과 감지 규칙

`/backend-lens:review`는 이 표로 리뷰 대상 프로젝트가 쓰는 기술을 알아내고, 기술에 맞는 참조 문서를 에이전트에 나눠 준다.

- 감지 신호는 백엔드 루트의 빌드 파일(`build.gradle`, `build.gradle.kts`, `pom.xml`, `settings.gradle(.kts)`), `buildSrc/`, `gradle/libs.versions.toml`, 소스 디렉토리 구조에서 찾는다. 코드 식별자 신호(`JdbcTemplate`, `JdbcClient`)는 `src/main` 아래 코드에서 찾는다. 신호 하나만 나와도 그 기술을 쓰는 것으로 본다. 의존성 신호는 아티팩트 이름이 정확히 같을 때만 센다(`spring-boot-starter-web`은 `spring-boot-starter-webflux`와 다른 신호다).
- 쓰는 에이전트 열에 이름이 있는 에이전트만 그 문서를 받는다.
- 새 기술을 더할 때는 이 디렉토리에 문서 하나를 만들고 표 1에 행 하나를 더한다. 표 2에 있던 기술이면 표 2의 행을 지운다. 기술 지식은 참조 문서에만 둔다. 다만 마이그레이션 파일 경로처럼 커맨드의 변경 수집과 에이전트 선택 조건에 적힌 패턴은 기술에 따라 함께 더해야 할 수 있다(예: Liquibase의 changelog 경로).

## 참조 문서

| 문서 | 감지 신호 | 쓰는 에이전트 |
|------|-----------|---------------|
| spring-transaction.md | `org.springframework.boot`, `spring-boot` | transaction-concurrency, responsibility-boundary |
| spring-web.md | `spring-boot-starter-web`, `spring-boot-starter-webmvc`, `spring-webmvc` | api-compatibility, responsibility-boundary |
| jackson.md | `spring-boot-starter-web`, `spring-boot-starter-webmvc`, `spring-webmvc`, `jackson` | api-compatibility |
| jpa-hibernate.md | `spring-boot-starter-data-jpa`, `hibernate-core`, `org.hibernate.orm`, `jakarta.persistence`, `querydsl` | transaction-concurrency, query-performance, migration-safety, responsibility-boundary |
| spring-jdbc.md | `spring-boot-starter-jdbc`, `spring-boot-starter-data-jdbc`, `spring-jdbc`, `JdbcTemplate`, `JdbcClient` | transaction-concurrency, query-performance |
| flyway.md | `flyway` | migration-safety |
| postgresql.md | `postgresql` | transaction-concurrency, query-performance, migration-safety |
| kotlin.md | `org.jetbrains.kotlin`, `kotlin("jvm")`, `kotlin("plugin.spring")`, `src/main/kotlin` | transaction-concurrency, query-performance, migration-safety, api-compatibility, responsibility-boundary, change-resilience |
| java.md | `src/main/java` | transaction-concurrency, query-performance, migration-safety, api-compatibility, responsibility-boundary, change-resilience |

## 참조 문서가 없는 기술

이 기술이 감지되면 리뷰 결과 머리말에 "참조 문서 없이 일반 원칙으로 본 기술"로 알린다.

| 기술 | 감지 신호 |
|------|-----------|
| Liquibase | `liquibase` |
| MySQL, MariaDB | `mysql`, `mariadb` |
| MyBatis | `mybatis` |
| jOOQ | `jooq` |
| R2DBC | `r2dbc` |
| WebFlux | `spring-boot-starter-webflux`가 있고 `spring-boot-starter-web`, `spring-boot-starter-webmvc`, `spring-webmvc`가 없음(WebClient만 쓰려고 넣은 경우를 빼기 위해) |
| Exposed | `org.jetbrains.exposed` |
| MongoDB | `spring-boot-starter-data-mongodb` |
