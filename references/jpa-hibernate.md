# JPA와 Hibernate 참조

적용 버전: Spring Boot 3.x와 4.x, Hibernate ORM 6.x와 7.x, Jakarta Persistence 3.1과 3.2, Spring Data JPA 3.x와 4.x, QueryDSL 5.x. Spring Boot 3.x는 Hibernate 6.1부터 6.6까지, Spring Boot 4.0.0은 7.1, 4.0.1부터 4.0.x까지는 7.2, 4.1과 4.2는 7.4를 기본으로 쓴다. 버전에 따라 결론이 갈리는 내용은 해당 항목 안에 버전을 적었다.

## 지연 연관 접근으로 생기는 N+1

- 의심할 코드: 목록 조회 결과를 `for`, `stream().map`, DTO 생성자, 매퍼로 돌면서 `order.getMember().getName()`이나 `order.getItems()`처럼 LAZY 연관을 건드리는 코드. 연관 필드를 포함하는 `toString()`(Lombok `@ToString`, Kotlin `data class`의 자동 `toString`)과, 엔티티를 그대로 JSON 응답으로 직렬화하는 컨트롤러도 같다.
- 실패 시나리오: 목록 N건마다 연관 조회가 한 번씩 더 나가 쿼리가 N+1개가 된다. 목록 길이에 비례해 응답이 느려지고 커넥션 점유 시간이 늘어난다. 영속성 컨텍스트가 닫힌 뒤에 접근하면 쿼리 대신 `LazyInitializationException`이 난다.
- 문제가 아닌 경우: 연관 엔티티의 식별자만 읽는 경우(`order.getMember().getId()`는 프록시를 초기화하지 않는다). 조회 쿼리가 그 연관을 `join fetch`나 `@EntityGraph`로 이미 가져오는 경우. 결과가 한 건이거나 크기가 작게 고정된 경우. 배치 페치가 설정되어 있으면 "배치 페치와 엔티티 그래프" 항목대로 심각도를 낮춘다.
- 고치는 방향: 필요한 연관을 조회 시점에 `join fetch`나 `@EntityGraph`로 함께 가져오거나, 필요한 칼럼만 DTO 프로젝션으로 조회한다. `toString`과 직렬화 대상에서 연관 필드를 뺀다.
- 출처: https://docs.hibernate.org/orm/7.1/introduction/html_single/#proxies-and-lazy-fetching, https://docs.hibernate.org/orm/7.1/introduction/html_single/#batch-subselect-fetch

## @ManyToOne과 @OneToOne의 기본 EAGER

- 의심할 코드: `fetch`를 지정하지 않은 `@ManyToOne`, `@OneToOne`, 또는 `fetch = FetchType.EAGER`. 이런 연관을 가진 엔티티를 JPQL, 파생 쿼리(`findByStatus`), `findAll()`, QueryDSL로 목록 조회하는 코드.
- 실패 시나리오: 두 연관의 JPA 기본 fetch는 EAGER다. JPQL 조회에서 EAGER 연관을 `join fetch`하지 않으면 Hibernate가 연관마다 보조 SELECT를 보내 N+1이 된다. fetch graph를 주지 않은 JPQL, 파생 쿼리, `findAll()`, QueryDSL 조회에서는 연관을 쓰지 않아도 매번 나간다.
- 문제가 아닌 경우: `findById`나 `EntityManager.find`처럼 식별자로 한 건을 직접 읽으면 Hibernate가 EAGER 연관을 조인으로 가져온다. JPQL이 그 연관을 `join fetch`한다. FETCH 타입 `@EntityGraph`(Spring Data의 기본 type)나 `jakarta.persistence.fetchgraph` 힌트를 준 조회는 그래프에 없는 EAGER 연관을 가져오지 않으므로 EAGER N+1로 지적하지 않는다. 대신 그 조회에서는 그래프 밖 연관이 지연 로딩이 되므로, 나중에 건드리는 코드는 "지연 연관 접근으로 생기는 N+1" 항목 기준(N+1, 트랜잭션 밖이면 `LazyInitializationException`)으로 본다. LOAD 타입 그래프는 매핑의 EAGER를 그대로 따른다. 반대로 `mappedBy` 쪽 `@OneToOne`은 LAZY로 적어도 Hibernate가 연관 유무를 알 수 없어 보조 조회를 하므로(바이트코드 향상이 없으면), LAZY 지정만으로 해결됐다고 보지 않는다.
- 고치는 방향: 연관에 `fetch = FetchType.LAZY`를 명시하고 필요한 쿼리에서만 `join fetch`한다. 양방향 `@OneToOne`은 단방향 매핑과 `@MapsId`를 검토한다.
- 출처: https://jakarta.ee/specifications/persistence/3.2/jakarta-persistence-spec-3.2.html#manytoone-annotation, https://docs.hibernate.org/orm/7.1/userguide/html_single/#best-practices-fetching, https://docs.hibernate.org/orm/7.1/userguide/html_single/#fetching-direct-vs-query, https://docs.hibernate.org/orm/7.1/userguide/html_single/#associations-one-to-one-bidirectional-lazy, https://docs.hibernate.org/orm/7.1/userguide/html_single/#fetching-strategies-dynamic-fetching-entity-graph, https://github.com/hibernate/hibernate-orm/blob/7.1.8/hibernate-core/src/main/java/org/hibernate/sql/results/internal/StandardEntityGraphTraversalStateImpl.java, https://github.com/spring-projects/spring-data-jpa/blob/main/spring-data-jpa/src/main/java/org/springframework/data/jpa/repository/EntityGraph.java

## 컬렉션 fetch join과 페이징

- 의심할 코드: `join fetch`나 `@EntityGraph(attributePaths = "items")`로 `@OneToMany`, `@ManyToMany` 컬렉션을 가져오면서 `Pageable`, `setFirstResult`, `setMaxResults`, HQL `limit`, QueryDSL `offset`과 `limit`을 함께 쓰는 코드.
- 실패 시나리오: Hibernate 6.x와 7.0부터 7.3까지(Spring Boot 3.x와 4.0)는 SQL에 limit을 붙이지 않고 조건에 맞는 행을 전부 읽은 뒤 메모리에서 자른다. 로그에 `HHH90003004: firstResult/maxResults specified with collection fetch; applying in memory` 경고가 남는다. 데이터가 늘면 한 요청이 테이블 대부분을 읽어 메모리와 응답 시간이 함께 커진다. `@EntityGraph`에 컬렉션이 들어가도 Hibernate는 같은 조건으로 판단한다.
- 문제가 아닌 경우: fetch하는 연관이 `@ManyToOne`, `@OneToOne` 같은 단일 연관뿐인 경우. 페이징이 없는 경우. Hibernate 7.4 이상(Spring Boot 4.1 이상 기본)은 limit을 파생 테이블로 SQL에서 처리하므로 메모리 페이징으로 지적하지 않는다. 단 7.4에서도 컬렉션 요소로 먼저 정렬하는 쿼리나 `org.hibernate.limitInMemory` 힌트를 준 쿼리는 메모리에서 자른다.
- 고치는 방향: 부모 ID를 먼저 페이징 조회하고 컬렉션은 그 ID로 따로 조회하거나 배치 페치에 맡긴다. `hibernate.query.fail_on_pagination_over_collection_fetch=true`로 두면 메모리 페이징이 경고 대신 예외가 되어 테스트에서 잡힌다.
- 출처: https://docs.hibernate.org/orm/6.6/userguide/html_single/#hql-explicit-fetch-join, https://docs.hibernate.org/orm/6.6/userguide/html_single/#hql-limit-offset, https://docs.hibernate.org/orm/7.1/userguide/html_single/#settings-hibernate.query.fail_on_pagination_over_collection_fetch, https://github.com/hibernate/hibernate-orm/blob/7.1/hibernate-core/src/main/java/org/hibernate/query/QueryLogging.java, https://github.com/hibernate/hibernate-orm/blob/7.1/hibernate-core/src/main/java/org/hibernate/query/sqm/internal/AppliedGraphs.java, https://docs.hibernate.org/orm/7.4/whats-new/#limit-fetch-join, https://docs.hibernate.org/orm/7.4/migration-guide/#_limits_and_fetch_joins

## 컬렉션 여러 개를 함께 fetch join

- 의심할 코드: 한 쿼리나 하나의 `@EntityGraph`에서 컬렉션 연관을 두 개 이상 `join fetch`하는 코드. 형제 관계(`order.items`와 `order.payments`)든 중첩(`order.items`와 그 아래 `item.options`)이든 같다. 특히 `@OrderColumn` 없는 `List` 컬렉션 둘 이상(Hibernate 기본값에서 bag으로 분류된다).
- 실패 시나리오: bag 두 개를 함께 fetch하면 형제든 중첩이든 `MultipleBagFetchException: cannot simultaneously fetch multiple bags`로 쿼리 생성이 실패한다. Hibernate는 한 문장의 fetch 트리 전체에서 bag을 하나만 허용한다. 형제 컬렉션은 `Set`으로 바꿔 예외를 피해도 DB에서 카테시안 곱이 만들어져 결과 행이 각 컬렉션 크기의 곱만큼 늘어난다.
- 문제가 아닌 경우: 단일 연관 여러 개를 fetch하는 경우. 컬렉션 하나 아래로 단일 연관만 이어지는 중첩 fetch(`order.items`와 `item.product`)는 안전하다. 문서가 괜찮다고 보는 한 줄로 이어지는 중첩 fetch는 카테시안 곱 기준이며, 그 체인에 bag이 둘 이상 들어가면 예외가 난다. 각 컬렉션 크기가 작게 고정된 경우(카테시안 곱에 한해서다).
- 고치는 방향: 컬렉션은 하나만 join fetch하고 나머지는 배치 페치, `@Fetch(FetchMode.SUBSELECT)`, 별도 쿼리로 가져온다. 예외를 없애려고 `List`를 `Set`으로만 바꾼 수정은 카테시안 곱을 그대로 두므로 해결로 보지 않는다.
- 출처: https://docs.hibernate.org/orm/7.1/userguide/html_single/#hql-explicit-fetch-join, https://docs.hibernate.org/orm/7.1/userguide/html_single/#settings-hibernate.mapping.default_list_semantics, https://docs.hibernate.org/orm/7.1/introduction/html_single/#join-fetch, https://github.com/hibernate/hibernate-orm/blob/7.1/hibernate-core/src/main/java/org/hibernate/loader/MultipleBagFetchException.java, https://github.com/hibernate/hibernate-orm/blob/7.4.15/hibernate-core/src/main/java/org/hibernate/query/sqm/sql/BaseSqmToSqlAstConverter.java

## 배치 페치와 엔티티 그래프

- 의심할 코드: `spring.jpa.properties.hibernate.default_batch_fetch_size`, 엔티티나 컬렉션의 `@BatchSize(size = ...)`, 리포지토리 메서드의 `@EntityGraph`. N+1을 지적하기 전에 설정 파일과 엔티티에서 이 값을 먼저 찾는다.
- 실패 시나리오: 배치 페치가 없으면 지연 연관 접근이 N번 나간다. 배치 페치가 있으면 Hibernate가 초기화되지 않은 프록시나 컬렉션을 배치 크기만큼 모아 `IN` 조회 한 번으로 가져오므로 쿼리 수가 대략 N을 배치 크기로 나눈 만큼으로 줄어든다. 문서는 배치 페치가 N+1을 완화할 뿐 해결하지는 않는다고 본다.
- 문제가 아닌 경우: 배치 페치가 적용되는 연관의 루프 접근은 Important로 올리지 않고 Suggestion으로 낮추거나, 목록 크기가 페이지 크기로 묶여 있으면 지적하지 않는다. `@EntityGraph`나 `join fetch`로 이미 가져오는 연관은 N+1이 아니다. 다만 `@EntityGraph`에 컬렉션을 넣고 페이징하면 "컬렉션 fetch join과 페이징" 항목의 조건이 된다.
- 고치는 방향: 화면에서 쓰는 연관이 정해져 있으면 `join fetch`나 `@EntityGraph`로 가져온다. 여러 컬렉션이나 페이징 때문에 조인할 수 없으면 배치 페치로 둔다.
- 출처: https://docs.hibernate.org/orm/7.1/introduction/html_single/#batch-subselect-fetch, https://docs.hibernate.org/orm/7.1/userguide/html_single/#fetching-batch, https://docs.hibernate.org/orm/7.1/userguide/html_single/#settings-hibernate.default_batch_fetch_size, https://docs.spring.io/spring-data/jpa/reference/jpa/query-methods.html#jpa.entity-graph, https://docs.spring.io/spring-boot/reference/data/sql.html#data.sql.jpa-and-spring-data.creating-and-dropping

## open-in-view 기본값

- 의심할 코드: `spring.jpa.open-in-view`를 지정하지 않은 서블릿 웹 애플리케이션. 컨트롤러, 응답 변환, 뷰에서 LAZY 연관을 건드리는 코드. 시작 로그의 `spring.jpa.open-in-view is enabled by default` 경고.
- 실패 시나리오: 값이 없으면 Spring Boot가 `OpenEntityManagerInViewInterceptor`를 등록해 요청 전체 동안 EntityManager를 스레드에 묶는다. 그래서 서비스 트랜잭션이 끝난 뒤 컨트롤러에서도 지연 로딩 쿼리가 나가고, N+1이 서비스 테스트에서 보이지 않는다. Spring이 Hibernate에 거는 기본 커넥션 모드(`DELAYED_ACQUISITION_AND_HOLD`)는 커넥션을 한 번 얻으면 세션이 닫힐 때까지 쥐므로, DB 조회 뒤 외부 API 호출처럼 오래 걸리는 작업이 같은 요청에 있으면 그동안 커넥션이 반납되지 않아 풀이 마른다.
- 문제가 아닌 경우: 서블릿 웹 애플리케이션이 아닌 경우(배치, 메시지 컨슈머, WebFlux). `spring.jpa.open-in-view=false`를 명시한 경우. `true`를 명시했다면 의도한 선택이므로 설정은 지적하지 않고 그 위에서 생기는 지연 로딩과 커넥션 점유만 본다.
- 고치는 방향: `spring.jpa.open-in-view=false`로 두고 필요한 연관은 서비스 트랜잭션 안에서 가져와 DTO로 넘긴다. 끄면 트랜잭션 밖 지연 접근이 `LazyInitializationException`으로 바뀌므로 같은 변경에서 그 경로를 함께 본다.
- 출처: https://docs.spring.io/spring-boot/reference/data/sql.html#data.sql.jpa-and-spring-data.open-entity-manager-in-view, https://docs.spring.io/spring-boot/appendix/application-properties/index.html#application-properties.data.spring.jpa.open-in-view, https://github.com/spring-projects/spring-boot/blob/v4.2.0/module/spring-boot-jpa/src/main/java/org/springframework/boot/jpa/autoconfigure/JpaBaseConfiguration.java, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-orm/src/main/java/org/springframework/orm/jpa/vendor/HibernateJpaVendorAdapter.java

## 변경 감지로 나가는 의도하지 않은 UPDATE

- 의심할 코드: 읽기 전용이 아닌 `@Transactional` 안에서 조회한 엔티티의 setter를 응답 가공, 마스킹, 계산용으로 부르는 코드. 엔티티를 매퍼에 넘겨 필드를 덮어쓰는 코드. 엔티티의 컬렉션을 정렬하거나 비우는 코드.
- 실패 시나리오: 관리 상태 엔티티의 변경은 flush 때 자동으로 감지되어 UPDATE로 나간다. 화면 표시용으로 바꾼 값이 커밋 시점에 DB에 저장된다. `@Version`이 있으면 버전도 올라가 다른 요청과 불필요한 낙관적 락 충돌을 만든다.
- 문제가 아닌 경우: 저장하려고 바꾼 것이면 정상이다. 관리 상태 엔티티에 `save()`를 부르지 않은 것은 결함이 아니다. `@Transactional(readOnly = true)`가 새 트랜잭션을 시작하고 open-in-view가 꺼져 있으면, Spring이 Hibernate flush 모드를 MANUAL로 두고 세션 기본값을 읽기 전용으로 바꿔 dirty check를 건너뛴다. 단 두 경우는 면제하지 않는다. 첫째, readOnly 메서드가 바깥의 읽기 쓰기 트랜잭션에 참여하면 readOnly 설정이 무시되어 바깥 커밋 때 flush된다. 둘째, open-in-view가 켜져 있으면 Spring은 readOnly 트랜잭션 동안 flush 모드만 바꿨다가 되돌리므로, readOnly 메서드 안에서 바꾼 엔티티도 같은 요청의 다음 쓰기 트랜잭션이 커밋될 때 flush된다. `org.hibernate.readOnly` 힌트로 읽은 엔티티는 기본 속성만 dirty check 대상이 아니다. 그 엔티티의 컬렉션을 정렬하거나 비우면 Hibernate 7.2까지(Spring Boot 3.x와 4.0)는 변경이 저장되고, 7.3부터(Spring Boot 4.1 이상)는 flush 때 `HibernateException`(`Immutable collection was modified`)이 난다. 트랜잭션이 끝난 뒤 바꾼 값은 저장되지 않는다. 단 open-in-view가 켜져 있으면 엔티티가 요청 끝까지 관리 상태라, 같은 요청에서 다음 쓰기 트랜잭션이 커밋될 때 함께 flush된다.
- 고치는 방향: 가공은 엔티티가 아니라 DTO에서 한다. 읽기만 하는 흐름은 바깥 쓰기 트랜잭션에 참여하지 않는 `readOnly = true` 트랜잭션으로 분리한다.
- 출처: https://docs.hibernate.org/orm/7.1/userguide/html_single/#pc-managed-state, https://docs.hibernate.org/orm/7.1/userguide/html_single/#hql-read-only-entities, https://docs.spring.io/spring-data/jpa/reference/jpa/transactions.html#transactional-query-methods, https://jakarta.ee/specifications/persistence/3.2/jakarta-persistence-spec-3.2.html#a2059, https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-orm/src/main/java/org/springframework/orm/jpa/vendor/HibernateJpaDialect.java, https://docs.hibernate.org/orm/7.3/migration-guide/#_collections_belonging_to_read_only_entities

## @Modifying 벌크 UPDATE와 DELETE

- 의심할 코드: `@Modifying`과 `@Query("update ...")` 또는 `@Query("delete ...")`를 쓴 메서드. 같은 트랜잭션에서 그 전에 엔티티를 바꾸거나, 그 뒤에 같은 엔티티를 다시 읽고 쓰는 코드. `clearAutomatically`, `flushAutomatically` 값(둘 다 기본 false).
- 실패 시나리오: 벌크 연산은 DB에 바로 실행되고 영속성 컨텍스트는 그 결과와 동기화되지 않는다. 그래서 이미 읽어 둔 엔티티는 옛 값을 돌려주고, 그 엔티티를 바꿔 flush하면 옛 값이 섞인 UPDATE가 벌크로 바꾼 값을 덮어쓸 수 있다. 낙관적 락 검사를 우회하고 version을 올리지 않으며, 벌크 DELETE는 연관 엔티티로 cascade되지 않고 `@PreRemove` 같은 콜백도 돌지 않는다. `clearAutomatically = true`만 켜면 아직 flush되지 않은 변경이 함께 버려진다.
- 문제가 아닌 경우: 벌크 연산 뒤 같은 트랜잭션에서 그 엔티티를 다시 쓰지 않는 경우. Hibernate는 기본 AUTO flush 모드에서 쿼리 실행 전에 관련 테이블의 대기 변경을 flush하므로, 같은 테이블의 변경만 걱정하는 상황에서 `flushAutomatically`가 없다는 이유만으로는 결함이 아니다. 파생 삭제 메서드(`deleteByStatus`)는 엔티티를 읽어 하나씩 지우므로 콜백과 cascade가 돈다(대신 건수만큼 메모리와 DELETE를 쓴다).
- 고치는 방향: 벌크 연산 뒤 같은 엔티티를 쓰면 `@Modifying(clearAutomatically = true, flushAutomatically = true)`로 둔다. version 관리 대상이면 쿼리에서 `version = version + 1`을 직접 올린다.
- 출처: https://docs.spring.io/spring-data/jpa/reference/jpa/query-methods.html#jpa.modifying-queries, https://github.com/spring-projects/spring-data-jpa/blob/main/spring-data-jpa/src/main/java/org/springframework/data/jpa/repository/Modifying.java, https://jakarta.ee/specifications/persistence/3.2/jakarta-persistence-spec-3.2.html#a5636, https://docs.hibernate.org/orm/7.1/userguide/html_single/#flushing-auto

## @Version 낙관적 락이 동작하는 조건

- 의심할 코드: `@Version`이 있는 엔티티의 수정 흐름. 요청 DTO에 version이 없는 수정 API, `findById` 뒤 DTO 값을 복사하는 코드, `order.setVersion(request.version())`, DTO로 `new Order(id, ...)`를 만들어 `save()`하는 코드, version을 건드리지 않는 `@Modifying` 쿼리나 JDBC UPDATE.
- 실패 시나리오: 검사는 영속성 컨텍스트가 읽은 version과 DB의 version을 쓰기 시점에 비교하는 것이다. 수정 요청마다 새로 읽고 바로 쓰면 검사 구간이 그 트랜잭션 안으로 좁아져, 사용자가 오래된 화면을 보고 보낸 수정이 다른 사용자의 변경을 덮어써도 충돌이 나지 않는다(클라이언트가 version을 보내지 않는 경우). 관리 상태 엔티티의 version을 애플리케이션이 직접 바꾸는 것은 명세상 정의되지 않은 동작이라 검사를 보장하지 않는다. version이 null인 새 인스턴스를 `save()`하면 Spring Data가 새 엔티티로 보고 persist로 보내므로 버전 검사가 없다. 벌크 UPDATE는 낙관적 락을 우회한다.
- 문제가 아닌 경우: 같은 트랜잭션에서 읽고 바꾸는 관리 상태 엔티티는 flush 때 version 조건으로 검사된다. 클라이언트가 보낸 version을 담은 준영속 인스턴스를 `merge`(Spring Data `save()`)하면 명세상 provider가 version을 비교해 오래된 값이면 `OptimisticLockException`을 던진다. 동시 수정이 일어날 수 없는 흐름은 지적하지 않는다.
- 고치는 방향: 수정 요청에 version을 받고, 조회한 엔티티의 version과 비교해 다르면 충돌로 처리한다. Spring은 버전 충돌을 `ObjectOptimisticLockingFailureException`(JPA 예외에서 오면 하위 타입인 `JpaOptimisticLockingFailureException`)으로 바꿔 주므로 이를 잡아 409나 재시도로 처리한다.
- 출처: https://jakarta.ee/specifications/persistence/3.2/jakarta-persistence-spec-3.2.html#a2060, https://jakarta.ee/specifications/persistence/3.2/jakarta-persistence-spec-3.2.html#a2056, https://jakarta.ee/specifications/persistence/3.2/jakarta-persistence-spec-3.2.html#a2059, https://docs.spring.io/spring-data/jpa/reference/jpa/entity-persistence.html#jpa.entity-persistence.saving-entities.strategies, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-orm/src/main/java/org/springframework/orm/jpa/hibernate/HibernateExceptionTranslator.java, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-orm/src/main/java/org/springframework/orm/jpa/EntityManagerFactoryUtils.java

## 비관적 락과 락 타임아웃

- 의심할 코드: `@Lock(LockModeType.PESSIMISTIC_WRITE)`, `entityManager.find(..., LockModeType.PESSIMISTIC_WRITE)`, `@QueryHints(@QueryHint(name = "jakarta.persistence.lock.timeout", value = "3000"))`, QueryDSL `setLockMode`.
- 실패 시나리오: PostgreSQL에서 Hibernate 6.x는 `SELECT ... FOR UPDATE`, 7.0부터는 `SELECT ... FOR NO KEY UPDATE`로 보낸다. 7.x의 이 락도 다른 쓰기 락과는 충돌하지만, 자식 테이블 INSERT의 외래 키 검사가 거는 `FOR KEY SHARE`는 막지 않는다. 락은 트랜잭션이 끝날 때 풀린다. 트랜잭션 밖에서 부르면 `TransactionRequiredException`이 난다(Spring Data의 선언 쿼리 메서드는 기본으로 트랜잭션이 없다). 단 `findById` 같은 CRUD 메서드를 리포지토리에 다시 선언해 `@Lock`을 붙이면 SimpleJpaRepository의 읽기 전용 트랜잭션을 물려받아 예외 없이 실행되고, 락은 리포지토리 호출이 끝날 때 풀려 뒤따르는 갱신을 보호하지 못한다. 타임아웃 값 0은 `NOWAIT`, -2는 `SKIP LOCKED`가 된다. 양수 값은 Hibernate 7.1까지(Spring Boot 3.x와 4.0.0)의 PostgreSQL 방언에서 무시되어, PostgreSQL `lock_timeout` 기본값 0(제한 없음)대로 락이 풀릴 때까지 기다린다. Hibernate 7.2부터(Spring Boot 4.0.1 이상)는 양수 값을 쿼리 전에 `set local lock_timeout`으로 걸고 끝나면 되돌린다. 락을 쥔 채 외부 호출을 하면 같은 행을 쓰는 요청이 모두 그 시간만큼 기다린다.
- 문제가 아닌 경우: 서비스의 짧은 트랜잭션 안에서 잠그고 바로 갱신하는 경우. DB나 세션에 `lock_timeout`이나 `statement_timeout`이 이미 설정되어 무한 대기가 아닌 경우. 잠긴 행을 건너뛰려는 의도의 `SKIP LOCKED`.
- 고치는 방향: Hibernate 7.1까지는 대기 상한이 필요하면 같은 트랜잭션에서 `SET LOCAL lock_timeout`을 먼저 실행하거나 `NOWAIT`을 쓴다. 여러 행은 같은 순서로 잠근다. 락이 필요한 조회는 서비스의 `@Transactional` 안에서 부른다. 7.3부터(Spring Boot 4.1 이상) PostgreSQL에서는 락 타임아웃과 NOWAIT 실패가 항상 `LockTimeoutException` 대신 `PessimisticLockException`(PersistenceException 하위)으로 나온다. Spring이 번역한 `CannotAcquireLockException`을 잡는 코드는 영향이 없으므로, `jakarta.persistence.LockTimeoutException`을 직접 잡는 코드만 고친다.
- 출처: https://docs.hibernate.org/orm/6.6/userguide/html_single/#locking-LockMode, https://docs.hibernate.org/orm/6.6/userguide/html_single/#locking-jpa-query-hints, https://github.com/hibernate/hibernate-orm/blob/6.6/hibernate-core/src/main/java/org/hibernate/dialect/PostgreSQLDialect.java, https://github.com/hibernate/hibernate-orm/blob/7.2.0/hibernate-core/src/main/java/org/hibernate/dialect/lock/internal/PostgreSQLLockingSupport.java, https://github.com/hibernate/hibernate-orm/blob/7.2.0/hibernate-core/src/main/java/org/hibernate/sql/exec/internal/LockTimeoutHandler.java, https://jakarta.ee/specifications/persistence/3.2/jakarta-persistence-spec-3.2.html#a4385, https://docs.spring.io/spring-data/jpa/reference/jpa/transactions.html#transactional-query-methods, https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-LOCK-TIMEOUT, https://docs.hibernate.org/orm/7.3/migration-guide/#_timeout_exceptions_and_transaction_rollback, https://github.com/hibernate/hibernate-orm/blob/7.0.0/hibernate-core/src/main/java/org/hibernate/dialect/PostgreSQLDialect.java, https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-ROWS, https://github.com/hibernate/hibernate-orm/blob/7.4.15/hibernate-core/src/main/java/org/hibernate/internal/ExceptionConverterImpl.java, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-orm/src/main/java/org/springframework/orm/jpa/hibernate/HibernateExceptionTranslator.java, https://docs.spring.io/spring-data/jpa/reference/jpa/transactions.html

## 직접 할당한 ID와 save()의 merge

- 의심할 코드: `@GeneratedValue` 없이 애플리케이션이 ID를 정하는 엔티티(UUID, 외부 코드, 복합 키)를 `repository.save(new Member(id, ...))`나 `saveAll`로 새로 저장하는 코드. `Persistable`을 구현하지 않았고 wrapper 타입 `@Version`도 없는 엔티티.
- 실패 시나리오: Spring Data JPA는 version 속성이 없으면 ID가 null인지로 새 엔티티를 판단한다. 할당 ID는 늘 null이 아니므로 `persist` 대신 `merge`로 가고, Hibernate는 merge할 때 그 ID로 SELECT를 먼저 보낸다. 대량 저장이면 INSERT마다 SELECT가 하나씩 붙는다. 같은 ID의 행이 이미 있으면 merge가 그 행에 상태를 복사해 UPDATE하므로, 중복 생성이 오류 없이 덮어쓰기로 바뀐다.
- 문제가 아닌 경우: 엔티티가 `Persistable`을 구현해 `isNew()`로 새 엔티티를 알려 주는 경우. wrapper 타입(`Long`, `Integer`) `@Version` 필드가 있으면 version이 null인 새 인스턴스는 persist로 간다(primitive version은 판단에 쓰이지 않는다). 원래 수정 의도로 `save()`를 부르는 경우.
- 고치는 방향: `Persistable`을 구현하고 `@PostPersist`, `@PostLoad`에서 새 엔티티 표시를 끄는 Spring Data 문서의 패턴을 쓰거나, 새 엔티티는 `EntityManager.persist`로 저장한다.
- 출처: https://docs.spring.io/spring-data/jpa/reference/jpa/entity-persistence.html#jpa.entity-persistence.saving-entities, https://docs.spring.io/spring-data/jpa/reference/jpa/entity-persistence.html#jpa.entity-persistence.saving-entities.strategies, https://docs.hibernate.org/orm/7.1/userguide/html_single/#pc-merge

## IDENTITY 전략과 JDBC 배치 INSERT

- 의심할 코드: `@GeneratedValue(strategy = GenerationType.IDENTITY)` 엔티티를 `saveAll`이나 루프의 `persist`로 대량 저장하는 코드. 배치를 기대하고 `hibernate.jdbc.batch_size`를 설정했는데 ID 전략이 IDENTITY인 경우.
- 실패 시나리오: IDENTITY는 키를 DB가 INSERT 시점에 만들기 때문에 Hibernate가 `persist()` 즉시 INSERT를 실행하고, 이 엔티티의 INSERT를 JDBC 배치로 묶지 않는다. 만 건이면 INSERT 만 번이 각각 왕복한다. `hibernate.jdbc.batch_size` 기본값은 0이라 설정하지 않으면 SEQUENCE여도 배치가 없다.
- 문제가 아닌 경우: 요청 하나에 몇 건만 저장하는 흐름은 배치 이득이 없어 IDENTITY여도 지적하지 않는다(문서도 같은 판단이다). SEQUENCE 전략(숫자 ID의 `AUTO`는 Hibernate가 시퀀스로 해석한다)과 `batch_size`가 함께 설정되어 있으면 배치가 된다.
- 고치는 방향: 대량 INSERT 대상은 SEQUENCE와 `allocationSize`(JPA 기본 50)로 바꾸고 `spring.jpa.properties.hibernate.jdbc.batch_size`와 `hibernate.order_inserts`를 둔다. 키 전략을 바꿀 수 없으면 그 경로만 JDBC `batchUpdate`로 뺀다.
- 출처: https://docs.hibernate.org/orm/7.1/userguide/html_single/#identifiers-generators-identity, https://docs.hibernate.org/orm/7.1/userguide/html_single/#identifiers-generators-auto, https://docs.hibernate.org/orm/7.1/userguide/html_single/#batch-session-batch, https://docs.hibernate.org/orm/7.1/userguide/html_single/#settings-hibernate.jdbc.batch_size

## cascade와 orphanRemoval로 인한 삭제

- 의심할 코드: `@ManyToOne`이나 `@ManyToMany`에 붙은 `cascade = CascadeType.ALL` 또는 `REMOVE`. `orphanRemoval = true` 컬렉션에 `clear()`, `remove()`를 하거나 `setItems(newList)`로 컬렉션 참조를 바꾸는 코드. 자식을 다른 부모의 컬렉션으로 옮기는 코드.
- 실패 시나리오: orphanRemoval 컬렉션에서 빠진 자식은 flush 때 DELETE된다. 수정 API가 `items.clear()` 뒤 요청 목록으로 다시 채우면 기존 자식 행이 모두 지워지고 새 ID로 다시 들어가, 그 자식을 참조하던 행이나 이력이 끊긴다. 컬렉션 참조 자체를 새 리스트로 바꾸면 Hibernate가 `A collection with orphan deletion was no longer referenced by the owning entity instance` 예외를 던진다. `@ManyToMany`의 REMOVE cascade는 다른 엔티티도 참조하는 대상까지 지우려다 제약 조건 위반을 낸다. 명세는 REMOVE cascade를 `@OneToOne`, `@OneToMany`에만 쓰라고 하고, 고아가 된 엔티티를 다른 관계에 다시 연결하는 것을 이식성 없는 사용으로 본다.
- 문제가 아닌 경우: 자식이 부모에만 속하고(주문과 주문 항목처럼) 컬렉션에서 빠지면 지워지는 것이 요구사항인 경우. cascade가 PERSIST나 MERGE뿐인 경우. 아직 저장하지 않았거나 첫 flush 전인 새 엔티티에 생성자, 빌더, `setItems`로 컬렉션을 넣는 코드는 참조 교체 예외와 관계없다(예외는 DB에서 읽었거나 flush된 컬렉션의 참조를 바꿀 때만 난다).
- 고치는 방향: REMOVE cascade와 orphanRemoval은 부모가 소유하는 `@OneToMany`, `@OneToOne`에만 둔다. 컬렉션은 참조를 바꾸지 말고 기존 요소와 비교해 추가와 삭제만 반영한다.
- 출처: https://jakarta.ee/specifications/persistence/3.2/jakarta-persistence-spec-3.2.html#a516, https://docs.hibernate.org/orm/7.1/userguide/html_single/#pc-cascade-remove, https://docs.hibernate.org/orm/7.1/userguide/html_single/#associations-many-to-many, https://github.com/hibernate/hibernate-orm/blob/7.1/hibernate-core/src/main/java/org/hibernate/engine/internal/Collections.java

## 매핑과 스키마 불일치로 인한 validate 실패

- 의심할 코드: `spring.jpa.hibernate.ddl-auto=validate`(또는 `hibernate.hbm2ddl.auto=validate`)인 프로젝트에서 엔티티 필드 추가, `@Column(name)`, 필드 타입, `@Enumerated`, `@Table`, `@SequenceGenerator`를 바꾸면서 같은 변경에 마이그레이션이 없는 diff. Hibernate 버전을 올리는 빌드 파일 변경.
- 실패 시나리오: 시작할 때 Hibernate가 스키마를 검사해 `Schema-validation: missing table`, `missing column`, `wrong column type encountered`, `missing sequence`, `defined inconsistent increment-size`로 `SchemaManagementException`을 던지고 애플리케이션이 뜨지 않는다. 마이그레이션이 앱 시작보다 늦게 적용되는 배포라면 새 버전 인스턴스가 모두 시작에 실패한다. Hibernate 업그레이드만으로도 기본 타입 매핑이 바뀌어 같은 실패가 날 수 있다(마이그레이션 가이드가 6.1의 배열, 6.2의 `OffsetTime`과 일부 DB의 UUID, 6.5의 H2 enum을 예로 든다).
- 문제가 아닌 경우: `ddl-auto`가 `none`이면 시작 검사가 없다(임베디드 DB가 아니면 기본값이 none이다). 그래도 같은 불일치는 실행 중 SQL 오류로 나타나므로 마이그레이션 누락은 따로 본다. `@Transient` 필드. 검사기는 테이블과 칼럼의 존재, 칼럼 타입, 시퀀스만 보고 길이, NOT NULL, 인덱스는 보지 않으므로 그 차이로 시작 실패를 지적하지 않는다.
- 고치는 방향: 엔티티 변경과 같은 PR에 마이그레이션을 넣고 마이그레이션이 먼저 적용되게 한다. `@SequenceGenerator`의 `allocationSize`(기본 50)를 DB 시퀀스의 INCREMENT와 맞춘다.
- 출처: https://docs.hibernate.org/orm/7.1/userguide/html_single/#settings-hibernate.hbm2ddl.auto, https://github.com/hibernate/hibernate-orm/blob/7.1/hibernate-core/src/main/java/org/hibernate/tool/schema/internal/AbstractSchemaValidator.java, https://docs.spring.io/spring-boot/appendix/application-properties/index.html#application-properties.data.spring.jpa.hibernate.ddl-auto, https://docs.hibernate.org/orm/6.1/migration-guide/, https://docs.hibernate.org/orm/6.2/migration-guide/#ddl-changes, https://docs.hibernate.org/orm/6.5/migration-guide/, https://jakarta.ee/specifications/persistence/3.2/jakarta-persistence-spec-3.2.html#a16164

## 상한 없는 findAll과 결과 개수 제한

- 의심할 코드: `List`를 돌려주는 `findAll()`, `findAllBy...()`, `@Query` 메서드에 `Pageable`, `Limit`, `Top`이나 `First`가 없는 조회. 주문, 로그, 이력처럼 시간이 지나며 커지는 테이블 대상. 전체를 읽어 메모리에서 `filter`, `size()`로 세는 코드.
- 실패 시나리오: 결과 전체를 한 번에 메모리에 올린다. Spring Data 문서도 `List` 반환은 메모리를 소진할 수 있다고 적는다. 영속성 컨텍스트가 읽은 엔티티를 모두 강하게 참조해 GC되지 않고 flush 때 dirty check 대상도 늘어난다. 데이터가 적은 개발 환경에서는 드러나지 않는다.
- 문제가 아닌 경우: 행 수가 작게 고정된 코드성 테이블(국가 코드, 설정값). WHERE 조건이 고유 키나 소유자 ID로 결과 크기를 묶는 경우. 개수만 필요해서 `countBy`, `existsBy`를 쓰는 코드.
- 고치는 방향: `Pageable`, `Slice`, `Limit`(Spring Data 3.2 이상), `findTop100By...`로 상한을 둔다. 전체 처리가 필요하면 키셋 스크롤(`Window`)로 나눠 읽는다. `Stream`으로 받는 방식은 그것만으로 메모리가 묶이지 않는다. Hibernate의 fetch size 기본값은 0(드라이버 기본값)이고 PgJDBC는 이때나 autocommit일 때 결과 전체를 가져오며, 스트림으로 읽은 엔티티도 영속성 컨텍스트에 쌓인다. 그래서 트랜잭션 안에서 `org.hibernate.fetchSize` 힌트를 함께 주고, 처리한 엔티티를 `detach`하거나 주기적으로 `clear`하는 경우에만 해결로 본다. DTO 프로젝션으로 읽으면 영속성 컨텍스트 부담은 없다.
- 출처: https://docs.spring.io/spring-data/jpa/reference/repositories/query-methods-details.html#repositories.scrolling.guidance, https://docs.spring.io/spring-data/jpa/reference/repositories/query-methods-details.html#repositories.limit-query-result, https://docs.hibernate.org/orm/7.1/introduction/html_single/#persistence-contexts, https://docs.hibernate.org/orm/7.1/userguide/html_single/#settings-hibernate.jdbc.fetch_size, https://docs.hibernate.org/orm/7.1/userguide/html_single/#batch-session-scroll, https://jdbc.postgresql.org/documentation/query/#getting-results-based-on-a-cursor, https://docs.spring.io/spring-data/jpa/reference/jpa/query-methods.html#jpa.query-hints

## Page의 count 쿼리와 Slice

- 의심할 코드: 반환 타입이 `Page<T>`인 리포지토리 메서드, `findAll(Pageable)`, QueryDSL 결과로 직접 만든 `PageImpl`. 무한 스크롤이나 "더 보기"처럼 전체 개수를 쓰지 않는 API의 `Page`. 조인이나 group by가 많은 `@Query`에 `countQuery`가 없는 경우.
- 실패 시나리오: `Page`는 전체 개수를 알려고 본 쿼리와 별도로 count 쿼리를 보낸다. 큰 테이블에서는 count가 본 쿼리보다 비쌀 수 있고 페이지 요청마다 나간다. count 쿼리는 기본으로 본 쿼리에서 파생되므로, 복잡한 쿼리는 파생이 안 되거나 불필요한 조인을 그대로 가진다.
- 문제가 아닌 경우: 화면이 전체 개수나 마지막 페이지 번호를 실제로 쓰는 경우. Spring Data는 첫 페이지 결과가 페이지 크기보다 적은 경우처럼 결과만으로 전체 개수를 알 수 있으면 count 쿼리를 생략한다.
- 고치는 방향: 전체 개수가 필요 없으면 `Slice`(페이지 크기보다 1건 더 읽어 다음 여부만 판단)나 `Pageable`을 받는 `List` 반환을 쓴다. 복잡한 쿼리는 `@Query(countQuery = ...)`로 가벼운 count를 따로 준다.
- 출처: https://docs.spring.io/spring-data/jpa/reference/repositories/query-methods-details.html#repositories.special-parameters, https://docs.spring.io/spring-data/jpa/reference/repositories/query-methods-details.html#repositories.scrolling.guidance, https://docs.spring.io/spring-data/jpa/reference/jpa/query-methods.html#jpa.query-methods.query-introspection-rewriting, https://docs.spring.io/spring-data/commons/docs/current/api/org/springframework/data/support/PageableExecutionUtils.html

## QueryDSL의 fetch join 페이징과 fetchResults, fetchCount

- 의심할 코드: `JPAQuery`에서 `.leftJoin(order.items).fetchJoin()`과 `.offset()`, `.limit()`을 함께 쓰는 코드. `fetchResults()`, `fetchCount()` 호출.
- 실패 시나리오: QueryDSL JPA는 offset과 limit을 JPA 쿼리의 `setFirstResult`, `setMaxResults`로 넘기므로, 컬렉션 fetchJoin과 함께 쓰면 "컬렉션 fetch join과 페이징" 항목과 같다(Hibernate 7.3까지 메모리 페이징). `fetchResults()`와 `fetchCount()`는 QueryDSL 5.0에서 deprecated되었고, group by 식이 여러 개이거나 having이 있으면 count를 JPQL로 만들 수 없어 `fetch()` 결과의 크기로 센다. 이때 전체 행을 읽는다.
- 문제가 아닌 경우: fetchJoin 대상이 단일 연관뿐인 경우. group by와 having이 없는 단순 쿼리의 `fetchCount()`는 count 쿼리로 나가므로 성능 결함이 아니라 deprecated API 사용으로 Suggestion이다.
- 고치는 방향: 본문은 `fetch()`로, 개수는 `select(order.count())` 같은 count 쿼리를 따로 만들어 `fetchOne()`으로 구한다. 컬렉션이 필요한 페이징은 ID를 먼저 페이징해 가져온 뒤 컬렉션을 따로 조회한다.
- 출처: http://querydsl.com/static/querydsl/latest/reference/html/ch02.html#jpa_integration, https://github.com/querydsl/querydsl/releases/tag/QUERYDSL_5_0_0, https://github.com/querydsl/querydsl/blob/QUERYDSL_5_1_0/querydsl-jpa/src/main/java/com/querydsl/jpa/impl/AbstractJPAQuery.java

## Hibernate 6에서 7로 바뀐 동작

- 의심할 코드: Hibernate 7(Spring Boot 4)로 올리는 빌드 변경. 7 환경에서 `Session`의 `save`, `update`, `saveOrUpdate`, `delete`, `load` 호출, `CascadeType.SAVE_UPDATE`, detached 엔티티의 `refresh`나 `lock`, `StatelessSession` 배치, `getSingleResult`, `LockTimeoutException` catch, 네이티브 쿼리 결과를 `java.sql.Timestamp`로 캐스팅하는 코드.
- 실패 시나리오: 7.0에서 `save`, `update`, `saveOrUpdate`, `delete`, `load`가 제거되어 컴파일되지 않는다. `SAVE_UPDATE` 제거로 PERSIST cascade 연관이 detached 인스턴스를 가리키면 persist나 flush에서 `EntityExistsException`이 난다. detached 엔티티의 refresh와 lock은 `IllegalArgumentException`이 된다. `StatelessSession`은 `hibernate.jdbc.batch_size`를 무시한다. 결과 매핑이 없는 네이티브 쿼리의 날짜 값이 `java.time` 타입으로 바뀌어 `java.sql` 캐스팅이 깨진다. 7.3부터 `getSingleResult`는 결과 목록에 중복이 있어도 항상 예외를 던지고, DB가 트랜잭션을 롤백 대상으로 만든 락이나 쿼리 타임아웃은 `PersistenceException`으로 나온다. PostgreSQL은 모든 오류가 트랜잭션을 중단시키므로 늘 이 경우라, 락 타임아웃은 `PessimisticLockException`, 쿼리 타임아웃은 `PersistenceException`이 된다.
- 문제가 아닌 경우: Hibernate 6.x에서 도는 코드에는 7의 규칙을 적용하지 않는다. 컬렉션 fetch join 페이징(7.4에서 바뀜)과 PostgreSQL 락 타임아웃(7.2에서 바뀜)은 각 항목의 기준을 따른다.
- 고치는 방향: `persist`, `merge`, `remove`, `getReference`로 바꾸고, detached 인스턴스는 `merge`나 `getReference`로 얻은 관리 상태 참조로 연결한다. `StatelessSession` 배치는 `setJdbcBatchSize()`나 `insertMultiple()`을 쓴다. 네이티브 쿼리 날짜는 `java.time`으로 받거나 `hibernate.query.native.prefer_jdbc_datetime_types=true`를 둔다. 타임아웃은 Spring이 번역한 `CannotAcquireLockException`, `org.springframework.dao.QueryTimeoutException`을 잡는 코드라면 영향이 없고, JPA 예외 타입을 직접 잡는 코드만 고친다.
- 출처: https://docs.hibernate.org/orm/7.0/migration-guide/#session-save-update, https://docs.hibernate.org/orm/7.0/migration-guide/#flush-persist, https://docs.hibernate.org/orm/7.0/migration-guide/#refresh-lock-deteached, https://docs.hibernate.org/orm/7.0/migration-guide/#stateless-session-jdbc-batching, https://docs.hibernate.org/orm/7.0/migration-guide/#datetime-native, https://docs.hibernate.org/orm/7.3/migration-guide/#_result_deduplication, https://docs.hibernate.org/orm/7.3/migration-guide/#_timeout_exceptions_and_transaction_rollback, https://github.com/hibernate/hibernate-orm/blob/7.4.15/hibernate-core/src/main/java/org/hibernate/internal/ExceptionConverterImpl.java, https://github.com/spring-projects/spring-framework/blob/v7.1.0/spring-orm/src/main/java/org/springframework/orm/jpa/hibernate/HibernateExceptionTranslator.java
