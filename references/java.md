# Java 참조

적용 버전: Java 17 이상(패턴 매칭 switch는 Java 21), Spring Boot 3.x와 4.x(Spring Framework 6.x, 7.x, Hibernate 6.x, 7.x), Lombok 1.18.x. 버전에 따라 결론이 갈리는 곳은 항목 안에 적었다.

## Lombok @Data, @EqualsAndHashCode, @ToString 엔티티

- 의심할 코드: `@Entity` 클래스에 `@Data`, `@EqualsAndHashCode`, `@ToString`이 붙어 있고 `@EqualsAndHashCode.Exclude`, `@ToString.Exclude`, `onlyExplicitlyIncluded = true`로 연관 필드를 빼지 않았다.
- 실패 시나리오: `@Data`는 `@ToString`, `@EqualsAndHashCode`, 모든 필드의 getter, final이 아닌 모든 필드의 setter, `@RequiredArgsConstructor`를 한꺼번에 만든다(직접 작성한 생성자가 있으면 생성자는 만들지 않는다). final 필드나 `@NonNull` 필드가 있는 엔티티면 인자 있는 생성자만 생겨 인자 없는 생성자가 없어지고, JPA가 엔티티를 만들지 못한다. `@EqualsAndHashCode`는 static과 transient가 아닌 모든 필드를 쓰고 `@ToString`은 static이 아닌 모든 필드를 출력한다. 지연 연관이 들어 있으면 로그 출력, HashSet 추가, 비교만으로 추가 쿼리가 나가거나 세션이 닫힌 뒤 LazyInitializationException이 나고, 양방향 연관이면 서로를 부르다 StackOverflowError가 난다. `@GeneratedValue` id나 바뀌는 필드가 `hashCode`에 들어가면 저장이나 수정 뒤 HashSet에서 엔티티를 찾지 못한다. `@Data`의 setter는 id와 연관 컬렉션까지 외부에 연다.
- 문제가 아닌 경우: 엔티티에 `@Getter`만 쓰는 경우. `@EqualsAndHashCode(onlyExplicitlyIncluded = true)`로 자연 키만 포함하고 `@ToString`에서 연관을 뺀 경우. 연관이 없는 엔티티의 `@ToString`. DTO에 `@Data`를 쓰는 것은 이 항목의 대상이 아니다.
- 고치는 방향: 엔티티에는 `@Getter`와 필요한 변경 메서드만 둔다. `equals`와 `hashCode`는 자연 키나 식별자 기준으로 직접 구현하고(Hibernate 문서는 프록시 때문에 `getClass()` 대신 `instanceof`로 타입을 비교한다), `toString`에서 연관을 뺀다.
- 출처: https://projectlombok.org/features/Data, https://projectlombok.org/features/EqualsAndHashCode, https://projectlombok.org/features/ToString, https://docs.hibernate.org/orm/7.1/introduction/html_single/Hibernate_Introduction.html#equals-and-hash, https://docs.hibernate.org/orm/7.1/introduction/html_single/Hibernate_Introduction.html#proxies-and-lazy-fetching, https://docs.hibernate.org/orm/7.1/userguide/html_single/Hibernate_User_Guide.html#mapping-model-pojo-equalshashcode

## Lombok @Builder와 엔티티 생성자

- 의심할 코드: 엔티티 클래스에 `@Builder`가 붙어 있는데 초기값이 있는 필드(`private List<OrderLine> lines = new ArrayList<>();`, `private OrderStatus status = OrderStatus.CREATED;`)에 `@Builder.Default`가 없다. `@Builder.Default`가 있는 엔티티에 직접 작성한 생성자가 있다. 인자 없는 생성자가 없다.
- 실패 시나리오: 빌더에서 설정하지 않은 필드는 필드 초기값과 상관없이 0, null, false가 된다. 빌더로 만든 주문의 `lines`가 null이라 `add`에서 NullPointerException이 나거나 상태 컬럼이 null로 저장되어 NOT NULL 위반이 난다. `@Builder.Default`를 붙이면 초기값이 필드에서 빠져 정적 메서드로 옮겨지므로, Lombok이 만든 생성자는 초기값을 쓰지만 직접 작성한 생성자는 초기값을 넣지 않는다. 클래스의 `@Builder`는 다른 생성자가 없을 때만 패키지 전용 전체 인자 생성자를 만들므로 `@Builder`만 있으면 JPA와 Hibernate가 요구하는 인자 없는 생성자가 없다.
- 문제가 아닌 경우: 초기값이 필요한 필드에 모두 `@Builder.Default`가 있고 직접 작성한 생성자가 없다. `@Builder`를 필요한 인자만 받는 생성자에 붙이고 JPA용으로 `@NoArgsConstructor(access = AccessLevel.PROTECTED)`를 따로 둔다. 클래스에 `@Builder`, `@NoArgsConstructor`, `@AllArgsConstructor`를 함께 둔다. `@NoArgsConstructor`를 두면서 전체 인자 생성자를 만들지 않으면 컴파일이 실패하므로 빌드에서 걸러진다.
- 고치는 방향: 초기값이 있는 필드에 `@Builder.Default`를 붙이고, 직접 작성한 생성자에서는 초기값을 직접 넣는다. 또는 빌더를 생성자에 붙이고 `protected` 인자 없는 생성자를 둔다.
- 출처: https://projectlombok.org/features/Builder, https://docs.hibernate.org/orm/7.1/introduction/html_single/Hibernate_Introduction.html#entity-clases, https://docs.hibernate.org/orm/7.1/userguide/html_single/Hibernate_User_Guide.html#entity-pojo-constructor

## record DTO와 record 엔티티

- 의심할 코드: `@Entity`가 붙은 `record`. 반대로 요청과 응답 DTO, 조회 전용 프로젝션, `@Embeddable` 값을 record로 바꾼 변경을 JPA와 맞지 않는다며 지적하려는 경우.
- 실패 시나리오: record는 암묵적으로 final이고 컴포넌트 필드도 final이며 인자 없는 생성자가 없다. JPA 엔티티는 final이 아닌 클래스, final이 아닌 영속 필드, 인자 없는 생성자가 필요하므로 record는 엔티티가 될 수 없다.
- 문제가 아닌 경우: 요청과 응답 DTO로 쓰는 record(Jackson 2.12부터 record를 읽고 쓴다). JPQL `select new`나 결과 타입 지정으로 조회 결과를 담는 record. `@Embeddable` 값이나 복합 키로 쓰는 record(Hibernate 6.2 이상 문서가 다루며 인자 없는 생성자 요구가 완화된다). 이때 볼 것은 하나뿐이다. record로 조회한 값은 관리되는 엔티티가 아니므로 값을 바꿔도 DB에 반영되지 않는다.
- 고치는 방향: 엔티티는 일반 클래스로 두고, 값 묶음은 `@Embeddable` record로, 조회 결과와 API 모델은 record DTO로 둔다.
- 출처: https://docs.oracle.com/en/java/javase/21/language/records.html, https://docs.hibernate.org/orm/7.1/userguide/html_single/Hibernate_User_Guide.html#entity-pojo, https://docs.hibernate.org/orm/7.1/introduction/html_single/Hibernate_Introduction.html#embeddable-objects, https://docs.hibernate.org/orm/6.2/introduction/html_single/Hibernate_Introduction.html#embeddable-objects, https://docs.hibernate.org/orm/7.1/querylanguage/html_single/Hibernate_Query_Language.html#select-new, https://github.com/FasterXML/jackson/wiki/Jackson-Release-2.12

## sealed 인터페이스와 패턴 매칭 switch

- 의심할 코드: sealed 인터페이스나 클래스를 대상으로 한 `switch`에 `default`가 있다. sealed가 아닌 타입에 `instanceof` 사슬이나 `case Type t` 분기를 두고 `default`로 나머지를 처리한다. enum을 대상으로 상수 라벨만 쓰는 `switch` 문(식이 아닌 문)에 `default`가 없다.
- 실패 시나리오: `default`가 있으면 새 permitted 하위 타입이 생겨도 컴파일 오류 없이 `default`로 가서 잘못 처리된다. sealed가 아닌 타입은 새 구현이 생겨도 컴파일러가 알려 주지 않는다. 상수 라벨만 쓰는 enum `switch` 문은 호환성 때문에 망라 검사를 받지 않으므로, 새 enum 상수가 생기면 오류 없이 어느 분기도 타지 않는다.
- 문제가 아닌 경우: 패턴이나 null 라벨을 쓰는 switch(Java 21)와 모든 switch 식은 망라해야 하므로, sealed 타입을 `default` 없이 모든 하위 타입으로 분기하면 새 하위 타입이 생길 때 컴파일 오류가 난다. 이런 switch는 타입 분기라도 변경에 안전하므로 다형성으로 바꾸라고 지적하지 않는다. `default`가 "나머지는 같은 처리"라는 의도로 분명한 경우. enum의 일부 상수만 처리하고 나머지는 무시하는 것이 의도이며 이름이나 주석으로 드러나는 switch 문(이벤트 종류별 부수 효과 등). enum 상수 라벨 switch 문은 새 상수를 반드시 처리해야 하는 분기일 때만 지적한다. 다만 sealed 계층만 다시 컴파일하고 switch가 든 클래스를 다시 컴파일하지 않으면 실행 중 MatchException이 나므로, sealed 타입을 별도 모듈이나 라이브러리로 배포하는 경우는 이 점을 본다.
- 고치는 방향: sealed 타입 분기에서는 `default`를 빼고 하위 타입을 모두 나열한다. enum 분기는 switch 식(`return switch (status) { ... };`)으로 바꾸면 망라 검사를 받는다.
- 출처: https://docs.oracle.com/en/java/javase/21/language/pattern-matching-switch.html, https://docs.oracle.com/javase/specs/jls/se21/html/jls-14.html#jls-14.11.2, https://docs.oracle.com/javase/specs/jls/se21/html/jls-15.html#jls-15.28.1, https://docs.oracle.com/en/java/javase/21/language/sealed-classes-and-interfaces.html

## 체크 예외를 던지는 서비스 메서드

- 의심할 코드: `@Transactional` 서비스 메서드에 `throws Exception`, `throws IOException`, `throws OrderException`(`Exception`을 상속한 직접 만든 예외)이 선언되어 있는데 `rollbackFor`가 없다. 클래스에는 `@Transactional(rollbackFor = Exception.class)`가 있지만 메서드에 따로 `@Transactional`을 붙이면서 `rollbackFor`를 빠뜨렸다.
- 실패 시나리오: 기본 롤백 규칙은 RuntimeException과 Error만 롤백하고 체크 예외는 커밋한다. 예외 직전까지의 변경이 커밋되어 호출자는 실패로 처리하지만 DB에는 일부가 남는다. 메서드에 붙인 `@Transactional`은 클래스 수준 설정보다 우선하므로, 클래스의 `rollbackFor`는 그 메서드에 적용되지 않는다.
- 문제가 아닌 경우: 체크 예외를 던져도 그때까지의 변경을 커밋하는 것이 의도인 경우. `rollbackFor`가 그 예외 타입이나 상위 타입을 포함하는 경우(타입 규칙은 하위 클래스까지 맞는다). Spring Framework 6.2 이상에서 `@EnableTransactionManagement(rollbackOn = RollbackOn.ALL_EXCEPTIONS)`를 설정한 경우. 체크 예외를 메서드 안에서 잡아 런타임 예외로 감싸 던지는 경우.
- 고치는 방향: 도메인 예외는 `RuntimeException`을 상속하게 하거나, `rollbackFor = Exception.class`를 메서드마다 명시하거나, 6.2 이상이면 ALL_EXCEPTIONS를 전역으로 켠다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/rolling-back.html, https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/annotation/RollbackOn.html
