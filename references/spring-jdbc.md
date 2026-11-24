# Spring JDBC 참조

적용 버전: Spring Boot 3.x와 4.x, Spring Framework 6.x와 7.x, PostgreSQL JDBC 드라이버(PgJDBC) 42.x, PostgreSQL. Spring Boot 3.0과 3.1은 Spring Framework 6.0, 3.2와 3.3은 6.1, 3.4와 3.5는 6.2, 4.0과 4.1은 7.0, 4.2는 7.1을 쓴다. `JdbcClient`는 Spring Framework 6.1(Spring Boot 3.2)부터 있다. 버전에 따라 결론이 갈리는 내용은 해당 항목 안에 버전을 적었다.

## 루프마다 보내는 쿼리와 batchUpdate

- 의심할 코드: `for`나 `forEach` 안에서 `jdbcTemplate.update(...)`, `namedParameterJdbcTemplate.update(...)`, `jdbcClient.sql(...).update()`를 건마다 부르는 코드. 루프 안의 단건 `query`, `queryForObject`도 같다.
- 실패 시나리오: 목록 크기만큼 DB 왕복이 생긴다. 만 건이면 문장 만 개가 각각 왕복하고, 트랜잭션 안이면 그동안 커넥션과 락을 쥔다.
- 문제가 아닌 경우: 루프 횟수가 코드에서 작게 고정된 경우. 건마다 앞 결과를 보고 다음 문장을 정해야 하는 경우. `INSERT ... SELECT`나 `UPDATE ... WHERE id = any(?)`처럼 이미 한 문장으로 묶은 경우.
- 고치는 방향: 같은 SQL이면 `batchUpdate`로 묶는다. 목록과 배치 크기를 받는 오버로드는 크기별로 나눠 실행한다. Spring Framework 7.1 이상(Spring Boot 4.2)은 `JdbcClient`의 `batch()`로도 묶을 수 있다. 조회는 `IN`이나 `= any(?)`로 한 번에 읽는다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/jdbc/advanced.html#jdbc-batch-classic, https://docs.spring.io/spring-framework/reference/data-access/jdbc/advanced.html#jdbc-batch-multi, https://docs.spring.io/spring-framework/reference/data-access/jdbc/core.html#jdbc-JdbcClient, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-jdbc/src/main/java/org/springframework/jdbc/core/simple/JdbcClient.java

## IN 절 파라미터 확장과 긴 목록

- 의심할 코드: `where id in (:ids)`에 `List`를 넘기는 `NamedParameterJdbcTemplate`이나 `JdbcClient` 코드. 목록 크기가 요청 입력이나 앞선 조회 결과로 정해지는 경우. 빈 목록이 들어올 수 있는 경우. 위치 파라미터 `in (?)` 하나에 `List`를 넘기는 코드.
- 실패 시나리오: 이름 있는 파라미터에 넘긴 컬렉션은 원소 수만큼 `?`로 펼쳐진다. PgJDBC 기본 모드(확장 쿼리 프로토콜)에서는 한 문장의 바인드 파라미터가 65535개로 제한되어 그보다 긴 목록은 실행되지 않는다. 빈 목록이면 SQL이 `in ()`이 되어 PostgreSQL 문법 오류가 난다. 위치 파라미터 `?`는 펼쳐지지 않으므로 `List` 하나를 넘기면 의도한 조회가 되지 않는다.
- 문제가 아닌 경우: 목록 크기에 코드상 상한(페이지 크기 등)이 있고, 빈 목록이면 호출 전에 반환하는 경우. `JdbcClient`는 이름 있는 파라미터를 쓰면 `NamedParameterJdbcTemplate`으로 실행되어 같은 확장이 적용되므로 정상이다.
- 고치는 방향: 빈 목록은 쿼리 전에 걸러 빈 결과를 돌려준다. 길이가 열린 목록은 배열 파라미터 하나로 `where id = any(?)`에 넘기거나(PgJDBC는 `Long[]` 같은 배열을 `setObject`로 받는다) 일정 크기로 나눠 조회한다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/jdbc/parameter-handling.html#jdbc-in-clause, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-jdbc/src/main/java/org/springframework/jdbc/core/namedparam/NamedParameterUtils.java, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-jdbc/src/main/java/org/springframework/jdbc/core/simple/DefaultJdbcClient.java, https://jdbc.postgresql.org/documentation/use/, https://jdbc.postgresql.org/documentation/server-prepare/#arrays, https://www.postgresql.org/docs/current/functions-comparisons.html#FUNCTIONS-COMPARISONS-ANY-SOME

## PostgreSQL 드라이버의 reWriteBatchedInserts

- 의심할 코드: `batchUpdate`나 JPA 배치로 대량 INSERT를 하는데 JDBC URL이나 데이터소스 속성에 `reWriteBatchedInserts=true`가 없는 경우. 반대로 이 옵션을 켠 상태에서 `batchUpdate` 반환 배열을 건마다 `== 1`로 검사하는 코드.
- 실패 시나리오: 옵션이 없으면 배치 INSERT가 문장 단위로 실행된다. 드라이버 문서는 다중 VALUES로 바꿔 쓰면 2배에서 3배 빨라진다고 적는다. 옵션을 켜면 드라이버가 여러 INSERT를 `values (...), (...)` 하나로 합치므로 건별 결과를 알 수 없어, 갱신 건수를 `Statement.SUCCESS_NO_INFO`(-2)로 채운다. 건수를 1과 비교하는 코드는 정상 저장을 실패로 판단한다.
- 문제가 아닌 경우: 이 옵션은 INSERT 배치만 바꾸므로 UPDATE, DELETE 배치에서 옵션이 없다는 지적은 하지 않는다. 배치 크기가 작거나 단건 INSERT 위주인 경로. Hibernate의 IDENTITY 엔티티는 애초에 INSERT 배치가 되지 않으므로 이 옵션과 무관하다.
- 고치는 방향: 대량 INSERT 경로가 있으면 옵션을 켠다. 반환 배열은 -2를 성공으로 취급하거나, 건수 대신 예외 여부로 성공을 판단한다.
- 출처: https://jdbc.postgresql.org/documentation/use/, https://github.com/pgjdbc/pgjdbc/blob/REL42.7.8/pgjdbc/src/main/java/org/postgresql/jdbc/BatchResultHandler.java, https://docs.spring.io/spring-framework/reference/data-access/jdbc/advanced.html#jdbc-batch-list

## Spring 트랜잭션 참여

- 의심할 코드: `@Transactional` 없이 여러 `update`를 연달아 부르는 메서드. `dataSource.getConnection()`을 직접 쓰는 코드. DataSource가 둘 이상인데 트랜잭션 매니저와 `JdbcTemplate`이 서로 다른 DataSource를 쓰는 설정. JPA 엔티티를 바꾼 뒤 같은 트랜잭션에서 `JdbcTemplate`이나 `JdbcClient`로 같은 테이블을 읽거나 쓰는 코드.
- 실패 시나리오: `JdbcTemplate`은 `DataSourceUtils`로 커넥션을 얻어 현재 스레드에 묶인 트랜잭션 커넥션에 참여하고, `JdbcClient`는 내부에서 `JdbcTemplate`을 쓴다. 트랜잭션이 없으면 호출마다 커넥션을 얻고 반납해 문장마다 따로 커밋되므로, 중간에 실패하면 앞 문장만 반영된다. `dataSource.getConnection()`을 직접 쓰거나 트랜잭션 매니저와 다른 DataSource를 쓰면 트랜잭션에 참여하지 않는다(트랜잭션 매니저는 자기 DataSource의 커넥션만 스레드에 묶는다). JPA와 섞으면 Hibernate의 AUTO flush는 JPQL, HQL, 네이티브 쿼리 실행 전에만 일어나므로, `JdbcTemplate`으로 보낸 SQL은 아직 flush되지 않은 엔티티 변경을 보지 못한다.
- 문제가 아닌 경우: Spring Boot 기본 구성처럼 `JpaTransactionManager`나 `DataSourceTransactionManager`가 `JdbcTemplate`과 같은 DataSource를 쓰면 같은 커넥션과 트랜잭션에 참여한다. 문장 하나만 실행하는 메서드는 트랜잭션이 없어도 그 문장 자체는 원자적이다.
- 고치는 방향: 여러 문장을 묶어야 하면 서비스 메서드에 `@Transactional`을 둔다. JPA로 바꾼 뒤 JDBC로 읽거나 쓰기 전에 `entityManager.flush()`를 부른다. DataSource가 여럿이면 DataSource마다 트랜잭션 매니저를 두고 맞는 매니저를 지정한다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/jdbc/connections.html#jdbc-DataSourceUtils, https://docs.spring.io/spring-framework/reference/data-access/jdbc/connections.html#jdbc-DataSourceTransactionManager, https://docs.spring.io/spring-framework/reference/data-access/orm/jpa.html#orm-jpa-tx, https://docs.hibernate.org/orm/7.1/userguide/html_single/#flushing-auto, https://www.postgresql.org/docs/current/tutorial-transactions.html

## 수동 낙관적 락의 갱신 행 수

- 의심할 코드: `update orders set ..., version = version + 1 where id = ? and version = ?`를 `jdbcTemplate.update`나 `jdbcClient.sql(...).update()`로 실행하고 반환값을 버리는 코드. version 조건 없이 `where id = ?`만으로, 앞서 읽은 값을 기준으로 계산한 결과를 덮어쓰는 수정.
- 실패 시나리오: 다른 요청이 먼저 version을 올렸으면 이 UPDATE는 0행을 바꾸고 예외 없이 끝난다. 반환값을 보지 않으면 충돌을 성공으로 처리해, 사용자는 저장됐다고 보고 뒤따르는 이벤트 발행이나 재고 차감도 그대로 진행된다.
- 문제가 아닌 경우: 반환값이 1이 아니면 예외를 던지거나 분기하는 코드. Spring Data JDBC의 `@Version` 엔티티를 리포지토리로 저장하는 경우는 프레임워크가 version 조건을 넣고 불일치하면 `OptimisticLockingFailureException`을 던진다. 마지막 쓰기 우선이 요구사항인 경우.
- 고치는 방향: `int updated = ...update();`로 받아 0이면 `OptimisticLockingFailureException` 같은 충돌 예외를 던진다. 0행이 "행 없음"인지 "버전 충돌"인지 구분해야 하면 존재 여부를 따로 확인한다.
- 출처: https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/jdbc/core/JdbcOperations.html, https://docs.spring.io/spring-data/relational/reference/jdbc/entity-persistence.html#jdbc.entity-persistence.optimistic-locking

## INSERT ... ON CONFLICT로 중복 생성 막기

- 의심할 코드: "없으면 만든다"를 SELECT와 INSERT로 나눈 코드(`exists`나 `count` 조회 뒤 INSERT). `ON CONFLICT DO NOTHING RETURNING id` 결과를 `queryForObject`나 `single()`로 받는 코드. 대상 칼럼에 unique 제약이 있는지 확인되지 않은 `ON CONFLICT (col)`. 중복 키 예외를 잡고 같은 트랜잭션에서 계속 진행하는 코드.
- 실패 시나리오: SELECT 후 INSERT는 동시 요청 두 개가 둘 다 "없음"을 보고 둘 다 INSERT한다. unique 제약이 없으면 중복 행이 생기고, 있으면 한쪽이 `DuplicateKeyException`으로 실패한다. `DO NOTHING`이 충돌하면 갱신 건수는 0이고 `RETURNING`도 행을 돌려주지 않으므로 `queryForObject`가 `EmptyResultDataAccessException`을 던진다. conflict_target에 맞는 unique 인덱스가 없으면 문장 자체가 오류다. PostgreSQL은 트랜잭션 블록 안에서 문장이 실패하면 트랜잭션을 중단 상태로 만들어, 예외를 잡은 뒤 같은 트랜잭션에서 보낸 SQL은 모두 거부된다.
- 문제가 아닌 경우: unique 제약이 있고 중복을 사용자 오류로 돌려주는 것이 요구사항인 경우. `ON CONFLICT DO UPDATE`는 동시 실행에서도 INSERT나 UPDATE 중 하나를 원자적으로 보장한다. `DO NOTHING` 뒤 갱신 건수 0을 "이미 있음"으로 처리하는 코드.
- 고치는 방향: unique 제약을 두고 `INSERT ... ON CONFLICT (key) DO NOTHING`이나 `DO UPDATE`를 쓴다. 기존 행의 ID가 필요하면 0행일 때 다시 SELECT하거나, PostgreSQL 19 이상이면 `ON CONFLICT DO SELECT ... RETURNING`을 쓴다. 여러 행을 한 번에 넣는 `DO UPDATE`는 같은 키가 두 번 나오면 오류이므로 입력에서 중복을 먼저 없앤다.
- 출처: https://www.postgresql.org/docs/18/sql-insert.html#SQL-ON-CONFLICT, https://www.postgresql.org/docs/current/sql-insert.html#SQL-ON-CONFLICT, https://www.postgresql.org/docs/current/tutorial-transactions.html

## SELECT ... FOR UPDATE

- 의심할 코드: `JdbcTemplate`이나 `JdbcClient`로 `select ... for update`를 보내는 코드. 특히 `@Transactional`이 없는 메서드, 락을 잡은 뒤 외부 API 호출이나 긴 계산을 하는 코드, 여러 행을 순서 없이 잠그는 코드, `offset`과 함께 쓰는 코드.
- 실패 시나리오: 행 락은 트랜잭션이 끝날 때 풀린다. 트랜잭션 밖(autocommit)에서는 문장마다 암묵적 트랜잭션이 바로 커밋되므로 락이 조회 직후 풀려 뒤따르는 UPDATE를 보호하지 못한다. 락을 쥔 채 오래 걸리는 작업을 하면 같은 행을 쓰거나 잠그는 요청이 기본 설정에서 제한 없이 기다린다. 두 트랜잭션이 서로 다른 순서로 행을 잠그면 교착이 생겨 PostgreSQL이 한쪽을 중단시킨다. `OFFSET`으로 건너뛴 행도 잠긴다.
- 문제가 아닌 경우: 같은 `@Transactional` 안에서 잠그고 바로 갱신한 뒤 끝나는 짧은 흐름. 큐 테이블을 여러 소비자가 나눠 가지려는 `FOR UPDATE SKIP LOCKED`(일관되지 않은 결과를 의도한 사용). 기다리지 않으려는 `NOWAIT`.
- 고치는 방향: 잠금과 갱신을 한 트랜잭션에 넣고 외부 호출은 트랜잭션 밖으로 뺀다. 여러 행은 ID 순으로 정렬해 잠근다. 대기 상한이 필요하면 같은 트랜잭션에서 `SET LOCAL lock_timeout`을 먼저 실행한다.
- 출처: https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE, https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-ROWS, https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-DEADLOCKS, https://www.postgresql.org/docs/current/tutorial-transactions.html, https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-LOCK-TIMEOUT

## queryForObject의 0건 예외

- 의심할 코드: 결과가 없을 수 있는 조회(`where email = ?`, 조건 검색)를 `queryForObject`나 `JdbcClient`의 `.single()`로 받는 코드. `max`, `sum` 같은 집계 결과를 `queryForObject(..., Integer.class)`로 받아 `int`나 Kotlin non-null 타입에 넣는 코드.
- 실패 시나리오: `queryForObject`는 결과가 정확히 한 행이 아니면 예외다. 0행이면 `EmptyResultDataAccessException`, 2행 이상이면 `IncorrectResultSizeDataAccessException`이 나서 "없음"이 500 오류가 된다. 한 행이지만 값이 NULL이면 `queryForObject`는 `null`을 돌려주어 언박싱에서 NPE가 난다(PostgreSQL 집계는 `count`를 빼면 대상 행이 없을 때 NULL을 돌려준다). `JdbcClient`의 `single()`은 0행이면 `EmptyResultDataAccessException`이고, Spring Framework 6.2부터(Spring Boot 3.4 이상) NULL 값도 `TypeMismatchDataAccessException`으로 거부한다.
- 문제가 아닌 경우: `count(*)`처럼 항상 한 행이 나오는 조회. 없으면 예외가 맞는 흐름에서 `EmptyResultDataAccessException`을 잡아 404 같은 응답으로 바꾸는 코드.
- 고치는 방향: 없을 수 있으면 `JdbcClient`의 `.optional()`이나 `query(...)` 목록으로 받는다. 집계는 `coalesce(max(...), 0)`처럼 SQL에서 NULL을 막는다.
- 출처: https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/jdbc/core/JdbcOperations.html, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-tx/src/main/java/org/springframework/dao/support/DataAccessUtils.java, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-jdbc/src/main/java/org/springframework/jdbc/core/simple/JdbcClient.java, https://www.postgresql.org/docs/current/functions-aggregate.html

## 큰 결과 집합과 fetch size

- 의심할 코드: 대량 행을 읽는 `query`, `queryForList`, `queryForStream`, `JdbcClient`의 `.stream()`, `RowCallbackHandler`. `setFetchSize`, `spring.jdbc.template.fetch-size`, `JdbcClient`의 `withFetchSize`(Spring Framework 7.0 이상), PgJDBC `defaultRowFetchSize`의 유무와 트랜잭션 유무를 함께 본다.
- 실패 시나리오: PgJDBC는 기본으로 결과 전체를 한 번에 메모리로 가져온다. fetch size를 줘도 커넥션이 autocommit이면(Spring 트랜잭션 밖이면) 드라이버가 조용히 전체 가져오기로 돌아가므로, `queryForStream`이나 `RowCallbackHandler`로 한 행씩 처리하는 코드도 결과 크기만큼 메모리를 쓴다. `queryForList`처럼 `List`로 받으면 fetch size와 관계없이 전체가 메모리에 쌓인다. `queryForStream`과 `stream()`이 돌려준 `Stream`은 다 쓴 뒤 닫아야 한다.
- 문제가 아닌 경우: LIMIT이나 페이지로 결과 크기에 상한이 있는 조회. 트랜잭션 안에서 fetch size를 주고 `RowCallbackHandler`나 try-with-resources로 닫는 `Stream`으로 처리하는 경우(트랜잭션 매니저가 autocommit을 끄므로 커서로 나눠 가져온다).
- 고치는 방향: 대량 조회는 `@Transactional(readOnly = true)` 안에서 fetch size를 지정하고 행 단위로 처리한다. Spring Framework 7.0 미만에서 `JdbcClient`의 fetch size는 그 `JdbcClient`가 쓰는 `JdbcTemplate`에 설정한다. 또는 키셋 페이징으로 나눠 읽는다.
- 출처: https://jdbc.postgresql.org/documentation/query/#getting-results-based-on-a-cursor, https://jdbc.postgresql.org/documentation/use/, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/jdbc/core/JdbcOperations.html, https://docs.spring.io/spring-boot/appendix/application-properties/index.html#application-properties.data.spring.jdbc.template.fetch-size, https://docs.spring.io/spring-boot/reference/data/sql.html#data.sql.jdbc-client, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-jdbc/src/main/java/org/springframework/jdbc/core/simple/JdbcClient.java

## RowMapper 안에서 다시 보내는 쿼리

- 의심할 코드: `RowMapper`, `ResultSetExtractor`, `RowCallbackHandler` 람다 안에서 `jdbcTemplate.query`, `jdbcClient.sql(...)`, 다른 DAO나 리포지토리를 부르는 코드(주문 행마다 회원이나 주문 항목을 조회).
- 실패 시나리오: 바깥 결과 N행마다 안쪽 쿼리가 한 번씩 나가 N+1이 된다. 트랜잭션 밖이면 `DataSourceUtils`가 `DataSource.getConnection`과 같이 동작하므로, 바깥 쿼리가 커넥션을 쥔 채 안쪽 쿼리가 커넥션을 하나 더 얻는다. 동시 요청이 많으면 요청당 두 개씩 잡아 커넥션 풀이 먼저 마른다.
- 문제가 아닌 경우: 매퍼 안에서 미리 읽어 둔 `Map`만 조회하는 경우. 안쪽 호출이 캐시를 거치고 키 종류가 작게 고정된 경우.
- 고치는 방향: 조인 한 번으로 읽어 `ResultSetExtractor`로 묶거나, 바깥 결과의 키를 모아 `IN`이나 `= any(?)`로 한 번 더 조회한 뒤 메모리에서 붙인다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/jdbc/connections.html#jdbc-DataSourceUtils, https://docs.spring.io/spring-framework/reference/data-access/jdbc/connections.html#jdbc-DataSourceTransactionManager, https://docs.hibernate.org/orm/7.1/introduction/html_single/#association-fetching
