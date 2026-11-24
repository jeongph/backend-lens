# Spring 트랜잭션 참조

적용 버전: Spring Boot 3.x와 4.x(Spring Framework 6.x, 7.x). 항목 안에 버전을 적은 동작은 그 버전부터 달라진다.

## 같은 클래스 안 자기 호출

- 의심할 코드: 같은 클래스의 다른 메서드를 `this.`나 이름만으로 부르는데, 불리는 메서드에만 `@Transactional`이나 다른 설정(`REQUIRES_NEW`, `readOnly`, `rollbackFor`)이 붙어 있다. 예: `OrderService.placeOrder()`가 같은 클래스의 `@Transactional(propagation = Propagation.REQUIRES_NEW) saveHistory()`를 부른다. `@PostConstruct`에서 자기 트랜잭션 메서드를 부르는 것도 같다.
- 실패 시나리오: 프록시 모드(기본값)는 프록시를 거쳐 들어온 외부 호출만 가로챈다. 자기 호출에서는 어노테이션이 무시되어, 바깥에 트랜잭션이 없으면 트랜잭션 없이 실행되고 있으면 바깥 설정을 그대로 따른다. 따로 커밋되길 기대한 기록이 바깥 롤백과 함께 사라지거나, 롤백을 기대한 작업이 커밋된다.
- 문제가 아닌 경우: 호출하는 메서드에 같은 설정의 트랜잭션이 이미 있어 안쪽 어노테이션이 무시되어도 결과가 같은 경우. AspectJ 모드(`mode = AdviceMode.ASPECTJ`와 위빙 설정)를 쓰는 경우. 자기 자신을 주입받은 참조로 부르는 경우.
- 고치는 방향: 트랜잭션 경계가 다른 메서드를 별도 빈으로 옮겨 주입받아 부른다. `AopContext.currentProxy()`는 공식 문서도 권하지 않는다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html, https://docs.spring.io/spring-framework/reference/core/aop/proxying.html

## private, final 메서드와 final 클래스

- 의심할 코드: `@Transactional`이 `private` 메서드, `final` 메서드, `final` 클래스에 붙어 있다. JDK 프록시 설정(`spring.aop.proxy-target-class=false`)에서 인터페이스에 없는 메서드에 붙어 있다. Kotlin 클래스라면 kotlin.md의 kotlin-spring 항목을 함께 본다.
- 실패 시나리오: CGLIB 프록시는 오버라이드할 수 없는 `private`과 `final` 메서드를 가로채지 못해 트랜잭션 없이 실행된다. `final` 메서드는 프록시 인스턴스에서 그대로 실행되므로 초기화되지 않은 필드 때문에 NullPointerException이 날 수 있다고 Spring이 로그로 경고한다. `final` 클래스는 프록시를 만들 수 없어 기동이 실패한다.
- 문제가 아닌 경우: Spring Framework 6.0부터 클래스 기반 프록시에서는 `protected`와 패키지 가시성 메서드에도 기본으로 트랜잭션이 걸린다(5.3까지는 `public`만). Spring Boot는 `spring.aop.proxy-target-class` 기본값이 `true`라 CGLIB 프록시를 쓴다. AspectJ 위빙은 가시성과 무관하다.
- 고치는 방향: 트랜잭션 메서드를 다른 빈에서 부르는 `public`(6.0 이상이면 `protected`도 가능) 비`final` 메서드로 만든다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html, https://docs.spring.io/spring-framework/reference/core/aop/proxying.html, https://github.com/spring-projects/spring-framework/blob/main/spring-aop/src/main/java/org/springframework/aop/framework/CglibAopProxy.java, https://github.com/spring-projects/spring-boot/blob/main/module/spring-boot-transaction/src/main/java/org/springframework/boot/transaction/autoconfigure/TransactionAutoConfiguration.java

## readOnly 트랜잭션 안에서 일어나는 쓰기

- 의심할 코드: 클래스나 바깥 메서드에 `@Transactional(readOnly = true)`가 있고, 그 안에서 엔티티 필드를 바꾸거나 `save()`를 부르거나 기본 전파(REQUIRED)인 쓰기 메서드를 부른다.
- 실패 시나리오: JPA에서 readOnly 트랜잭션은 Hibernate 세션의 flush 모드를 MANUAL로 바꾸고(트랜잭션마다 새로 연 EntityManager면 세션을 기본 읽기 전용으로도 만든다), 기본 설정에서는 JDBC 커넥션에 `Connection.setReadOnly(true)`를 건다. 안쪽 REQUIRED 메서드는 바깥 readOnly 트랜잭션에 참여하고 자기 readOnly 설정은 무시되므로, 변경 감지로 바뀐 값이 flush되지 않아 조용히 사라지거나 드라이버와 DB가 쓰기를 거부해 예외가 난다. 어느 쪽인지는 드라이버와 DB에 따라 다르다.
- 문제가 아닌 경우: 쓰기 메서드가 `REQUIRES_NEW`로 새 트랜잭션을 연다. 클래스 수준은 readOnly지만 쓰기 메서드에 메서드 수준 `@Transactional`이 있고, 그 메서드가 바깥 트랜잭션 없이 불리는 시작점이다(가장 가까운 선언이 우선한다).
- 고치는 방향: 쓰기 경로의 진입 메서드에 readOnly가 아닌 트랜잭션을 건다. 트랜잭션 매니저의 `validateExistingTransaction`을 `true`로 하면 read-write 안쪽이 readOnly 바깥에 참여할 때 예외로 드러난다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html#tx-propagation-required, https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/orm/jpa/vendor/HibernateJpaDialect.html, https://github.com/spring-projects/spring-framework/blob/main/spring-orm/src/main/java/org/springframework/orm/jpa/vendor/HibernateJpaDialect.java, https://docs.spring.io/spring-data/jpa/reference/jpa/transactions.html, https://docs.hibernate.org/orm/7.1/userguide/html_single/Hibernate_User_Guide.html#hql-read-only-entities

## readOnly가 효과를 내지 못하는 경우

- 의심할 코드: 쓰기 차단이나 읽기 전용 복제본 라우팅, 조회 최적화를 기대하고 `readOnly = true`를 붙였는데, 그 메서드가 read-write 트랜잭션 안에서 불리거나, 전파가 REQUIRED나 REQUIRES_NEW가 아니거나, 프록시를 거치지 않는다.
- 실패 시나리오: 기존 트랜잭션에 참여하는 REQUIRED 메서드는 바깥의 isolation, timeout, readOnly를 따르고 자기 설정은 조용히 무시된다. readOnly는 힌트라서 해석하지 못하는 트랜잭션 매니저는 예외 없이 무시하고, 쓰기를 반드시 막지도 않는다. JDBC(DataSourceTransactionManager)는 기본으로 `Connection.setReadOnly(true)` 힌트만 주며, `SET TRANSACTION READ ONLY`로 쓰기를 강제로 막으려면 `enforceReadOnly`를 켜야 한다.
- 문제가 아닌 경우: readOnly를 성능 힌트로만 쓰고 결과의 정확성이 readOnly에 기대지 않는 경우. 무시되어도 동작은 같으므로 결함으로 보지 않는다.
- 고치는 방향: readOnly에 기대는 동작(복제본 라우팅, 쓰기 차단)이 있으면 그 트랜잭션이 실제로 새로 시작되는 진입점에 readOnly를 건다.
- 출처: https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/annotation/Transactional.html, https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html, https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html#tx-propagation-required, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/jdbc/datasource/DataSourceTransactionManager.html

## REQUIRES_NEW와 커넥션 풀 고갈

- 의심할 코드: 트랜잭션 안에서 `@Transactional(propagation = Propagation.REQUIRES_NEW)` 메서드를 부른다. 요청마다 타는 경로, 반복문 안, 동시 요청이 많은 경로일수록 의심한다.
- 실패 시나리오: 바깥 트랜잭션의 커넥션은 묶인 채로 남고 안쪽이 커넥션을 하나 더 얻는다. 여러 스레드가 바깥 트랜잭션을 연 채 안쪽 커넥션을 기다리면 풀이 바닥나 서로 기다리는 교착 상태가 된다. 공식 문서는 풀 크기가 동시 스레드 수보다 최소 1 크지 않으면 쓰지 말라고 한다.
- 문제가 아닌 경우: 바깥에 트랜잭션이 없는 곳에서만 불려 새 트랜잭션 하나만 여는 경우. 풀 크기가 동시 처리 스레드 수보다 크다는 것이 설정으로 확인되는 경우. 풀 크기와 동시 요청 수는 코드만으로 알 수 없으므로 단정하지 말고 확인이 필요하다고 적는다.
- 고치는 방향: 안쪽 작업을 바깥 커밋 뒤(AFTER_COMMIT 리스너 등)로 옮기거나 같은 트랜잭션으로 합친다. 꼭 필요하면 풀 크기를 동시 스레드 수보다 크게 잡는다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html#tx-propagation-requires_new

## REQUIRES_NEW의 독립 커밋

- 의심할 코드: 바깥 작업과 함께 롤백되어야 할 데이터(주문 상태, 재고 차감, 포인트 적립)를 `REQUIRES_NEW` 메서드에서 쓴다. 안쪽 `REQUIRES_NEW`가 바깥이 방금 쓰고 아직 커밋하지 않은 행을 읽거나 같은 행을 수정한다.
- 실패 시나리오: 안쪽 트랜잭션은 별도 물리 트랜잭션이라 따로 커밋되고, 바깥이 나중에 롤백해도 남는다. 안쪽이 롤백되어도 바깥은 영향을 받지 않는다. 안쪽은 다른 커넥션이라 바깥의 커밋 전 변경을 보지 못하고, 바깥이 잡은 행 락을 기다리면 같은 스레드가 자기 자신을 기다리게 되어 락 대기 시간이 끝날 때까지 멈춘다.
- 문제가 아닌 경우: 감사 로그나 실패 기록처럼 바깥이 롤백되어도 남아야 하는 데이터를 일부러 따로 커밋하는 경우. 이때는 그 의도가 이름이나 주석으로 드러나는지만 본다.
- 고치는 방향: 함께 성공하고 함께 실패해야 하면 REQUIRED로 둔다. 따로 남겨야 하면 바깥이 롤백될 때 남는 데이터가 정합한지 확인한다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html#tx-propagation-requires_new

## NESTED와 savepoint

- 의심할 코드: `Propagation.NESTED`. 특히 JPA로 엔티티를 바꾸는 메서드를 NESTED로 두고, 그 예외를 바깥에서 잡아 계속 진행한다.
- 실패 시나리오: NESTED는 한 물리 트랜잭션 안의 savepoint로 동작하며 JDBC 자원 트랜잭션에서만 된다. DataSourceTransactionManager 계열은 `nestedTransactionAllowed` 기본값이 `true`다. JpaTransactionManager는 기본값이 `false`라 바깥 트랜잭션이 있을 때 NESTED를 쓰면 NestedTransactionNotSupportedException이 난다. 켜더라도 savepoint는 JDBC 커넥션에만 적용되어 EntityManager에 캐시된 엔티티 상태는 되돌아가지 않으며, JPA 자체는 중첩 트랜잭션을 지원하지 않는다.
- 문제가 아닌 경우: JdbcTemplate이나 JdbcClient만 쓰는 코드에서 DataSourceTransactionManager로 NESTED를 쓰고 드라이버가 savepoint를 지원하는 경우. 바깥 트랜잭션이 없으면 NESTED는 REQUIRED처럼 새 트랜잭션을 연다.
- 고치는 방향: JPA에서 부분 롤백이 필요하면 실패할 수 있는 검증을 쓰기 전에 끝내거나, 작업을 별도 트랜잭션으로 나눈다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html#tx-propagation-nested, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/orm/jpa/JpaTransactionManager.html, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/jdbc/datasource/DataSourceTransactionManager.html, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/annotation/Propagation.html

## 체크 예외와 기본 롤백 규칙

- 의심할 코드: `@Transactional` 메서드가 체크 예외(`Exception`을 상속했지만 `RuntimeException`이 아닌 것, 예: `IOException`, `OrderException extends Exception`)를 던지는데 `rollbackFor`가 없다. `rollbackForClassName = "Exception"`처럼 짧은 이름 패턴을 쓴다.
- 실패 시나리오: 기본 규칙은 RuntimeException과 Error만 롤백하고 체크 예외는 커밋한다. 예외 직전까지의 변경이 커밋되어 호출자는 실패로 처리하지만 DB에는 일부가 남는다. 이름 패턴 규칙은 예외의 전체 이름에 그 문자열이 들어 있기만 하면 맞으므로 `"Exception"`은 거의 모든 예외에 걸리고 비슷한 이름의 예외도 잘못 맞는다.
- 문제가 아닌 경우: 체크 예외를 던져도 그때까지의 변경을 커밋하는 것이 의도인 경우. Spring Framework 6.2 이상에서 `@EnableTransactionManagement(rollbackOn = RollbackOn.ALL_EXCEPTIONS)`로 전역 기본값을 바꾼 경우. 체크 예외가 트랜잭션 메서드 밖으로 나가기 전에 런타임 예외로 감싸지는 경우.
- 고치는 방향: `rollbackFor = Exception.class`처럼 타입으로 지정한다(타입 규칙은 하위 클래스까지 맞는다). 6.2 이상이면 전역 ALL_EXCEPTIONS를 쓴다. 공식 문서는 EJB식으로 커밋되는 비즈니스 예외에 기대지 않는다면 ALL_EXCEPTIONS를 권한다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/rolling-back.html, https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/annotation/RollbackOn.html

## 안쪽 REQUIRED 메서드의 예외를 바깥에서 잡는 경우

- 의심할 코드: 바깥 `@Transactional` 메서드가 다른 빈의 `@Transactional`(기본 REQUIRED) 메서드나 Spring Data 리포지토리 메서드를 `try-catch`로 감싸 런타임 예외를 잡고 계속 진행한다. 예: `try { pointService.earn(order) } catch (RuntimeException e) { log.warn(...) }`.
- 실패 시나리오: 안쪽은 바깥과 같은 물리 트랜잭션에 참여하므로, 롤백 대상 예외가 안쪽 경계를 나가는 순간 트랜잭션 전체에 rollback-only 표시가 남는다. 바깥이 정상 종료해 커밋을 시도하면 실제로는 롤백되고 UnexpectedRollbackException이 던져진다. 호출자는 성공을 기대한 곳에서 예외를 받고 바깥에서 쓴 데이터도 모두 사라진다.
- 문제가 아닌 경우: 안쪽 메서드에 트랜잭션 경계가 없는 경우(일반 메서드라 rollback-only 표시가 남지 않는다). 잡은 예외가 안쪽 롤백 규칙에 걸리지 않는 경우(체크 예외, `noRollbackFor`). 안쪽이 `REQUIRES_NEW`이거나 NESTED를 지원하는 매니저에서 NESTED인 경우. 다만 Hibernate가 던진 예외는 Hibernate 문서상 복구할 수 없는 것으로 보고 세션을 계속 쓰지 말아야 하므로, 이 경우는 경계와 무관하게 의심한다.
- 고치는 방향: 실패해도 계속 가야 하는 작업은 `REQUIRES_NEW`로 분리하거나(풀 크기 확인), 예외가 나지 않도록 먼저 검증하거나, 바깥도 함께 실패시킨다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html#tx-propagation-required, https://docs.spring.io/spring-data/jpa/reference/jpa/transactions.html, https://docs.hibernate.org/orm/7.1/userguide/html_single/Hibernate_User_Guide.html#pc-exception-handling

## 트랜잭션 안의 외부 호출과 긴 작업

- 의심할 코드: `@Transactional` 메서드나 `TransactionTemplate` 콜백 안에서 `RestClient`, `RestTemplate`, `WebClient.block()` 같은 HTTP 호출, 메시지 전송 대기, 파일 업로드, `Thread.sleep`, 재시도 루프, 대량 반복 처리를 한다. 특히 UPDATE나 `@Lock(LockModeType.PESSIMISTIC_WRITE)`, `SELECT ... FOR UPDATE` 뒤에 외부 호출이 온다.
- 실패 시나리오: 트랜잭션 매니저는 트랜잭션 동안 커넥션을 스레드에 묶어 두고, 쓰기나 비관적 락으로 잡은 행 락은 트랜잭션이 끝나야 풀린다. 외부 응답이 느려지면 커넥션이 반납되지 않아 풀 대기가 쌓이고, 같은 행을 쓰려는 다른 요청이 락을 기다리다 시간 초과로 실패한다. 외부 호출이 성공한 뒤 커밋이 실패하면 외부 시스템에만 반영된 상태가 남는다.
- 문제가 아닌 경우: 호출 대상이 프로세스 안의 빠른 연산인 경우. 아직 행을 쓰거나 잠그기 전이고 짧은 타임아웃이 있는 호출이면 락 경합은 없지만 커넥션은 계속 잡으므로, 호출량이 많은 경로가 아니면 낮은 심각도로만 남긴다.
- 고치는 방향: 조회, 외부 호출, 짧은 쓰기 트랜잭션 순서로 나누거나 커밋 뒤 작업은 AFTER_COMMIT 리스너로 옮기고, 외부 호출에는 타임아웃을 둔다. JPA 웹 애플리케이션은 Spring Boot가 기본으로 Open EntityManager in View를 켜고 Spring이 Hibernate 커넥션 처리를 DELAYED_ACQUISITION_AND_HOLD로 두므로, 트랜잭션 밖으로 옮겨도 그 요청에서 이미 얻은 커넥션은 요청이 끝날 때까지 잡혀 있을 수 있다. 이때는 `spring.jpa.open-in-view=false`를 검토한다.
- 출처: https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/jdbc/datasource/DataSourceTransactionManager.html, https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html#tx-propagation-requires_new, https://docs.spring.io/spring-boot/reference/data/sql.html, https://github.com/spring-projects/spring-framework/blob/main/spring-orm/src/main/java/org/springframework/orm/jpa/vendor/HibernateJpaVendorAdapter.java

## @TransactionalEventListener의 단계와 실행 조건

- 의심할 코드: 꼭 실행되어야 하는 후속 작업(포인트 지급, 외부 전송)을 `@TransactionalEventListener`(기본 phase AFTER_COMMIT)에 맡기는데, 이벤트를 발행하는 코드가 트랜잭션 밖에서도 불릴 수 있다. phase가 BEFORE_COMMIT, AFTER_ROLLBACK, AFTER_COMPLETION인 리스너가 이름과 다른 시점을 기대한다.
- 실패 시나리오: 발행 시점에 활성 트랜잭션이 없으면 이벤트는 버려지고 리스너는 불리지 않는다(`fallbackExecution` 기본값은 `false`). 트랜잭션이 롤백되면 AFTER_COMMIT 리스너는 불리지 않는다. AFTER_COMMIT, AFTER_ROLLBACK, AFTER_COMPLETION 리스너는 트랜잭션 완료 콜백(`afterCompletion`)에서 실행되므로, 리스너가 던진 예외는 로그로만 남고 호출자에게 전달되지 않는다.
- 문제가 아닌 경우: 발행 메서드가 항상 트랜잭션 안에서 불리는 것이 호출 구조로 확인되는 경우. 리스너 작업이 실패해도 되는 알림성 작업이거나 재처리 수단이 따로 있는 경우. `fallbackExecution = true`로 트랜잭션 밖 발행도 처리하게 한 경우. BEFORE_COMMIT 리스너의 예외는 커밋 전이라 원래 트랜잭션을 실패시킨다.
- 고치는 방향: 반드시 처리해야 하는 후속 작업은 같은 트랜잭션 안에서 처리할 일을 테이블에 기록하고 커밋 뒤 따로 처리하는 방식을 검토한다. 트랜잭션 밖 발행이 가능하면 `fallbackExecution`을 명시한다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/event.html, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/event/TransactionalEventListener.html, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/support/TransactionSynchronization.html, https://github.com/spring-projects/spring-framework/blob/main/spring-tx/src/main/java/org/springframework/transaction/event/TransactionalApplicationListenerSynchronization.java

## AFTER_COMMIT 리스너에서 DB에 쓰기

- 의심할 코드: AFTER_COMMIT(기본값), AFTER_ROLLBACK, AFTER_COMPLETION 리스너 안에서 리포지토리 `save()`, 엔티티 변경, `JdbcTemplate.update()`를 하거나, 기본 REQUIRED인 `@Transactional` 서비스 메서드를 부른다.
- 실패 시나리오: 원래 트랜잭션은 이미 커밋되었지만 트랜잭션 자원이 아직 묶여 있어, 리스너의 데이터 접근은 원래 트랜잭션에 참여하고 그 뒤에 커밋이 없다. REQUIRED 메서드를 불러도 새 트랜잭션이 열리지 않으므로 쓴 내용이 오류 없이 반영되지 않는다.
- 문제가 아닌 경우: 리스너가 부르는 쓰기 메서드가 `REQUIRES_NEW`다. 리스너에 `@Async`가 있어 원래 트랜잭션이 묶여 있지 않은 다른 스레드에서 실행된다. BEFORE_COMMIT 리스너라 원래 트랜잭션과 함께 커밋된다. 읽기만 한다.
- 고치는 방향: 리스너의 쓰기는 `@Transactional(propagation = Propagation.REQUIRES_NEW)` 메서드로 하거나 `@Async`로 다른 스레드에서 처리한다.
- 출처: https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/event/TransactionalEventListener.html, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/support/TransactionSynchronization.html

## 리스너 메서드에 붙인 @Transactional

- 의심할 코드: `@TransactionalEventListener` 메서드에 `@Transactional`(기본 REQUIRED)이 붙어 있거나, 리스너가 있는 클래스에 클래스 수준 `@Transactional`이 있다.
- 실패 시나리오: Spring Framework 6.1부터 트랜잭션 리스너에 붙은 `@Transactional`의 전파가 REQUIRES_NEW나 NOT_SUPPORTED가 아니면 기동할 때 IllegalStateException으로 실패한다. 6.1은 메서드의 어노테이션만 보고, 6.2.0부터는 클래스 수준 `@Transactional`도 본다. `@Async`가 함께 있어도 검사는 같다.
- 문제가 아닌 경우: 전파를 REQUIRES_NEW나 NOT_SUPPORTED로 선언한 경우. 6.2.10 이상과 7.x에서는 phase가 BEFORE_COMMIT인 리스너에 어떤 전파든 허용한다. 6.0 이하에는 이 검사가 없지만, 그때도 AFTER_COMMIT 리스너의 REQUIRED 쓰기는 앞 항목처럼 커밋되지 않는다.
- 고치는 방향: 리스너 메서드에 `@Transactional(propagation = Propagation.REQUIRES_NEW)`를 명시하거나, 리스너를 클래스 수준 트랜잭션이 없는 별도 클래스로 옮긴다.
- 출처: https://github.com/spring-projects/spring-framework/blob/6.1.x/spring-tx/src/main/java/org/springframework/transaction/annotation/RestrictedTransactionalEventListenerFactory.java, https://github.com/spring-projects/spring-framework/blob/v6.2.0/spring-tx/src/main/java/org/springframework/transaction/annotation/RestrictedTransactionalEventListenerFactory.java, https://github.com/spring-projects/spring-framework/blob/v6.2.10/spring-tx/src/main/java/org/springframework/transaction/annotation/RestrictedTransactionalEventListenerFactory.java

## @Async로 넘긴 작업과 트랜잭션 맥락

- 의심할 코드: `@Transactional` 메서드 안에서 `@Async` 메서드, `CompletableFuture.supplyAsync`, `executor.execute`로 DB 작업을 넘긴다. 넘긴 작업이 방금 저장한 엔티티를 id로 다시 조회하거나 엔티티 객체를 그대로 받는다.
- 실패 시나리오: 트랜잭션은 스레드에 묶여 있어 새 스레드로 넘어가지 않는다. 비동기 작업의 쓰기는 바깥과 따로 커밋되거나 트랜잭션 없이 실행되어 바깥이 롤백되어도 남는다. 비동기 작업이 바깥 커밋 전에 시작되면 커밋되지 않은 행을 보지 못해 조회 결과가 없거나 이전 값을 읽는다. 넘겨받은 엔티티의 지연 연관은 원래 세션이 닫히면 LazyInitializationException이 난다.
- 문제가 아닌 경우: 비동기 쪽이 바깥 데이터에 기대지 않고 자체 트랜잭션으로 처리하며 바깥 롤백과 무관해도 되는 작업인 경우. `@Async`와 `@Transactional`을 같은 메서드에 붙이면 비동기 전환이 먼저 일어나 트랜잭션은 새 스레드에서 시작된다. AFTER_COMMIT 리스너에서 `@Async`로 넘겨 커밋 뒤에 시작하는 경우. 같은 클래스 안에서 부른 `@Async`는 프록시를 거치지 않아 동기로 실행되므로 이 항목이 아니라 자기 호출 항목으로 본다.
- 고치는 방향: 바깥 데이터를 읽어야 하는 비동기 작업은 `@TransactionalEventListener`(AFTER_COMMIT)와 `@Async`로 커밋 뒤에 시작한다. 엔티티 대신 id를 넘기고 비동기 쪽에서 새로 조회한다.
- 출처: https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/annotation/Transactional.html, https://github.com/spring-projects/spring-framework/blob/main/spring-context/src/main/java/org/springframework/scheduling/annotation/AsyncAnnotationBeanPostProcessor.java, https://docs.spring.io/spring-framework/reference/data-access/transaction/event.html, https://docs.hibernate.org/orm/7.1/introduction/html_single/Hibernate_Introduction.html#proxies-and-lazy-fetching

## 인스턴스 여러 개에서 겹쳐 도는 @Scheduled

- 의심할 코드: `@Scheduled(cron = ...)`, `fixedRate`, `fixedDelay` 메서드가 정산, 발송, 일괄 상태 변경, 외부 전송처럼 한 번만 실행되어야 하는 일을 하고, 분산 락이나 처리 대상 선점 같은 중복 방지 장치가 보이지 않는다.
- 실패 시나리오: 스케줄러는 애플리케이션 프로세스마다 따로 돈다. 같은 애플리케이션을 두 대 이상 띄우거나 롤링 배포로 새 버전과 옛 버전이 잠시 함께 떠 있으면 같은 작업이 동시에 실행되어 중복 발송, 이중 정산, 락 경합이 난다. Spring Boot에서 가상 스레드(Java 21 이상, `spring.threads.virtual.enabled=true`)를 켜면 SimpleAsyncTaskScheduler가 쓰이는데, 이 스케줄러는 실행마다 새 스레드에 넘기고 완료를 추적하지 않으므로 한 인스턴스 안에서도 fixedRate와 cron 작업이 이전 실행과 겹칠 수 있다(fixedDelay는 스케줄러 스레드 하나에서 돈다).
- 문제가 아닌 경우: 단일 인스턴스로만 운영되는 것이 설정이나 문서로 확인되는 경우. 두 번 돌아도 결과가 같게 만든 경우(조건부 UPDATE로 한 행을 한 번만 처리하는 등). DB 락이나 분산 락으로 한 인스턴스만 실행되게 막은 경우. 가상 스레드를 켜지 않았다면 Boot의 기본 ThreadPoolTaskScheduler는 스레드 1개라 한 인스턴스 안에서 같은 작업이 겹치지 않는다. 인스턴스 수는 코드로 알 수 없으므로 단정하지 말고 확인이 필요하다고 적는다.
- 고치는 방향: 분산 락이나 조건부 UPDATE로 처리 대상을 선점해 한 번만 처리되게 하거나, 스케줄 작업을 한 인스턴스에서만 켠다.
- 출처: https://docs.spring.io/spring-framework/reference/integration/scheduling.html, https://docs.spring.io/spring-boot/reference/features/task-execution-and-scheduling.html, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/scheduling/concurrent/SimpleAsyncTaskScheduler.html, https://github.com/spring-projects/spring-framework/blob/main/spring-context/src/main/java/org/springframework/scheduling/concurrent/SimpleAsyncTaskScheduler.java, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/scheduling/concurrent/ThreadPoolTaskScheduler.html

## suspend 함수에 붙인 @Transactional

- 의심할 코드: Kotlin `suspend fun`에 `@Transactional`이 붙어 있고 프로젝트가 JPA나 JDBC(JpaTransactionManager, DataSourceTransactionManager)를 쓴다. 함수 안에 `delay`, `withContext`, 다른 suspend 호출 같은 중단 지점이 있다.
- 실패 시나리오: 코루틴의 트랜잭션은 리액티브 트랜잭션(ReactiveTransactionManager) 위에서 동작하며, 스레드에 묶인 트랜잭션과 함께 쓰도록 설계되지 않았다고 Spring 관리자가 공식 이슈에서 밝혔다. PlatformTransactionManager만 있으면 Spring은 일반 메서드처럼 트랜잭션을 열고 대상 메서드 호출이 처음 반환되는 시점에 커밋한다. 소스 기준으로 kotlinx-coroutines-reactor가 있으면 suspend 함수가 지연 실행되는 Publisher로 호출되어 본문이 커밋 뒤에 실행되고, 없으면 첫 중단 지점까지만 트랜잭션 안에서 실행된다. 오류는 나지 않고 롤백과 원자성이 조용히 빠진다.
- 문제가 아닌 경우: R2DBC처럼 ReactiveTransactionManager를 쓰는 경우(Spring Framework 5.3부터 suspend 함수의 `@Transactional`을 지원한다). `TransactionalOperator.executeAndAwait`로 감싼 경우. suspend 함수 자체에는 트랜잭션이 없고, 그 안에서 부르는 suspend가 아닌 `@Transactional` 메서드가 트랜잭션을 연다.
- 고치는 방향: JPA와 JDBC에서는 트랜잭션 경계를 suspend가 아닌 일반 함수에 두고, suspend 함수는 `withContext(Dispatchers.IO)` 안에서 그 함수를 부른다. 리액티브 스택이면 ReactiveTransactionManager나 `TransactionalOperator`를 쓴다.
- 출처: https://docs.spring.io/spring-framework/reference/languages/kotlin/coroutines.html#transactions, https://github.com/spring-projects/spring-framework/issues/26705, https://github.com/spring-projects/spring-framework/issues/23575, https://github.com/spring-projects/spring-framework/blob/main/spring-tx/src/main/java/org/springframework/transaction/interceptor/TransactionAspectSupport.java, https://github.com/spring-projects/spring-framework/blob/main/spring-aop/src/main/java/org/springframework/aop/support/AopUtils.java

## TransactionTemplate 콜백 안의 예외 처리

- 의심할 코드: `transactionTemplate.execute { ... }`나 `executeWithoutResult { ... }` 콜백 안에서 예외를 잡고 `status.setRollbackOnly()` 없이 정상 반환한다. 바깥 `@Transactional` 안에서 기본 TransactionTemplate을 쓰며 별도 트랜잭션을 기대한다.
- 실패 시나리오: TransactionTemplate은 콜백이 정상 반환하면 커밋하므로, 콜백 안에서 삼킨 예외 앞의 변경이 커밋된다. 반대로 콜백 밖으로 나간 예외는 런타임 예외든 체크 예외든 모두 롤백하고 체크 예외는 UndeclaredThrowableException으로 감싸 던지므로, 선언적 `@Transactional`의 기본 규칙(체크 예외는 커밋)과 다르다. 기본 설정은 REQUIRED라 바깥 트랜잭션이 있으면 참여하고, 콜백에서 나간 예외는 바깥 전체를 rollback-only로 만든다.
- 문제가 아닌 경우: 콜백 안에서 잡은 예외 앞의 변경을 커밋해도 되는 경우. 전파를 `PROPAGATION_REQUIRES_NEW`로 설정한 전용 템플릿을 쓰는 경우.
- 고치는 방향: 잡아야 하면 `status.setRollbackOnly()`를 부르거나 예외를 다시 던진다. 별도 트랜잭션이 필요하면 전파를 바꾼 전용 TransactionTemplate 인스턴스를 만든다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/programmatic.html#tx-prog-template, https://github.com/spring-projects/spring-framework/blob/main/spring-tx/src/main/java/org/springframework/transaction/support/TransactionTemplate.java

## 공유 TransactionTemplate의 설정 변경

- 의심할 코드: 주입받은 `TransactionTemplate`(트랜잭션 매니저가 하나면 Spring Boot가 자동 등록하는 빈)에 `setPropagationBehavior`, `setIsolationLevel`, `setReadOnly`, `setTimeout`을 호출한다. 생성자나 요청 처리 메서드 안에서 호출하면 더 위험하다.
- 실패 시나리오: TransactionTemplate은 대화 상태가 없어 스레드 안전하지만 설정 상태는 가진다. 공유 빈의 설정을 바꾸면 그 빈을 쓰는 다른 모든 클래스의 트랜잭션 동작이 바뀌고, 요청 처리 중에 바꾸면 동시에 실행되는 다른 요청도 바뀐 설정으로 실행된다.
- 문제가 아닌 경우: `TransactionTemplate(transactionManager)`로 그 클래스 전용 인스턴스를 새로 만들어 설정하는 경우.
- 고치는 방향: 설정이 다르면 별도 인스턴스를 만든다. 공식 문서도 설정이 다르면 인스턴스를 따로 만들라고 한다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/programmatic.html#tx-prog-template-settings, https://github.com/spring-projects/spring-boot/blob/main/module/spring-boot-transaction/src/main/java/org/springframework/boot/transaction/autoconfigure/TransactionAutoConfiguration.java
