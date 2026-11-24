# Kotlin 참조

적용 버전: Kotlin 1.7 이상, Spring Boot 3.x와 4.x(Spring Framework 6.x, 7.x, Boot 4는 Kotlin 2.2 이상), jackson-module-kotlin 2.x(Jackson 2, Boot 3 기본)와 3.x(Jackson 3, Boot 4 기본). 버전에 따라 결론이 갈리는 곳은 항목 안에 적었다.

## kotlin-spring 플러그인과 프록시

- 의심할 코드: 빌드 파일에 `kotlin("plugin.spring")`(`org.jetbrains.kotlin.plugin.spring`)이나 all-open 설정이 없다. 플러그인은 있지만 메서드에만 `@Transactional`, `@Async`, `@Cacheable`이 붙은 클래스를 `@Bean` 메서드로 등록한다. 직접 `open class`로 열었지만 프록시가 필요한 메서드에 `open`이 없다.
- 실패 시나리오: Kotlin 클래스와 멤버 함수는 기본 final이다. kotlin-spring은 `@Component`, `@Async`, `@Transactional`, `@Cacheable`, `@SpringBootTest`가 붙은 클래스와 그 멤버를 열고, 메타 어노테이션도 보므로 `@Configuration`, `@Controller`, `@RestController`, `@Service`, `@Repository`도 열린다. 판단 기준은 클래스나 상위 클래스의 어노테이션이라서 메서드에만 어노테이션이 있는 클래스는 열리지 않는다. 열리지 않은 final 클래스는 CGLIB 프록시를 만들 수 없어 기동이 실패한다. 열린 클래스의 final 메서드는 프록시가 가로채지 못해 트랜잭션이나 캐시가 조용히 빠지고, 프록시 인스턴스의 초기화되지 않은 필드 때문에 NullPointerException이 날 수 있다.
- 문제가 아닌 경우: 플러그인이 적용되어 있고 클래스에 스테레오타입 어노테이션이나 클래스 수준 `@Transactional`이 있는 경우. 직접 `open class`와 `open fun`을 선언한 경우. `@Configuration(proxyBeanMethods = false)`는 CGLIB 프록시가 필요 없다.
- 고치는 방향: kotlin-spring 플러그인을 적용하고, 프록시가 필요한 클래스는 `@Bean` 메서드 대신 `@Component` 계열 어노테이션으로 등록한다(Spring 문서도 이 방식을 권한다).
- 출처: https://kotlinlang.org/docs/kotlin-spring-plugin.html, https://kotlinlang.org/docs/all-open-plugin.html, https://docs.spring.io/spring-framework/reference/languages/kotlin/spring-projects-in.html#final-by-default, https://github.com/spring-projects/spring-framework/blob/main/spring-aop/src/main/java/org/springframework/aop/framework/CglibAopProxy.java

## 엔티티 클래스가 final로 남는 경우

- 의심할 코드: JPA를 쓰는데 Kotlin이 2.3.20 미만이고 `allOpen { annotation("jakarta.persistence.Entity"); annotation("jakarta.persistence.MappedSuperclass"); annotation("jakarta.persistence.Embeddable") }` 설정이 없다. 그러면서 `@ManyToOne(fetch = FetchType.LAZY)`, `@OneToOne(fetch = FetchType.LAZY)`, `getReferenceById()`로 지연 로딩을 기대한다.
- 실패 시나리오: JPA 구현체는 엔티티의 하위 클래스 프록시로 지연 로딩을 하는데 Kotlin 클래스와 멤버는 기본 final이라 프록시를 만들 수 없다. Hibernate는 final 엔티티도 저장하지만 지연 연관에 프록시를 쓰지 못하고, Kotlin 문서는 이때 지연 연관이 즉시 로딩처럼 동작해 추가 쿼리가 나간다고 설명한다. kotlin-spring은 JPA 어노테이션을 열지 않고, Kotlin 2.3.20 미만의 `kotlin("plugin.jpa")`는 no-arg만 적용하고 all-open은 적용하지 않는다. 오류가 나지 않아 쿼리 수 증가로만 드러난다.
- 문제가 아닌 경우: Kotlin 2.3.20 이상에서 `kotlin("plugin.jpa")`를 쓰는 경우. 이 버전부터 JPA 플러그인이 all-open을 JPA 프리셋으로 자동 적용해 `javax`와 `jakarta`의 Entity, Embeddable, MappedSuperclass를 모두 연다. 엔티티를 직접 `open`으로 선언하고 매핑 프로퍼티도 `open`인 경우. Spring Boot 4의 최소 Kotlin은 2.2라서 Boot 4라는 이유만으로 자동 적용을 가정하지 말고 Kotlin 버전을 확인한다.
- 고치는 방향: Kotlin을 2.3.20 이상으로 올리거나, 그 미만이면 위 세 어노테이션을 allOpen에 등록한다.
- 출처: https://kotlinlang.org/docs/kotlin-jpa-plugin.html, https://kotlinlang.org/docs/whatsnew2320.html, https://docs.hibernate.org/orm/7.1/userguide/html_single/Hibernate_User_Guide.html#entity-pojo-final, https://docs.spring.io/spring-boot/reference/features/kotlin.html

## no-arg 생성자와 초기화 코드

- 의심할 코드: 엔티티의 인자 없는 생성자를 kotlin-jpa(no-arg) 플러그인에 맡기면서, 매핑되지 않은 필드의 초기값(`@Transient val cache = mutableMapOf<Long, Coupon>()`)이나 `init` 블록의 검증에 기대는 코드가 있다. no-arg 설정에 `invokeInitializers = true`가 없다.
- 실패 시나리오: no-arg 플러그인이 만든 생성자는 기본으로 클래스 초기화 코드를 실행하지 않는다. JPA는 이 생성자로 엔티티를 만들고 매핑된 필드만 채우므로, 조회한 엔티티의 매핑되지 않은 필드는 non-null 타입이어도 null로 남아 쓰는 순간 NullPointerException이 난다. `init` 블록의 검증도 조회한 엔티티에서는 실행되지 않는다.
- 문제가 아닌 경우: 초기값이 있는 필드가 모두 매핑된 컬럼이라 조회할 때 값이 채워지는 경우. `noArg { invokeInitializers = true }`를 켠 경우. 코드에서 주 생성자로 만든 엔티티(`Order(...)`)는 초기화 코드가 정상 실행된다.
- 고치는 방향: 매핑되지 않은 상태는 엔티티 밖으로 빼거나 nullable로 두고 접근할 때 초기화한다. 초기화 코드가 꼭 필요하면 `invokeInitializers = true`를 켠다.
- 출처: https://kotlinlang.org/docs/no-arg-plugin.html, https://kotlinlang.org/docs/kotlin-jpa-plugin.html, https://docs.hibernate.org/orm/7.1/userguide/html_single/Hibernate_User_Guide.html#entity-pojo-constructor

## data class 엔티티

- 의심할 코드: `@Entity`가 붙은 `data class`. 일반 클래스 엔티티라도 `equals`, `hashCode`, `toString`을 연관 필드까지 넣어 구현한다.
- 실패 시나리오: data class는 주 생성자의 모든 프로퍼티로 `equals`, `hashCode`, `toString`을 만든다. 지연 연관이 들어 있으면 로그 출력, Set 추가, 비교만으로 추가 쿼리가 나가고, 세션이 닫힌 뒤에는 LazyInitializationException이 난다. 양방향 연관이면 서로를 부르다 StackOverflowError가 난다. `@GeneratedValue` id가 들어간 `hashCode`는 저장 전후로 값이 바뀌어 저장 전에 넣은 HashSet에서 엔티티를 찾지 못한다. Kotlin 문서는 data class 엔티티가 프록시도 깨뜨린다고 적는다.
- 문제가 아닌 경우: 요청과 응답 DTO, 조회 결과 타입을 data class로 쓰는 것은 Kotlin 문서가 권하는 방식이다. 엔티티를 일반 클래스로 두고 id나 자연 키만으로 `equals`와 `hashCode`를 구현한 경우.
- 고치는 방향: 엔티티는 일반 클래스로 바꾸고, `equals`와 `hashCode`는 식별자와 타입(또는 자연 키)만으로 구현하며, `toString`에서 연관을 뺀다.
- 출처: https://kotlinlang.org/docs/kotlin-jpa-plugin.html, https://kotlinlang.org/docs/data-classes.html, https://docs.hibernate.org/orm/7.1/introduction/html_single/Hibernate_Introduction.html#equals-and-hash

## Kotlin에서 던지는 체크 예외와 롤백

- 의심할 코드: `@Transactional` 함수 안에서 JVM 기준 체크 예외(`IOException`, `Exception`을 상속한 직접 만든 예외)를 던지거나 그대로 전파한다. `class OrderException : Exception()`처럼 `RuntimeException`이 아닌 `Exception`을 상속한 도메인 예외.
- 실패 시나리오: Kotlin은 모든 예외를 unchecked로 다뤄 컴파일러가 알려 주지 않지만, Spring의 기본 롤백 규칙은 JVM 타입으로 판단해 RuntimeException과 Error만 롤백한다. `Exception`을 상속한 예외가 나가면 그 전까지의 변경이 커밋된다. 또 프록시를 거친 메서드에서 나간 체크 예외는 기본으로 UndeclaredThrowableException으로 감싸지므로, 호출 쪽의 `catch (e: OrderException)`이 잡지 못한다.
- 문제가 아닌 경우: 도메인 예외가 `RuntimeException`이나 그 하위를 상속한다. `@Transactional(rollbackFor = [Exception::class])`가 있다. Spring Framework 6.2 이상에서 `@EnableTransactionManagement(rollbackOn = RollbackOn.ALL_EXCEPTIONS)`를 설정했다(Spring 문서는 Kotlin 애플리케이션에 이 설정을 권한다). 체크 예외를 함수 안에서 잡아 런타임 예외로 바꾼다.
- 고치는 방향: 도메인 예외는 `RuntimeException`을 상속하게 하고, 라이브러리의 체크 예외는 잡아서 감싼다. 6.2 이상이면 ALL_EXCEPTIONS를 전역으로 켠다. 원래 예외 타입으로 받아야 하면 `@Throws(IOException::class)`를 붙인다.
- 출처: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html, https://docs.spring.io/spring-framework/reference/languages/kotlin/spring-projects-in.html#checked-exceptions, https://kotlinlang.org/docs/exceptions.html

## jackson-module-kotlin: 요청에서 빠진 non-null 필드

- 의심할 코드: 요청 DTO의 기본값 없는 non-null 프로퍼티. 특히 `Int`, `Long`, `Double`, `Boolean`처럼 JVM 기본형으로 컴파일되는 타입(`val quantity: Int`). 필드가 빠지면 400이 난다고 가정한 코드나 테스트.
- 실패 시나리오: `String`이나 객체 타입의 non-null 파라미터가 빠지거나 null이면 역직렬화 예외가 나고 Spring MVC는 HttpMessageNotReadableException으로 400을 응답한다(예외 타입은 모듈 2.20부터 KotlinInvalidNullException, 그 전은 MissingKotlinParameterException). 기본형은 다르다. Jackson 2의 기본값처럼 FAIL_ON_NULL_FOR_PRIMITIVES가 꺼져 있으면(Spring Boot 3 기본) 필드가 빠지거나 null이어도 예외 없이 0이나 false가 들어간다. Jackson 3은 이 기능이 기본으로 켜져 있어(Spring Boot 4 기본) 빠진 필드와 null 모두 예외가 난다.
- 문제가 아닌 경우: 빠졌을 때 0이나 false가 의도한 값인 경우. Jackson 2에서 `spring.jackson.deserialization.fail-on-null-for-primitives=true`를 켠 경우. Jackson 3을 쓰고 `spring.jackson.use-jackson2-defaults=true`(FAIL_ON_NULL_FOR_PRIMITIVES를 끈다)를 켜지 않은 경우. nullable 타입과 Bean Validation `@field:NotNull`로 따로 막는 경우.
- 고치는 방향: 필수 숫자와 불리언은 nullable 타입에 `@field:NotNull`을 붙이거나 FAIL_ON_NULL_FOR_PRIMITIVES를 켠다. 필드를 뺀 요청이 400이 되는지 테스트한다.
- 출처: https://github.com/FasterXML/jackson-module-kotlin/blob/2.x/README.md, https://github.com/FasterXML/jackson-module-kotlin/issues/242, https://github.com/FasterXML/jackson-module-kotlin/blob/2.x/src/main/kotlin/com/fasterxml/jackson/module/kotlin/KotlinAnnotationIntrospector.kt, https://github.com/FasterXML/jackson-module-kotlin/blob/3.x/src/main/kotlin/tools/jackson/module/kotlin/KotlinNamesAnnotationIntrospector.kt, https://github.com/FasterXML/jackson-module-kotlin/blob/2.20/src/main/kotlin/com/fasterxml/jackson/module/kotlin/Exceptions.kt, https://github.com/FasterXML/jackson-databind/blob/3.x/src/main/java/tools/jackson/databind/DeserializationFeature.java, https://github.com/spring-projects/spring-boot/blob/main/module/spring-boot-jackson/src/main/java/org/springframework/boot/jackson/autoconfigure/JacksonAutoConfiguration.java, https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/web/servlet/mvc/support/DefaultHandlerExceptionResolver.html

## jackson-module-kotlin: 기본값 파라미터와 nullable 조합

- 의심할 코드: 요청 DTO에서 기본값이 있는 non-null 파라미터(`val page: Int = 0`, `val status: OrderStatus = OrderStatus.CREATED`)와 nullable에 기본값을 준 파라미터(`val memo: String? = null`). 부분 수정 요청에서 "필드 없음"과 "null로 지움"을 구분해야 하는 코드.
- 실패 시나리오: 필드가 빠지면 기본값이 쓰인다. 하지만 클라이언트가 null을 명시해 보내면 기본값이 쓰이지 않는다. non-null 객체 타입이면 예외(400)가 나고, 기본형이면 FAIL_ON_NULL_FOR_PRIMITIVES가 꺼진 설정(Jackson 2 기본)에서 0이나 false가 들어간다. nullable에 기본값을 주면 빠질 때는 기본값, null을 보내면 null이 되며, `String? = null`이면 둘이 같은 값이 되어 구분할 수 없다.
- 문제가 아닌 경우: `KotlinFeature.NullIsSameAsDefault`를 켜 null을 빠진 것처럼 다루게 한 경우(기본값은 꺼짐). 클라이언트가 null을 보내지 않는다는 계약이 문서로 있는 경우. 빠짐과 null을 구분할 필요가 없는 필드.
- 고치는 방향: null을 받을 수 있는 필드는 nullable로 선언하고 기본값은 서비스에서 채운다. 빠짐과 null을 구분해야 하면 `JsonNode`나 `Map`으로 받아 키가 있는지 본다.
- 출처: https://github.com/FasterXML/jackson-module-kotlin/blob/2.x/src/main/kotlin/com/fasterxml/jackson/module/kotlin/KotlinFeature.kt, https://github.com/FasterXML/jackson-module-kotlin/blob/3.x/src/main/kotlin/tools/jackson/module/kotlin/KotlinValueInstantiator.kt, https://github.com/FasterXML/jackson-module-kotlin/blob/2.x/README.md

## jackson-module-kotlin: non-null 원소 컬렉션의 null

- 의심할 코드: `val memberIds: List<Long>`, `val tags: List<String>`, `Map<String, String>`처럼 원소가 non-null인 컬렉션 파라미터.
- 실패 시나리오: jackson-module-kotlin 2.x는 StrictNullChecks가 기본으로 꺼져 있어 `["a", null]`이 오면 `List<String>` 안에 null이 들어가고, 오류는 원소를 쓰는 곳에서 NullPointerException으로 난다. 3.x(Spring Boot 4 기본)는 StrictNullChecks가 기본으로 켜져 있어 역직렬화 단계에서 InvalidNullException이 나므로, 2.x에서 3.x로 올리면 null 원소를 보내던 요청이 400으로 바뀐다.
- 문제가 아닌 경우: 원소 타입을 nullable(`List<String?>`)로 선언하고 null을 처리한다. 2.x에서 `KotlinFeature.StrictNullChecks`를 켰다. 3.x에서 이 기능을 끄지 않았다.
- 고치는 방향: 2.x에서는 StrictNullChecks를 켜거나 원소를 검증한다. 3.x로 올릴 때는 null 원소를 보내는 클라이언트가 있는지 확인한다.
- 출처: https://github.com/FasterXML/jackson-module-kotlin/blob/2.x/src/main/kotlin/com/fasterxml/jackson/module/kotlin/KotlinFeature.kt, https://github.com/FasterXML/jackson-module-kotlin/blob/3.x/src/main/kotlin/tools/jackson/module/kotlin/KotlinFeature.kt, https://docs.spring.io/spring-boot/reference/features/json.html

## sealed 타입과 else 없는 when

- 의심할 코드: sealed class나 sealed interface를 주제로 한 `when`에 `else ->` 분기가 있다. sealed가 아닌 `open` 클래스나 인터페이스에 `is` 분기를 나열하고 `else`로 나머지를 처리한다.
- 실패 시나리오: sealed 타입의 직접 하위 타입은 같은 모듈과 패키지에만 둘 수 있어 컴파일러가 모두 안다. `else`가 있으면 새 하위 타입이 생겨도 컴파일 오류 없이 `else`로 가서 잘못 처리된다. sealed가 아닌 타입은 새 구현이 생겨도 컴파일러가 알려 주지 않는다.
- 문제가 아닌 경우: sealed 타입을 `else` 없이 모든 하위 타입으로 분기한 `when`은 새 하위 타입이 생기면 컴파일 오류가 나므로, 타입 분기라도 변경에 안전하다. 다형성으로 바꾸라고 지적하지 않는다. Kotlin 1.7부터 sealed, enum, Boolean을 주제로 한 `when`은 값을 쓰지 않는 문으로 써도 망라해야 하며 빠지면 컴파일 오류다(1.6은 경고). `else`가 "나머지는 모두 같은 처리"라는 의도로 분명하고 새 하위 타입에도 그 처리가 맞는 경우.
- 고치는 방향: sealed 주제의 `when`에서는 `else`를 빼고 하위 타입을 모두 나열한다. 하위 타입이 늘어날 분기 대상이면 sealed로 선언한다.
- 출처: https://kotlinlang.org/docs/sealed-classes.html, https://kotlinlang.org/docs/control-flow.html, https://kotlinlang.org/docs/compatibility-guide-17.html

## Kotlin null 여부와 DB 컬럼 제약 불일치

- 의심할 코드: 엔티티 프로퍼티의 Kotlin 타입과 컬럼 제약이 다르다. non-null 타입(`var memo: String`)인데 컬럼이 NULL을 허용하거나, 마이그레이션으로 nullable 컬럼을 추가했는데 엔티티는 non-null이다. nullable 타입(`var paidAt: Instant?`)인데 컬럼은 NOT NULL이다. NOT NULL을 `@Column(nullable = false)`로만 표시했다.
- 실패 시나리오: JPA는 엔티티를 채울 때 필드에 값을 직접 넣으므로 DB의 NULL이 non-null 프로퍼티에 그대로 들어가고, 오류는 그 값을 쓰는 곳에서 NullPointerException으로 늦게 난다(Kotlin의 런타임 null 검사는 공개 함수의 파라미터에 붙는다). nullable 프로퍼티를 null로 둔 채 저장하면 NOT NULL 위반이 flush나 커밋 때 DB 예외로 난다. `@Column(nullable = false)`는 스키마 생성에만 쓰이고, 저장 전 검사는 `@Basic(optional = false)`나 Bean Validation `@NotNull`이 한다.
- 문제가 아닌 경우: 타입과 제약이 맞고 non-null 컬럼에는 생성자 인자나 기본값으로 항상 값이 들어간다. `@GeneratedValue` id를 `var id: Long? = null`로 둔 것은 Kotlin 문서가 권하는 형태다.
- 고치는 방향: Kotlin 타입의 null 여부를 컬럼 제약과 맞추고 NOT NULL은 `@Basic(optional = false)`나 `@NotNull`로도 표시한다. nullable 컬럼을 추가하는 마이그레이션에서는 엔티티 타입도 nullable로 바꾼다.
- 출처: https://kotlinlang.org/docs/kotlin-jpa-plugin.html, https://kotlinlang.org/docs/java-to-kotlin-interop.html, https://docs.hibernate.org/orm/7.1/introduction/html_single/Hibernate_Introduction.html#basic-attributes

## 엔티티의 val 프로퍼티와 lateinit

- 의심할 코드: 엔티티의 매핑된 프로퍼티를 `val`로 선언한다. 필수 값이나 연관을 `lateinit var`로 선언하고 생성 뒤에 따로 채운다.
- 실패 시나리오: `val`은 final 필드로 컴파일되는데, JPA 명세(Hibernate 문서에 정리)는 영속 필드가 final이면 안 된다고 하고 Kotlin 문서도 JPA가 엔티티를 채울 때 필드에 값을 넣으므로 매핑 프로퍼티를 `var`로 두라고 한다. `lateinit` 프로퍼티는 값을 넣기 전에 읽으면 UninitializedPropertyAccessException이 나고, 값을 넣지 않은 채 저장하면 필드가 null이라 NULL로 저장되거나 NOT NULL 위반이 난다. `lateinit`은 기본형(`Int`, `Long`)에 쓸 수 없다.
- 문제가 아닌 경우: 매핑 프로퍼티를 `var`로 두고 `protected set`으로 외부 변경만 막은 경우. 엔티티가 아닌 DTO와 값 객체의 `val`. `lateinit`이 테스트 클래스의 주입 필드이거나, 생성 직후 같은 팩토리에서 반드시 채워진다.
- 고치는 방향: 매핑 프로퍼티는 `var`(필요하면 `protected set`)로 두고, 필수 값은 `lateinit` 대신 생성자 인자로 받는다.
- 출처: https://kotlinlang.org/docs/kotlin-jpa-plugin.html, https://kotlinlang.org/docs/reflection.html, https://kotlinlang.org/docs/properties.html, https://docs.hibernate.org/orm/7.1/userguide/html_single/Hibernate_User_Guide.html#entity-pojo
