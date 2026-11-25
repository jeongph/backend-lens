# PostgreSQL 참조

적용 버전: PostgreSQL 12 이상. 버전에 따라 결론이 달라지는 부분(11, 12, 18, 19)은 항목 안에 따로 적었다.

## DDL 락과 락 대기열

- 의심할 코드: 운영 중인 테이블에 대한 `ALTER TABLE`, `DROP TABLE`, `TRUNCATE`, CONCURRENTLY 없는 `CREATE INDEX`나 `DROP INDEX`가 마이그레이션에 있고, 그 앞에 `SET LOCAL lock_timeout`이 없다.
- 실패 시나리오: `ALTER TABLE`은 따로 적힌 형태가 아니면 ACCESS EXCLUSIVE 락을 잡는데, 이 락은 SELECT가 잡는 ACCESS SHARE와도 충돌한다. 메타데이터만 바뀌는 짧은 DDL이라도 오래 도는 조회나 열린 트랜잭션 뒤에서 락을 기다리는 동안, 뒤에 온 SELECT와 쓰기가 대기열에서 그 DDL 뒤에 서서 함께 막힌다(`pg_blocking_pids` 문서의 soft block). `lock_timeout` 기본값은 0이라 데드락이 아니면 끝없이 기다리고, 그동안 그 테이블을 쓰는 요청이 모두 멈춘다.
- 문제가 아닌 경우: 같은 변경에서 새로 만든 테이블, 트래픽이 없는 테이블, 점검 시간에 돌리는 마이그레이션이다. ACCESS EXCLUSIVE가 아닌 락만 잡는 문장(`CREATE INDEX CONCURRENTLY`, `VALIDATE CONSTRAINT`, `ADD FOREIGN KEY`)은 기다리는 동안에도 SELECT를 막지 않는다. 다만 쓰기는 락 종류에 따라 막힐 수 있다.
- 고치는 방향: 트랜잭션 안에서 도는 마이그레이션 첫 줄에 `SET LOCAL lock_timeout = '5s'`처럼 짧은 제한을 두고, 실패하면 한가한 시간에 다시 시도한다. `SET`은 커밋 뒤 세션이 끝날 때까지 남아 같은 커넥션의 다른 작업에도 적용되므로 `SET LOCAL`을 쓴다.
- 출처: https://www.postgresql.org/docs/current/sql-altertable.html, https://www.postgresql.org/docs/current/explicit-locking.html, https://www.postgresql.org/docs/current/functions-info.html, https://www.postgresql.org/docs/current/runtime-config-client.html, https://www.postgresql.org/docs/current/sql-set.html

## ADD COLUMN 기본값과 재작성

- 의심할 코드: 기존 테이블에 `ALTER TABLE ... ADD COLUMN`을 하면서 `DEFAULT clock_timestamp()`나 `DEFAULT random()` 같은 휘발성(VOLATILE) 함수 기본값, `serial` 계열(`nextval` 기본값), `GENERATED ... STORED`, `GENERATED ... AS IDENTITY`, 제약이 있는 domain 타입을 쓴다.
- 실패 시나리오: 휘발성 기본값, stored generated 컬럼, identity 컬럼, 제약이 있는 domain 타입 컬럼을 더하면 테이블과 인덱스 전체를 다시 쓰고, 그동안 ACCESS EXCLUSIVE 락으로 읽기와 쓰기가 모두 막힌다. 큰 테이블이면 배포 중 장애가 된다. 재작성은 MVCC 안전하지 않아 재작성 전에 스냅샷을 잡은 동시 트랜잭션에는 테이블이 비어 보일 수 있다.
- 문제가 아닌 경우: 기본값 없는 nullable 컬럼, 상수 기본값, `now()`나 `CURRENT_TIMESTAMP`처럼 휘발성이 아닌(STABLE) 기본값이다. PostgreSQL 11부터는 이런 기본값을 메타데이터에 저장만 하므로 큰 테이블에서도 빠르다(기존 행은 ALTER 시점에 한 번 계산한 값을 갖는다). PostgreSQL 18 이상에서 `STORED` 없이 쓴 generated 컬럼은 virtual이 기본이라 재작성하지 않는다. 같은 변경에서 만든 빈 테이블이다. 함수가 휘발성인지는 `pg_proc.provolatile`로 확인한다.
- 고치는 방향: 컬럼은 기본값 없이 또는 상수 기본값으로 더하고, 값 채우기는 나눠서 배치 UPDATE로 한다. 휘발성 값이 필요하면 컬럼을 더한 뒤 `ALTER COLUMN ... SET DEFAULT`로 새 행에만 적용한다.
- 출처: https://www.postgresql.org/docs/current/sql-altertable.html, https://www.postgresql.org/docs/current/ddl-alter.html, https://www.postgresql.org/docs/current/xfunc-volatility.html, https://www.postgresql.org/docs/current/catalog-pg-proc.html, https://www.postgresql.org/docs/release/11.0/, https://www.postgresql.org/docs/release/18.0/

## NOT NULL 컬럼 추가

- 의심할 코드: `ALTER TABLE orders ADD COLUMN status varchar(20) NOT NULL;`처럼 기본값 없이 NOT NULL을 붙인 컬럼 추가.
- 실패 시나리오: 새 컬럼은 기존 행에서 NULL로 채워지므로 행이 하나라도 있으면 제약 위반으로 실패한다. 테스트나 로컬처럼 빈 데이터베이스에서는 통과해서 CI가 잡지 못하고, 데이터가 있는 운영 배포에서 처음 실패한다. 성공하더라도 롤링 배포 중 이 컬럼을 모르는 구버전 코드의 INSERT가 기본값이 없어 실패한다.
- 문제가 아닌 경우: 같은 변경에서 새로 만든 테이블이거나 비어 있음이 보장된 테이블이다. 휘발성이 아닌 `DEFAULT`를 함께 주면 기존 행과 구버전 INSERT가 그 값을 가지므로 성공하고, PostgreSQL 11 이상에서는 재작성도 없다.
- 고치는 방향: `NOT NULL DEFAULT '<값>'`으로 더하거나, nullable로 더해 값을 채운 뒤 "SET NOT NULL" 항목의 방법으로 제약을 건다.
- 출처: https://www.postgresql.org/docs/current/ddl-alter.html, https://www.postgresql.org/docs/current/sql-altertable.html

## 컬럼 타입 변경

- 의심할 코드: `ALTER TABLE ... ALTER COLUMN ... TYPE`(`SET DATA TYPE`). 특히 `integer`에서 `bigint`, `varchar(n)` 길이 줄이기, `text`에서 `varchar(n)`, 값을 바꾸는 `USING` 절.
- 실패 시나리오: 타입 변경은 보통 테이블과 인덱스 전체를 다시 쓰고, 끝날 때까지 ACCESS EXCLUSIVE 락으로 테이블을 막는다. `integer`에서 `bigint`처럼 내부 표현이 다른 타입으로 바꾸는 것이 이 경우다. 줄이는 변경은 기존 값이 맞지 않으면 실패한다.
- 문제가 아닌 경우: `USING`이 값을 바꾸지 않고 이전 타입이 새 타입으로 binary coercible이면 재작성하지 않는다. `varchar(n)` 길이 늘리기나 제한 없애기, `varchar`에서 `text`, `numeric` 정밀도 늘리기가 해당한다. PostgreSQL 12 이상에서는 세션 시간대가 UTC일 때 `timestamp`와 `timestamptz` 사이 변경도 재작성하지 않는다. JDBC 드라이버(pgjdbc)는 세션 시간대를 JVM 기본 시간대로 정하므로, DB 서버 설정이 UTC여도 JVM이 다른 시간대면 재작성한다. 마이그레이션 안에서 `SET LOCAL TIME ZONE 'UTC'`를 두지 않았다면 재작성으로 본다. 이때도 ACCESS EXCLUSIVE 락은 잠깐 잡으므로 "DDL 락과 락 대기열" 항목은 그대로 적용되고, 인덱스는 새 인덱스가 논리적으로 같다고 확인될 때만 다시 만들지 않는다.
- 고치는 방향: 재작성이 필요한 변경은 새 컬럼을 더하고 값을 나눠 옮긴 뒤 코드를 바꾸고 옛 컬럼을 지우는 순서로 여러 배포에 나눈다.
- 출처: https://www.postgresql.org/docs/current/sql-altertable.html, https://www.postgresql.org/docs/current/sql-createcast.html, https://www.postgresql.org/docs/release/9.2.0/, https://www.postgresql.org/docs/release/12.0/, https://www.postgresql.org/docs/current/sql-set.html, https://github.com/pgjdbc/pgjdbc/blob/master/pgjdbc/src/main/java/org/postgresql/core/v3/ConnectionFactoryImpl.java

## SET NOT NULL

- 의심할 코드: 기존 큰 테이블에 `ALTER TABLE ... ALTER COLUMN ... SET NOT NULL`.
- 실패 시나리오: 테이블 전체를 스캔해 NULL이 없는지 확인하고, 그동안 ACCESS EXCLUSIVE 락으로 읽기와 쓰기가 모두 막힌다. NULL이 남아 있으면 스캔 끝에 실패한다.
- 문제가 아닌 경우: PostgreSQL 12 이상에서 그 컬럼에 NULL이 없음을 증명하는 유효한 CHECK 제약(`CHECK (status IS NOT NULL)`이고 NOT VALID가 아니거나 이미 VALIDATE된 것)이 있으면 스캔을 건너뛴다. 같은 명령에서 그 CHECK를 지우면 건너뛰지 않는다. 작은 테이블이나 새 테이블이다. 아래 고치는 방향대로 단계를 여러 마이그레이션으로 나눴고, 마이그레이션 도구가 파일마다 트랜잭션을 따로 쓴다(Flyway는 `group=false`가 기본이고, `group=true`면 대기 중인 파일 전부가 한 트랜잭션이라 나눈 효과가 없다).
- 고치는 방향: `ADD CONSTRAINT orders_status_not_null CHECK (status IS NOT NULL) NOT VALID`, 다음 마이그레이션에서 `VALIDATE CONSTRAINT`, 그다음 `SET NOT NULL`, 마지막으로 필요 없어진 CHECK를 지운다. PostgreSQL 18 이상은 `ADD CONSTRAINT orders_status_not_null NOT NULL status NOT VALID`로 not-null 제약 자체를 NOT VALID로 더한 뒤 `VALIDATE CONSTRAINT`로 검증할 수 있다.
- 출처: https://www.postgresql.org/docs/current/sql-altertable.html, https://www.postgresql.org/docs/release/12.0/, https://www.postgresql.org/docs/release/18.0/, https://documentation.red-gate.com/flyway/reference/configuration/flyway-namespace/flyway-group-setting

## CHECK와 FK 제약 추가

- 의심할 코드: 기존 테이블에 NOT VALID 없이 `ADD CONSTRAINT ... CHECK (...)`나 `ADD CONSTRAINT ... FOREIGN KEY ... REFERENCES ...`를 추가한다. NOT VALID 추가와 `VALIDATE CONSTRAINT`가 같은 마이그레이션 파일(같은 트랜잭션)에 있다.
- 실패 시나리오: NOT VALID 없이 추가하면 기존 행을 모두 검사하는 동안 락을 쥔다. CHECK는 ACCESS EXCLUSIVE라 읽기까지, FK는 SHARE ROW EXCLUSIVE라 쓰기가 막힌다. 위반 행이 있으면 스캔 끝에 실패한다. 락은 트랜잭션 끝까지 유지되므로 NOT VALID 추가와 VALIDATE를 한 트랜잭션에 두면 처음 잡은 강한 락을 쥔 채 스캔하게 되어 나눈 효과가 없다.
- 문제가 아닌 경우: 새로 만든 테이블이나 작은 테이블이다. NOT VALID로 추가하고 VALIDATE는 다른 트랜잭션에서 한다. 파일을 나눈 것이 트랜잭션을 나눈 것이 되려면 마이그레이션 도구가 파일마다 트랜잭션을 따로 써야 한다(Flyway는 `group=false`가 기본이고, `group=true`면 대기 중인 파일 전부가 한 트랜잭션이다).
- 고치는 방향: `ADD CONSTRAINT ... NOT VALID`(스캔 없이 바로 커밋되고 이후 들어오는 행에는 바로 적용된다)와 `VALIDATE CONSTRAINT`(SHARE UPDATE EXCLUSIVE, FK면 참조 테이블에 ROW SHARE만 잡아 쓰기를 막지 않는다)를 별도 마이그레이션으로 나눈다.
- 출처: https://www.postgresql.org/docs/current/sql-altertable.html, https://www.postgresql.org/docs/current/explicit-locking.html, https://documentation.red-gate.com/flyway/reference/configuration/flyway-namespace/flyway-group-setting

## FK 추가와 참조 테이블 락

- 의심할 코드: `ALTER TABLE order_items ADD CONSTRAINT order_items_order_fk FOREIGN KEY (order_id) REFERENCES orders (id)`처럼 자주 쓰는 테이블을 참조하는 FK 추가. 참조하는 컬럼(`order_items.order_id`)에 인덱스가 없다.
- 실패 시나리오: `ADD FOREIGN KEY`는 제약을 거는 테이블뿐 아니라 참조되는 테이블에도 SHARE ROW EXCLUSIVE 락을 잡는다. 이 락은 INSERT, UPDATE, DELETE가 잡는 ROW EXCLUSIVE와 충돌하므로, 검증 스캔 동안과 락을 기다리는 동안 참조되는 테이블(orders)의 쓰기까지 막힌다. 자식 테이블이 작아도 참조되는 쪽이 핵심 테이블이면 영향이 크다. 참조하는 컬럼에 인덱스가 없으면 참조되는 행을 지우거나 키를 바꿀 때마다 참조하는 테이블을 스캔한다.
- 문제가 아닌 경우: 두 테이블 모두 같은 변경에서 새로 만들었다. NOT VALID로 추가해 스캔이 없고 VALIDATE를 다른 트랜잭션에서 따로 한다(Flyway `group=true`면 파일을 나눠도 대기 중인 파일 전부가 한 트랜잭션이라 해당하지 않는다).
- 고치는 방향: NOT VALID로 추가하고 `lock_timeout`을 함께 두며, VALIDATE는 다음 마이그레이션에서 한다. 참조하는 컬럼 인덱스는 PostgreSQL이 자동으로 만들지 않으므로 필요하면 CONCURRENTLY로 따로 만든다.
- 출처: https://www.postgresql.org/docs/current/sql-altertable.html, https://www.postgresql.org/docs/current/explicit-locking.html, https://www.postgresql.org/docs/current/ddl-constraints.html, https://documentation.red-gate.com/flyway/reference/configuration/flyway-namespace/flyway-group-setting

## 인덱스 생성

- 의심할 코드: 기존 테이블에 CONCURRENTLY 없는 `CREATE INDEX`. 트랜잭션 블록 안(마이그레이션 도구의 기본 트랜잭션, `BEGIN`, 다른 문장과 같은 파일)의 `CREATE INDEX CONCURRENTLY`. `CREATE INDEX CONCURRENTLY IF NOT EXISTS`. 분할 테이블(partitioned table)에 대한 CONCURRENTLY.
- 실패 시나리오: 일반 `CREATE INDEX`는 SHARE 락으로 끝날 때까지 쓰기를 막는다(읽기는 된다). CONCURRENTLY는 쓰기를 막지 않지만 트랜잭션 블록 안에서는 실행되지 않고, 테이블을 두 번 스캔하며 그 사이 기존 트랜잭션이 끝나기를 기다린다. 도중에 데드락이나 유니크 위반으로 실패하면 INVALID 인덱스가 남아 조회에는 쓰이지 않으면서 쓰기 비용은 계속 들고, UNIQUE면 유니크 검사도 계속한다. `IF NOT EXISTS`는 같은 이름의 INVALID 인덱스가 있어도 알림만 내고 넘어가므로 재시도가 아무 일도 하지 않는다. 분할 테이블에는 CONCURRENTLY로 인덱스를 만들 수 없다.
- 문제가 아닌 경우: 같은 변경에서 만든 빈 테이블이나 작은 테이블에 일반 `CREATE INDEX`를 쓴다.
- 고치는 방향: 운영 테이블에는 `CREATE INDEX CONCURRENTLY`를 파일 하나에 단독으로 둔다(Flyway 쪽 설정은 flyway.md 참조). 실패하면 INVALID 인덱스를 `DROP INDEX CONCURRENTLY`로 지우고 다시 만들거나 `REINDEX INDEX CONCURRENTLY`로 다시 만든다. 분할 테이블은 파티션마다 CONCURRENTLY로 만든 뒤 부모 인덱스를 일반 방식으로 만든다(이때 부모 인덱스 생성은 메타데이터 작업이다).
- 출처: https://www.postgresql.org/docs/current/sql-createindex.html, https://www.postgresql.org/docs/current/explicit-locking.html, https://www.postgresql.org/docs/current/sql-reindex.html

## 인덱스 삭제

- 의심할 코드: 운영 테이블에 CONCURRENTLY 없는 `DROP INDEX`. `DROP INDEX CONCURRENTLY`에 이름 여러 개나 CASCADE를 쓰거나 트랜잭션 블록 안에 둔다.
- 실패 시나리오: 일반 `DROP INDEX`는 테이블에 ACCESS EXCLUSIVE 락을 잡아 락 대기열 때문에 조회까지 막을 수 있다. CONCURRENTLY는 트랜잭션 블록 안에서 실패하고, 이름 하나만 받으며 CASCADE를 지원하지 않아 UNIQUE나 PRIMARY KEY 제약을 받치는 인덱스는 이 방법으로 지울 수 없다. 분할 테이블의 인덱스에도 쓸 수 없다. 그 인덱스를 쓰던 쿼리는 삭제 뒤 느려진다.
- 문제가 아닌 경우: 새 테이블, 작은 테이블, 트래픽이 없는 테이블이다.
- 고치는 방향: `DROP INDEX CONCURRENTLY`를 파일 하나에 단독으로 둔다. 제약이 받치는 인덱스는 `ALTER TABLE ... DROP CONSTRAINT`로 지우되 `lock_timeout`을 둔다.
- 출처: https://www.postgresql.org/docs/current/sql-dropindex.html

## UNIQUE 제약 붙이기

- 의심할 코드: 기존 테이블에 `ALTER TABLE ... ADD CONSTRAINT ... UNIQUE (col)`이나 `ADD PRIMARY KEY`를 바로 추가한다.
- 실패 시나리오: 이 형태는 ACCESS EXCLUSIVE 락을 잡은 채 유니크 인덱스를 일반 방식으로 만들므로, 인덱스를 다 만들 때까지 읽기와 쓰기가 모두 막힌다. 중복 값이 있으면 끝에 실패한다.
- 문제가 아닌 경우: 새 테이블이나 작은 테이블이다. `ON CONFLICT (col)`의 대상 추론과 FK 참조는 부분 인덱스가 아닌 유니크 인덱스만으로도 되므로, `ON CONFLICT ON CONSTRAINT <이름>`처럼 제약이 꼭 필요한 경우가 아니면 CONCURRENTLY로 만든 유니크 인덱스만으로 충분하다.
- 고치는 방향: `CREATE UNIQUE INDEX CONCURRENTLY orders_order_number_key ON orders (order_number)`를 만든 뒤 별도 마이그레이션에서 `ALTER TABLE orders ADD CONSTRAINT orders_order_number_key UNIQUE USING INDEX orders_order_number_key`로 붙인다. 이 단계는 빠르지만 ACCESS EXCLUSIVE 락을 잠깐 잡는다. 인덱스는 표현식이나 부분 인덱스가 아닌 기본 정렬의 B-tree여야 하고, 분할 테이블에는 쓸 수 없다. PRIMARY KEY로 붙일 때 컬럼이 아직 NOT NULL이 아니면 전체 스캔이 생긴다.
- 출처: https://www.postgresql.org/docs/current/sql-altertable.html, https://www.postgresql.org/docs/current/sql-createindex.html, https://www.postgresql.org/docs/current/sql-insert.html, https://www.postgresql.org/docs/current/ddl-constraints.html

## 이름 변경과 삭제

- 의심할 코드: `ALTER TABLE ... RENAME COLUMN`, `ALTER TABLE ... RENAME TO`, `DROP COLUMN`, `DROP TABLE`이 그 이름을 쓰는 코드 변경과 같은 배포에 들어 있다. 엔티티 필드나 `@Column(name = ...)`, `@Table(name = ...)` 변경과 마이그레이션이 한 변경에 있다.
- 실패 시나리오: 이름 변경과 컬럼 삭제는 저장된 데이터를 건드리지 않아 빠르지만 ACCESS EXCLUSIVE 락을 잡고, 커밋 순간 옛 이름이 사라진다. 롤링 배포 중 구버전 인스턴스의 SQL(ORM이 매핑으로 만든 SELECT와 INSERT 포함)이 없는 컬럼이나 테이블을 가리켜 실패한다. 배포를 되돌려도 이름은 돌아오지 않는다. 뷰가 그 컬럼을 쓰거나 다른 테이블의 FK가 그 컬럼을 참조하면 `DROP COLUMN`은 CASCADE 없이 실패하고, CASCADE를 쓰면 그 뷰나 FK 제약도 함께 사라진다. 그 테이블에 선언된 인덱스와 제약(지우는 컬럼으로 다른 테이블을 참조하는 FK 포함)은 CASCADE 없이도 자동으로 함께 지워진다.
- 문제가 아닌 경우: 앞선 배포에서 코드 참조를 이미 없애서 운영 중인 어떤 버전도 그 이름을 쓰지 않는다. 같은 변경에서 만든 객체다. 배포 중 중단을 허용한다.
- 고치는 방향: expand-contract로 나눈다. 새 컬럼 추가와 양쪽 쓰기, 데이터 이관, 읽기 전환, 옛 컬럼 삭제를 서로 다른 배포로 두고, 삭제는 모든 인스턴스에서 참조가 사라진 다음 배포에서 한다.
- 출처: https://www.postgresql.org/docs/current/sql-altertable.html, https://www.postgresql.org/docs/current/ddl-alter.html

## enum 타입 값 추가

- 의심할 코드: `ALTER TYPE order_status ADD VALUE 'CANCELLED'`와 그 값을 쓰는 `UPDATE`, `INSERT`, `DEFAULT`, `CHECK`가 같은 마이그레이션 파일에 있다. enum 값 삭제나 순서 변경을 시도한다.
- 실패 시나리오: PostgreSQL 12 이상은 트랜잭션 블록 안에서 `ADD VALUE`를 실행할 수 있지만 새 값은 그 트랜잭션이 커밋될 때까지 쓸 수 없다. 마이그레이션 파일 하나가 트랜잭션 하나로 돌면 같은 파일에서 새 값을 쓰는 문장이 실패한다. PostgreSQL 11 이하에서는 `ADD VALUE`를 트랜잭션 블록 안에서 아예 실행할 수 없다. 기존 enum 값은 지울 수 없고 순서도 바꿀 수 없어서 타입을 다시 만들어야 한다.
- 문제가 아닌 경우: `ADD VALUE`만 있는 파일이고 새 값은 다음 마이그레이션이나 애플리케이션 코드에서 처음 쓴다. 이는 다음 마이그레이션이 다른 트랜잭션에서 돈다는 전제다. Flyway `group=true`면 대기 중인 파일 전부가 한 트랜잭션이라 다음 파일에서 새 값을 써도 실패한다.
- 고치는 방향: 값 추가와 값 사용을 다른 마이그레이션으로 나누고, 재실행에 대비해 `ADD VALUE IF NOT EXISTS`를 쓴다. 값을 자주 바꾸거나 지워야 하는 상태라면 enum 타입 대신 `varchar`와 CHECK 제약 또는 참조 테이블을 쓴다.
- 출처: https://www.postgresql.org/docs/current/sql-altertype.html, https://www.postgresql.org/docs/current/datatype-enum.html, https://www.postgresql.org/docs/11/sql-altertype.html, https://www.postgresql.org/docs/release/12.0/, https://documentation.red-gate.com/flyway/reference/configuration/flyway-namespace/flyway-group-setting

## 조회 후 갱신의 갱신 손실

- 의심할 코드: 한 트랜잭션에서 `SELECT`로 읽은 값(재고, 잔액, 카운터, 상태)을 애플리케이션에서 계산해 `UPDATE products SET stock = :newStock WHERE id = :id`처럼 계산된 값으로 쓴다. `FOR UPDATE`, 버전 컬럼 조건, 현재 값을 쓰는 원자적 UPDATE가 없다. 상태를 읽고 확인한 뒤 전이시키는 코드도 같다.
- 실패 시나리오: 기본 격리 수준 READ COMMITTED에서 일반 SELECT는 행을 잠그지 않으므로, 동시 요청 둘이 같은 값을 읽고 각자 계산해 쓰면 나중 쓰기가 앞 쓰기를 덮는다(재고가 한 번만 줄거나 같은 상태 전이가 두 번 처리된다). 두 번째 UPDATE는 앞 트랜잭션을 기다린 뒤 갱신된 행에 적용되지만, SET 값이 이미 계산된 상수라 손실을 막지 못한다.
- 문제가 아닌 경우: `UPDATE products SET stock = stock - 1 WHERE id = ? AND stock >= 1`처럼 한 문장 안에서 현재 값으로 계산하고 조건을 거는 원자적 UPDATE와 갱신 행 수 확인이다(READ COMMITTED는 갱신된 행 버전으로 WHERE를 다시 평가한다). 읽을 때 `FOR UPDATE`로 잠그거나 버전 컬럼을 WHERE에 넣고 갱신 행 수를 확인하는 낙관적 잠금이 있다. 동시에 같은 행을 쓰는 요청이 생길 수 없는 데이터다. REPEATABLE READ 이상에서 돌고 40001을 받으면 트랜잭션 전체를 재시도한다(REPEATABLE READ는 읽은 뒤 다른 트랜잭션이 바꾸고 커밋한 행을 UPDATE하면 40001로 중단하므로 앞 쓰기를 덮지 않는다. "직렬화 실패와 재시도" 항목 참조).
- 고치는 방향: 원자적 UPDATE로 바꾸고 영향 행 수로 성공을 판단하거나, 조회에 `FOR UPDATE`를 붙이거나, 버전 조건을 쓴다.
- 출처: https://www.postgresql.org/docs/current/transaction-iso.html, https://www.postgresql.org/docs/current/explicit-locking.html, https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html

## FOR UPDATE와 FOR NO KEY UPDATE

- 의심할 코드: `SELECT ... FOR UPDATE` 뒤에 외부 API 호출이나 긴 처리가 같은 트랜잭션에 있다. 조인 쿼리에 `OF <테이블>` 없는 `FOR UPDATE`, `OFFSET`과 함께 쓴 `FOR UPDATE`, 트랜잭션 없이(자동 커밋으로) 실행하는 `FOR UPDATE`.
- 실패 시나리오: 행 잠금은 트랜잭션 끝까지 유지되고 데드락이 아니면 기다림에 제한이 없어서, 잠근 뒤 느린 일을 하면 같은 행을 쓰는 요청이 모두 줄을 선다. 조인에 `OF` 없이 쓰면 결과에 기여한 모든 테이블의 행이 잠긴다. OFFSET으로 건너뛴 행도 잠긴다. 자동 커밋에서는 문장마다 트랜잭션이 끝나 잠금이 바로 풀리므로 보호가 없다. `FOR UPDATE`는 `FOR KEY SHARE`까지 막지만, 키 컬럼을 바꾸지 않는 갱신이면 `FOR NO KEY UPDATE`로 충분하고 이 잠금은 `FOR KEY SHARE`를 막지 않는다.
- 문제가 아닌 경우: 짧은 트랜잭션 안에서 PK 조건으로 한두 행만 잠그고 바로 갱신한 뒤 커밋한다.
- 고치는 방향: 잠금 범위를 PK 조건과 `OF <테이블>`로 좁히고, 잠근 뒤의 외부 호출은 트랜잭션 밖으로 뺀다. 키를 바꾸지 않으면 `FOR NO KEY UPDATE`를 쓴다. 기다림에는 `lock_timeout`이나 `NOWAIT`로 상한을 둔다.
- 출처: https://www.postgresql.org/docs/current/explicit-locking.html, https://www.postgresql.org/docs/current/sql-select.html, https://www.postgresql.org/docs/current/tutorial-transactions.html

## SKIP LOCKED와 NOWAIT

- 의심할 코드: 작업 큐 테이블에서 여러 워커가 `SELECT ... ORDER BY id LIMIT 10 FOR UPDATE`로 작업을 가져간다. 합계, 존재 확인, 재고 판단 같은 일반 조회에 `SKIP LOCKED`를 쓴다. `NOWAIT`를 쓰는데 잠금 실패 오류 처리가 없다.
- 실패 시나리오: SKIP LOCKED 없이 여러 워커가 같은 조건으로 가져가면 첫 워커가 커밋할 때까지 나머지가 같은 행에서 기다린다. 반대로 SKIP LOCKED를 일반 조회에 쓰면 잠긴 행이 빠진 일관되지 않은 결과로 판단하게 된다. NOWAIT는 행을 바로 잠그지 못하면 오류(SQLSTATE 55P03)를 내므로 처리가 없으면 동시 요청이 그대로 실패한다. 두 옵션 모두 행 잠금에만 적용되고 테이블 수준 ROW SHARE 락은 평소처럼 기다린다.
- 문제가 아닌 경우: 어느 행을 가져가도 되는 큐 소비자에 SKIP LOCKED를 쓴다. 잠금 실패를 잡아 "처리 중" 응답이나 재시도로 바꾸는 코드와 함께 NOWAIT를 쓴다.
- 고치는 방향: SKIP LOCKED는 큐 소비 같은 경우에만 쓰고, NOWAIT에는 55P03 처리를 둔다.
- 출처: https://www.postgresql.org/docs/current/sql-select.html, https://www.postgresql.org/docs/current/errcodes-appendix.html

## 데드락과 잠금 순서

- 의심할 코드: 한 트랜잭션에서 여러 행이나 여러 테이블을 갱신하거나 잠그는데 순서가 입력에 따라 달라진다. 예를 들어 이체에서 보내는 계좌를 먼저 잠그거나, 정렬하지 않은 id 목록을 차례로 UPDATE한다. 처음에 약한 락을 잡고 나중에 같은 객체에 더 강한 락을 잡는다.
- 실패 시나리오: 트랜잭션 A가 1번 다음 2번을, B가 2번 다음 1번을 잠그면 서로를 기다리는 데드락이 된다. PostgreSQL은 `deadlock_timeout`(기본 1초)만큼 기다린 뒤 검사해 한쪽을 SQLSTATE 40P01로 중단시키므로, 그동안 두 요청이 멈추고 한쪽은 실패한다. 재시도가 없으면 사용자 오류가 된다.
- 문제가 아닌 경우: 한 트랜잭션이 행 하나만 잠근다. 여러 행을 모든 코드 경로에서 같은 기준(예: id 오름차순)으로 잠근다.
- 고치는 방향: 잠글 대상을 정렬해 모든 코드 경로가 같은 순서로 잠그게 하고, 처음부터 필요한 가장 강한 락을 잡는다. 그래도 남는 경우에 대비해 40P01을 트랜잭션 전체 재시도로 처리한다. `deadlock_timeout`을 줄이는 것은 감지를 앞당길 뿐 해결이 아니다.
- 출처: https://www.postgresql.org/docs/current/explicit-locking.html, https://www.postgresql.org/docs/current/runtime-config-locks.html, https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html

## 중복 생성과 ON CONFLICT

- 의심할 코드: 있는지 조회한 뒤 없으면 INSERT하는 코드(`exists` 확인 후 저장), 멱등 키나 외부 요청 ID를 받는 생성 API, 재시도되는 메시지 소비자에 유니크 제약이 없다. 유니크 인덱스나 제약이 없는 컬럼을 `ON CONFLICT (col)`의 대상으로 쓴다. `ON CONFLICT DO NOTHING ... RETURNING` 결과가 항상 한 행이라고 가정한다.
- 실패 시나리오: 유니크 제약이 없으면 동시 요청 둘이 모두 "없음"을 보고 둘 다 INSERT해 중복 행이 생긴다. 재시도나 메시지 재전달도 같은 행을 또 만든다. `ON CONFLICT`의 판정 대상(arbiter)은 유니크 인덱스나 NOT DEFERRABLE 제약만 될 수 있다. `RETURNING`은 실제로 넣은(또는 갱신한) 행만 돌려주므로 `DO NOTHING`에서 충돌하면 빈 결과가 오고, 이를 처리하지 않으면 잘못된 응답이 된다.
- 문제가 아닌 경우: 업무 키에 유니크 제약이 있고, 유니크 위반(SQLSTATE 23505)을 잡은 뒤 새 트랜잭션에서, 또는 savepoint로 되돌린 뒤 기존 행을 조회해 돌려준다. 오류가 난 트랜잭션은 aborted 상태라 같은 트랜잭션에서 이어 하는 조회는 SQLSTATE 25P02로 거부된다. `ON CONFLICT ... DO UPDATE`를 쓴다(동시성이 높아도 INSERT나 UPDATE 중 하나를 보장한다).
- 고치는 방향: 업무 키나 멱등 키에 유니크 제약을 두고 `INSERT ... ON CONFLICT (idempotency_key) DO NOTHING`이나 `DO UPDATE`로 한 문장에서 처리한다. 기존 행이 필요하면 충돌 시 다시 조회한다. PostgreSQL 19 이상은 `ON CONFLICT (...) DO SELECT ... RETURNING`으로 충돌한 기존 행을 바로 돌려받을 수 있다.
- 출처: https://www.postgresql.org/docs/current/sql-insert.html, https://www.postgresql.org/docs/current/transaction-iso.html, https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html, https://www.postgresql.org/docs/release/19.0/, https://www.postgresql.org/docs/current/tutorial-transactions.html, https://www.postgresql.org/docs/current/errcodes-appendix.html

## advisory lock

- 의심할 코드: `pg_advisory_lock`, `pg_try_advisory_lock`, `pg_advisory_xact_lock`, `pg_try_advisory_xact_lock` 호출. 커넥션 풀을 쓰는 앱에서 세션 단위 함수를 쓰거나, 트랜잭션이 없는 곳(자동 커밋)에서 `_xact_` 함수를 쓰거나, `pg_try_*`의 boolean 결과를 확인하지 않거나, `pg_advisory_unlock`이 finally에 없다.
- 실패 시나리오: 세션 단위 락은 명시적으로 풀거나 세션이 끝날 때까지 유지되고 트랜잭션 롤백과도 무관하다. 커넥션 풀에서는 세션이 끝나지 않으므로 예외로 unlock을 건너뛰면 락이 풀에 돌아간 커넥션에 남아 다른 요청이 계속 잡지 못한다. 같은 세션은 같은 락을 여러 번 잡을 수 있어서, 그 커넥션을 다시 빌린 다른 요청은 잠금을 그대로 통과한다. lock과 unlock이 다른 커넥션에서 실행되면 unlock은 false와 경고만 내고 락은 남는다. 트랜잭션 단위 락은 트랜잭션 끝에 풀리므로 자동 커밋에서 부르면 그 문장이 끝나자마자 풀려 보호가 없다.
- 문제가 아닌 경우: 트랜잭션(예: `@Transactional` 메서드) 안에서 `pg_advisory_xact_lock`을 부르고 보호할 작업을 같은 트랜잭션에서 한다. 세션 단위 락을 쓰되 같은 커넥션을 직접 잡고 쓰며 finally에서 unlock한다.
- 고치는 방향: 커넥션 풀 환경에서는 트랜잭션 단위 함수를 기본으로 쓰고, `pg_try_*`는 false일 때의 처리를 둔다.
- 출처: https://www.postgresql.org/docs/current/explicit-locking.html, https://www.postgresql.org/docs/current/functions-admin.html, https://www.postgresql.org/docs/current/tutorial-transactions.html

## 직렬화 실패와 재시도

- 의심할 코드: `REPEATABLE READ`나 `SERIALIZABLE`을 지정했는데(`SET TRANSACTION ISOLATION LEVEL`, `@Transactional(isolation = ...)`) 재시도 처리가 없다. 재시도가 트랜잭션 전체가 아니라 마지막 UPDATE만 다시 실행한다.
- 실패 시나리오: 두 수준 모두 동시 갱신과 충돌하면 "could not serialize access" 오류(SQLSTATE 40001)로 트랜잭션을 중단한다. REPEATABLE READ에서는 트랜잭션 시작 뒤 다른 트랜잭션이 바꾼 행을 UPDATE, DELETE, `FOR UPDATE`하면 이 오류가 난다. SERIALIZABLE은 읽기와 쓰기 의존만으로도 실패할 수 있고, 실패한 트랜잭션에서 읽은 값은 믿을 수 없다. PostgreSQL은 자동 재시도를 하지 않으므로 재시도가 없으면 경쟁이 있을 때마다 사용자 오류가 된다.
- 문제가 아닌 경우: 40001(필요하면 40P01도)을 받으면 결정 로직까지 포함한 트랜잭션 전체를 처음부터 다시 실행하는 재시도가 있다. 실패해도 사용자가 다시 요청하면 되는 읽기 전용 작업이다.
- 고치는 방향: 트랜잭션 경계 바깥에서 전체를 다시 실행하는 재시도를 두고, 여러 번 실패할 수 있으니 횟수 상한을 둔다.
- 출처: https://www.postgresql.org/docs/current/transaction-iso.html, https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html, https://www.postgresql.org/docs/current/explicit-locking.html

## 깊은 OFFSET 페이징

- 의심할 코드: 사용자가 고르는 페이지 번호를 그대로 `LIMIT ? OFFSET ?`에 쓰는 목록 API, OFFSET을 늘려 가며 큰 테이블 전체를 훑는 배치, `ORDER BY`가 없거나 유일하지 않은 정렬에 쓰는 LIMIT과 OFFSET.
- 실패 시나리오: OFFSET으로 건너뛰는 행도 서버가 모두 계산하므로 뒤 페이지일수록 느려지고, OFFSET을 늘려 가며 훑는 배치는 뒤로 갈수록 한 번의 조회 비용이 커진다. 정렬이 정해지지 않으면 LIMIT과 OFFSET 값에 따라 계획이 달라져 페이지 사이에 행이 겹치거나 빠진다. 페이지를 넘기는 사이 행이 추가되거나 지워져도 겹치거나 빠진다.
- 문제가 아닌 경우: 행 수가 작거나 페이지 수에 상한이 있어 OFFSET이 작게 유지된다(관리 화면의 앞쪽 몇 페이지 등).
- 고치는 방향: 마지막으로 읽은 정렬 키로 이어 읽는 keyset 방식(`WHERE (created_at, id) < (?, ?) ORDER BY created_at DESC, id DESC LIMIT ?`)과 같은 순서의 인덱스를 쓰고, 정렬 끝에 유일한 컬럼을 넣는다.
- 출처: https://www.postgresql.org/docs/current/queries-limit.html, https://www.postgresql.org/docs/current/sql-select.html

## 인덱스를 못 타는 조건

- 의심할 코드: 인덱스 컬럼에 함수나 연산을 씌운 조건(`WHERE lower(email) = ?`, `WHERE date(created_at) = ?`), 앞에 `%`가 붙은 `LIKE '%keyword'`나 `LIKE '%keyword%'`, 복합 인덱스 `(member_id, created_at)`만 있는데 `created_at`만으로 거는 조건.
- 실패 시나리오: 같은 표현식으로 만든 인덱스가 없으면 표현식 조건에는 컬럼 인덱스가 쓰이지 않는다. B-tree는 앞이 고정된 상수 패턴(`LIKE 'abc%'`)에만 쓸 수 있고 `'%abc'`에는 못 쓰며, C 로캘이 아닌 데이터베이스에서는 앞이 고정된 패턴에도 `text_pattern_ops` 같은 연산자 클래스 인덱스가 필요하다. 복합 B-tree 인덱스는 선두 컬럼에 조건이 있을 때 가장 효율적이고, 선두 컬럼 조건이 없으면 인덱스 전체를 읽거나 순차 스캔이 된다. 큰 테이블이면 전체 스캔으로 응답 시간과 부하가 커진다.
- 문제가 아닌 경우: 같은 표현식의 인덱스가 있다(`CREATE INDEX ... ON members (lower(email))`). `pg_trgm`의 GIN이나 GiST 인덱스가 있으면 `%`로 시작하는 LIKE와 ILIKE도 인덱스를 쓸 수 있다(검색어가 짧아 추출할 trigram이 없으면 인덱스 전체를 훑으므로 효과가 없다). PostgreSQL 18 이상은 선두 컬럼의 서로 다른 값이 적을 때 skip scan으로 복합 인덱스를 쓸 수 있다(값이 많으면 여전히 순차 스캔을 고른다). 디스크 페이지 한두 개에 다 들어가는 작은 테이블은 순차 스캔을 이길 계획이 없다.
- 고치는 방향: 조건을 컬럼 그대로 비교하는 형태로 바꾸거나(`created_at >= ? AND created_at < ?`) 같은 표현식의 인덱스를 만든다. 인덱스 표현식에는 IMMUTABLE 함수만 쓸 수 있어서, timestamptz 컬럼의 `date(created_at)`처럼 시간대에 따라 결과가 달라지는(STABLE) 표현식은 인덱스로 만들 수 없으므로 범위 비교로 바꾼다. 선두 컬럼 없이 자주 쓰는 조건이면 그 컬럼으로 시작하는 인덱스를 따로 둔다. 실제 데이터 규모에서 `EXPLAIN`으로 계획을 확인한다.
- 출처: https://www.postgresql.org/docs/current/indexes-expressional.html, https://www.postgresql.org/docs/current/indexes-types.html, https://www.postgresql.org/docs/current/indexes-opclass.html, https://www.postgresql.org/docs/current/indexes-multicolumn.html, https://www.postgresql.org/docs/current/indexes-examine.html, https://www.postgresql.org/docs/current/pgtrgm.html, https://www.postgresql.org/docs/release/18.0/, https://www.postgresql.org/docs/current/sql-createindex.html
