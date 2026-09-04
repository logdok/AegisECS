[← Повний приклад](11-povnyi-pryklad.md) | [Зміст](README.md)

---

# 12. Довідник API

Повний перелік публічного API. Пояснення «чому так» — у відповідних розділах, з
доданими посиланнями.

---

## `World`

Розподільник ідентифікаторів і реєстр сховищ. Див.
[розділ 3](03-svit-sutnosti-zhyttievyi-tsykl.md).

### Константи

| Константа | Значення |
|---|---|
| `kInvalidEntity` | `-1` |
| `kInvalidHandle` | `0` |
| `kMaximumCapacity` | `16_777_216` (2²⁴ — максимум, який адресує розкладка handle) |

### Складання

| Член | Опис |
|---|---|
| `init(entityCapacity:)` | Задає ємність і одразу виділяє всі буфери |
| `registerStore(_:typeID:) -> Bool` | Реєструє сховище **до** першої сутності |
| `getStore(_ typeID:) -> ComponentStore?` | Пошук за типом. Для складання й діагностики, **не для гарячого циклу** |
| `hasStore(_:) -> Bool` | |
| `storeCount: Int32` | |
| `getStore(at:) -> ComponentStore?` | |
| `isSchemaLocked: Bool` | Чи вже створено сутності |

### Створення

| Член | Опис |
|---|---|
| `createEntity() -> Entity` | Новий id, або **`kInvalidEntity`**, якщо світ повний |
| `createEntities(_:into:capacity:) -> Int32` | Пакетно в сирий буфер; повертає скільки справді створено |
| `createEntities(_:into: inout [Entity]) -> Int32` | Пакетно в Swift-масив |
| `createEntityHandle() -> Handle` | Створити й одразу отримати handle |

### Handle

| Член | Опис |
|---|---|
| `makeHandle(_:) -> Handle` | Безпечне посилання, що переживає кадри |
| `entityFromHandle(_:) -> Entity` | Розв'язати, або `kInvalidEntity` |
| `isHandleAlive(_:) -> Bool` | |
| `getGeneration(_:) -> Int32` | |
| `tag: Int32` | Тег цього світу, унікальний у межах процесу |
| `queueDestroyHandle(_:) -> Bool` | |
| `isHandlePendingDestroy(_:) -> Bool` | |

### Знищення

| Член | Опис |
|---|---|
| `queueDestroy(_:) -> Bool` | Позначити. Ідемпотентно |
| `queueDestroyMany(_:count:) -> Int32` | Пакетно; повертає скільки щойно додано в чергу |
| `flushDestroyQueue() -> Int32` | **Структурна точка синхронізації.** Рівно в одному місці кадру |
| `isPendingDestroy(_:) -> Bool` | |
| `isAlive(_:) -> Bool` | З перевіркою меж |

### Ємність і скидання

| Член | Опис |
|---|---|
| `reserveCapacity(_:) -> Bool` | Явний бар'єр, що алокує. `false`, якщо якесь сховище не підтримує зростання |
| `reset()` | Очищає світ **без алокацій**; робить недійсними всі handle |
| `capacity: Int32` | Поточна ємність (тільки читання) |

### Діагностика

| Член | Опис |
|---|---|
| `getLiveCount()` / `getFreeCount()` / `getRetiredCount()` | |
| `getPendingDestroyCount()` | |
| `getLoadFactor() -> Float` | `live / capacity`, у межах `0...1` |
| `structuralVersion: Int64` | Монотонний лічильник структурних змін |
| `validateIntegrity(reportErrors:) -> Bool` | Повна перевірка. **Не для продакшн-кадру** |
| `clearChangeLogs()` | Очищає журнали всіх сховищ, де вони ввімкнені |

---

## `ComponentStore`

Абстрактне sparse-set сховище (`open class`, успадковується). Див.
[розділ 4](04-komponenty-i-skhovyshcha.md).

### Публічні поля

| Поле | Опис |
|---|---|
| `typeID: Int32` | Ідентифікатор типу, під яким зареєстровано |
| `debugName: String` | Опційна назва для інструментів; типово `"type N"` |
| `sparseIndex: ContiguousArray<Int32>` | `entity → слот`, або -1. **Лише читання ззовні** |
| `denseEntities: ContiguousArray<Int32>` | `слот → entity`. **Лише читання ззовні** |
| `count: Int32` | Кількість компонентів = довжина щільного масиву |
| `structuralVersion: Int64` | Змінюється лише коли міняється склад/розкладка |

### Журнал змін ([розділ 7.2](07-chas-podii-yemnist.md))

| Член | Опис |
|---|---|
| `trackChanges: Bool` | Увімкнути журнал. За замовчуванням `false` |
| `addedEntities`, `addedCount` | Дійсний префікс `0..<addedCount` |
| `removedEntities`, `removedCount` | Дійсний префікс `0..<removedCount` |
| `changeLogOverflowed: Bool` | `clear()`/`World.reset()` не логували видалення поелементно |
| `clearChangeLog()` | Очистити обидва журнали |

### Операції

| Член | Опис |
|---|---|
| `attach(_:) -> Int32` | Прикріпити; ідемпотентно; -1 при переповненні |
| `attachMany(_:count:) -> Int32` | Пакетно; нові слоти йдуть підряд від старого `count` |
| `detach(_:)` | Безпечно, навіть якщо компонента немає |
| `detachMany(_:count:) -> Int32` | Пакетно за списком жертв |
| `detachFlagged(_:) -> Int32` | Пакетно за байтовими прапорцями; мінімум переміщень |
| `has(_:) -> Bool` | **Без перевірки меж**, `@inline(__always)` |
| `indexOf(_:) -> Int32` | Слот або -1. **Без перевірки меж**, `@inline(__always)` |
| `entityAt(_:) -> Entity` | **Без перевірки меж**, `@inline(__always)` |
| `clear()` | Спорожнити без алокацій |
| `getDebugName() -> String` | Назва для інструментів; `debugName`, потім `"type N"` |
| `capacity: Int32` | |
| `isInitialized: Bool` | |
| `supportsCapacityGrowth: Bool` | Чи оголошено `.growDense` |
| `validateIntegrity(alive:aliveSize:reportErrors:) -> Bool` | Перевірка бієкції sparse↔dense |

### Обов'язкові перевизначення

| Метод | Опис |
|---|---|
| `reserveDense(_:)` | Виділити масиви корисного навантаження |
| `relocateDense(from:to:)` | Перенести дані при swap-remove |

### `Hooks` (`OptionSet`) — опційні перевизначення

Оголошуються перевизначенням `var hooks: Hooks`. Базовий клас не реалізує
жодного з них і викликає відповідне перевизначення лише коли встановлено біт —
неоголошений хук коштує одну перевірку біта, ніколи виклику.

| Біт | Вмикає | Перевизначення |
|---|---|---|
| `.growDense` | `World.reserveCapacity()` | `growDense(previousCapacity:newCapacity:)` |
| `.relocateBatch` | Пакетне перенесення | `relocateDenseBatch(from:to:moveCount:)` |
| `.releaseDense` | Звільнення володіння перед перезаписом | `releaseDense(_:)` |
| `.clearRelocated` | Очистити дублікат, що лишився після переміщення | `clearRelocatedDense(_:)` |
| `.clearDense` | Масове очищення на `clear()` | `clearDense(activeCount:)` |

---

## `PackedStore`

`final class PackedStore: ComponentStore` — декларативне сховище. Реалізує
`reserveDense`, `growDense`, `relocateDense` і `relocateDenseBatch` узагальнено,
на основі схеми `ColumnType`. Див. [розділ 4](04-komponenty-i-skhovyshcha.md).

| Член | Опис |
|---|---|
| `init(schema: [ColumnType])` | По одному запису на колонку, по порядку |
| `columnCount: Int32` | |
| `columnType(_:) -> ColumnType?` | |
| `columnData(_:) -> UnsafeMutableRawPointer?` | Сирий базовий покажчик колонки |
| `columnF32/columnF64/columnI32/columnI64/columnU8(_:) -> UnsafeMutablePointer<T>?` | Типізовані акцесори; `nil` при невідповідності індексу чи типу |
| `clearSlot(_:)` | Занулити всі колонки в щільному слоті |

`ColumnType`: `.uint8`, `.int32`, `.int64`, `.float32`, `.float64`, `.vec2`
(2×f32), `.vec3` (3×f32), `.vec4` (4×f32, це також форма кольору).

> Покажчик колонки дійсний **лише до наступного зростання ємності світу**
> (`World.reserveCapacity()`) — не кешуйте його між кадрами чи через
> зростання. Див. правило безпеки в розділі 4.

---

## `TagStore`

`final class TagStore: ComponentStore` — компонент-маркер без даних. Весь API
успадкований від `ComponentStore`; `detachMany`/`detachFlagged` перевизначені
спеціалізованими версіями, що взагалі не виконують переміщень — переносити
нічого.

---

## `View`

Перетин сховищ без матеріалізації. Див. [розділ 6](06-poshuk-sutnostei.md).

| Член | Опис |
|---|---|
| `configure(world:required:excluded:ownerSystem:) -> Bool` | Холодна операція, одноразово |
| `refreshDriver()` | Обрати найменше з обов'язкових сховищ |
| `candidateStore: ComponentStore?` | Сховище-драйвер |
| `candidateCount: Int32` | |
| `driverRequiredIndex: Int32` | Індекс драйвера серед обов'язкових |
| `matches(_:) -> Bool` | Перевірка належності — реальний виклик на кандидата |
| `requiredCount` / `requiredStore(_:)` / `requiredSparse(_:)` | |
| `excludedCount` / `excludedStore(_:)` / `excludedSparse(_:)` | |
| `isConfigured: Bool` | |
| `validateOwnerAccess(reportErrors:) -> Bool` | Перевірка метаданих проти оголошеного доступу системи-власника |

---

## `Query`

Матеріалізований кеш поверх `View`. Див. [розділ 6](06-poshuk-sutnostei.md).

| Член | Опис |
|---|---|
| `configure(world:required:excluded:ownerSystem:maximumResults:) -> Bool` | `maximumResults: -1` = завбільшки зі світ |
| `refresh() -> Bool` | `true`, якщо кеш перебудовано |
| `isCurrent: Bool` | Чи кеш актуальний, без перебудови |
| `count: Int32` | Розмір результату |
| `entityAt(_:) -> Entity` | |
| `withEntities<R>(_:) -> R` | Безпечний unchecked-доступ до дійсного префіксу `0..<count` |
| `resultCapacity: Int32` | |
| `isTruncated: Bool` | Знайдено більше, ніж вміщує буфер |
| `rebuildCountValue: Int32` | Скільки разів перебудовано |
| `underlyingView: View` | |
| `validateOwnerAccess(reportErrors:) -> Bool` | |

---

## `System`

`open class System`, успадковується. Одиниця логіки. Див.
[розділ 5](05-systemy-i-planuvalnyk.md).

| Член | Опис |
|---|---|
| `systemName: String` | Задається в `init()`; показується в профілюванні |
| `systemPhase: Int32` | Фіксується після `addSystem()` |
| `enabled: Bool` | Рантайм-перемикач |
| `requiresTime: Bool` | `true` → планувальник пропускає систему при `delta <= 0` |
| `readComponentTypes` / `writeComponentTypes` / `structuralWriteComponentTypes` | Метадані |
| `writesWorldStructure: Bool` | `create`/`destroy`/`reset` |
| `accessMetadataComplete: Bool` | |

| Метод | Опис |
|---|---|
| `setup(world:context:)` | Одноразово, коли все готове. Тут кешуйте посилання |
| `execute(delta:)` | Раз на кадр |
| `teardown()` | У зворотному порядку реєстрації |
| `declareRead(_:)` / `declareWrite(_:)` / `declareStructuralWrite(_:)` | Ланцюжкові, `@discardableResult` |
| `hasDeclaredAccess(_:) -> Bool` | |
| `completeAccessMetadata()` | Підтвердити, що опис завершено |

---

## `Scheduler`

Див. [розділ 5](05-systemy-i-planuvalnyk.md).

| Член | Опис |
|---|---|
| `addSystem(_:phase:) -> System` | Порядок реєстрації = порядок виконання |
| `setupAll(world:context:) -> Bool` | |
| `teardownAll()` | У зворотному порядку |
| `executeAll(delta:)` | Весь конвеєр |
| `beginFrame()` | Закрити заміри попереднього кадру |
| `executePhase(_:delta:)` | Одна фаза; заміри **накопичуються** до наступного `beginFrame()` |
| `setSystemEnabled(_:_:)` / `isSystemEnabled(_:)` | |
| `setPhaseEnabled(_:_:)` / `isPhaseEnabled(_:)` | |
| `isPhaseAllowed(_:) -> Bool` | Чи дозволяє фазу системі виконуватися |
| `systemCount: Int32` / `getSystemName(_:)` / `getSystem(_:)` / `getSystemPhase(_:)` | |
| `findSystem(_:) -> Int32` | Індекс або -1 |
| `wasSystemExecuted(_:) -> Bool` | |
| `getTimingUsec(_:) -> Float` | Останній кадр |
| `getAverageTimingUsec(_:) -> Float` | Згладжено; вага `Scheduler.averageSmoothing = 0.1` |
| `getTotalTimingUsec() -> Float` | |
| `resetProfiling()` | |
| `profilingEnabled: Bool` | Вимкнути замір |
| `validatePipeline(world:reportErrors:) -> Bool` | |
| `systemsConflict(_:_:) -> Bool` | Консервативний аналіз залежностей |

---

## `ReaperSystem`

`final class ReaperSystem: System`. Єдина точка знищення. Реєструйте
**останньою**.

| Член | Опис |
|---|---|
| `init(world:name:)` | Типово: `world: nil`, `name: "Reaper"` |
| `lastReaped: Int32` | Знищено цього кадру |
| `totalReaped: Int64` | Знищено загалом |

Свідомо має `requiresTime == false`: чергу треба спорожняти навіть на паузі.

---

## `CapacityPolicySystem`

`final class CapacityPolicySystem: System`. Автоматичне зростання світу.
Реєструйте **одразу після жнеця**.

| Член | Опис |
|---|---|
| `init(world:name:)` | Типово: `world: nil`, `name: "CapacityPolicy"` |
| `growThreshold: Float` | Частка заповнення для зростання. `0.85` за замовчуванням |
| `growthFactor: Float` | Множник нової ємності. `1.5` за замовчуванням |
| `maximumCapacity: Int32` | Стеля; `0` = без додаткового ліміту |
| `checkIntervalFrames: Int32` | `30` за замовчуванням |
| `onCapacityGrown: ((Int32, Int32) -> Void)?` | `(previous, new)` після зростання |
| `growNow() -> Bool` | Форсувати, ігноруючи інтервал |
| `growthCount`, `lastGrowthCapacity` | Діагностика |

---

## `SimulationClock`

Фіксований крок і масштаб часу. Див. [розділ 7](07-chas-podii-yemnist.md).

| Член | Опис |
|---|---|
| `advance(realDelta:) -> Int32` | Скільки суб-кроків виконати. **Рівно раз на кадр** |
| `fixedStep: Float` | Довжина відрізка симуляції |
| `timeScale: Float` | `0` = стоп, `1` = реальний час |
| `maxSubsteps: Int32` | Запобіжник проти «спіралі смерті». `8` за замовчуванням |
| `paused: Bool` | Заморозити без втрати акумулятора |
| `getLastSubsteps() -> Int32` | |
| `getAlpha() -> Float` | Частка невитраченого відрізка, для інтерполяції |
| `isSaturated() -> Bool` | Чи впирається в `maxSubsteps` |
| `getEffectiveTimeScale(realDelta:) -> Float` | Фактична швидкість |
| `elapsedSimulated: Float` | Точна сума, без дрейфу |
| `totalSubsteps: Int64`, `droppedSubsteps: Int64` | |
| `reset()` | |

---

## `UniformSpatialGrid`

Broadphase на основі counting sort. Див. [розділ 8](08-prostorovyi-poshuk.md).

| Константа | Значення |
|---|---|
| `UniformSpatialGrid.maxQueryResults` | `2048` |

| Член | Опис |
|---|---|
| `configure(arenaRadius:verticalExtent:cellSize:entryCapacity:)` | `verticalExtent: 0` → плаский режим |
| `static suggestCellSize(arenaRadius:verticalExtent:expectedEntries:typicalQueryRadius:) -> Float` | Обґрунтована відправна точка |
| `rebuild(entityIDs:points:entryCount:)` | Повна перебудова (перевантаження для сирих покажчиків або `[Int32]`/`[SIMDVector3]`) |
| `queryNearest(center:radius:) -> Int32` | Найближчий id, або -1. Без алокацій |
| `querySphere(center:radius:resultLimit:) -> Int` | Кількість; id — у `queryBuffer` |
| `getCellStart(_:)` / `getCellEnd(_:)` | Межі комірки у відсортованих масивах |
| `getEntryCount()` / `getCellCount()` / `getCellSize()` | |
| `getDimensions() -> (Int, Int, Int)` | Комірок по осі; `y == 1` у пласкому режимі |
| `isFlat() -> Bool` | |

| Поле | Опис |
|---|---|
| `queryBuffer: ContiguousArray<Int32>` | Результат останнього `querySphere`. **Перезаписується наступним запитом** |
| `queryPointBuffer: ContiguousArray<SIMDVector3>` | Позиції; заповнюється лише коли `storeQueryPoints == true` |
| `storeQueryPoints: Bool` | `false` за замовчуванням |
| `sortedEntities`, `sortedPoints` | Відсортовані за коміркою. **Лише читання** |

`SIMDVector3` — власний value-тип бібліотеки: `struct SIMDVector3 { var x, y, z: Float }`.

---

## `AngleMath`

Вільні функції, незалежні від ECS. Скрізь радіани.

| Метод | Опис |
|---|---|
| `static wrap(_:_:_:) -> Float` | Загорнути значення у `[min, max)` |
| `static approach(_:_:_:) -> Float` | Довернути `current` до `desired` максимум на `maxStep`, коротким шляхом |
| `static shortestDelta(_:_:) -> Float` | Абсолютна найкоротша кутова відстань, завжди невід'ємна |

---

## `Entity`, `Handle` і помилки

| Символ | Опис |
|---|---|
| `typealias Entity = Int32` | Сирий щільний індекс; нестабільний через структурну зміну |
| `typealias Handle = Int64` | Generation + world tag + entity id; безпечний між кадрами |
| `kInvalidEntity: Entity` | `-1` |
| `kInvalidHandle: Handle` | `0` |
| `kMaximumCapacity: Int32` | `16_777_216` |
| `AegisDiagnostics.setErrorHandler(_:)` | Встановити власний приймач для повідомлень бібліотеки; `nil` повертає stderr |

Бібліотека ніколи не кидає винятків і не падає на некоректному використанні:
вона звітує через `AegisDiagnostics` і повертає значення-вартовий (`-1`,
`false`, `nil`) замість цього.

---

## Відладкова частина

Повністю описана в [розділі 13](13-inspektor.md). `AegisECS` (весь цей
довідник) містить усе, крім панелі; `AegisECSInspectorUI` — окремий
бібліотечний продукт, що додає лише `InspectorPanelView`.

### `Inspector`

Єдина точка підключення.

| Член | Опис |
|---|---|
| `static attach(scheduler:world:options:) -> Inspector` | Ніколи не повертає опціонал |
| `capture()` | **Останнім рядком кадру.** Також заміряє настінний час |
| `refreshNow()` | Негайно перерахувати агрегати й діагностику |
| `addCounterSection(_:provider:)` | Лічильники застосунку |
| `registerQuery(_:_:)` / `registerGrid(_:_:)` / `setClock(_:)` | Обʼєкти для діагностики |
| `getFindings() -> [Diagnostics.Finding]` | Знахідки, найгірші першими |
| `printReport()` | Текстовий звіт у консоль |
| `detach()` | Зупинити збір; встановлює `mode = .off` |
| `mode: Inspector.Mode` | `.off` / `.telemetry` / `.inspector` / `.dev` |
| `statsRefreshHz`, `diagnosticsRefreshHz` | Частоти перерахунку |
| `recorder`, `stats`, `diagnostics` | Прямий доступ до частин |
| `getWorld()` / `getScheduler()` / `getClock()` / `getQueries()` / `getGrids()` | |

`Inspector.Options`: `mode`, `frames`, `budgetUsec`, `clock`, `queries`, `grids`.

### `FrameRecorder`

Кільцевий буфер кадрів. Нічого не алокує після `configure()`.

| Член | Опис |
|---|---|
| `configure(scheduler:world:frames:) -> Bool` | `frames` типово `FrameRecorder.defaultFrameCapacity` (240) |
| `capture(substeps:wallFrameUsec:)` | |
| `clear()` | Забути вікно без переалокації |
| `frameCount` / `framesSeenCount` | |
| `newestSlot` / `oldestSlot` / `slotInOrder(_:)` / `slotFromNewest(age:)` | |
| `frameTotalUsec(_:)` / `frameWallUsec(_:)` / `frameSubstepsCount(_:)` | |
| `frameLiveCount(_:)` / `framePendingDestroy(_:)` / `frameStructuralDelta(_:)` | |
| `timingUsec(slot:system:)` / `status(slot:system:)` | |
| `systemName(_:)` / `systemPhase(_:)` / `systemRequiresTime(_:)` | |
| `lastCaptureUsec` / `memoryUsage()` | Вартість спостереження |
| `Status` | `.executed` / `.skippedPaused` / `.disabled` / `.phaseOff` |

### `FrameStats`

| Член | Опис |
|---|---|
| `analyse(_:) -> Bool` | Холодний шлях: сортує вікно |
| `frameMedianUsec()` / `frameP95Usec()` / `frameMaxUsec()` / `frameAverageUsec()` | |
| `worstFrameSlot() -> Int` | Слот найгіршого кадру |
| `spikeFrameCount()` / `spikeRatio()` | Чи бувають ривки |
| `systemMedianUsec(_:)` / `systemP95Usec(_:)` / `systemMaxUsec(_:)` | |
| `systemSharePercent(_:)` | Частка від часу ECS |
| `systemVolatility(_:)` | `max / median` — хто дає ривки |
| `systemExcessShare(_:)` | Частка в надлишку повільних кадрів |
| `spikeContributor(_ rank:)` / `spikeContributorCount()` | Ранжування винуватців |
| `liveMin()` / `liveMax()` / `capacityChangeCount()` / `peakPendingDestroy()` | |
| `spikeFactor`, `highPercentile` | Налаштування |

### `Diagnostics`

| Член | Опис |
|---|---|
| `inspect(recorder:stats:world:extras:) -> [Finding]` | Знахідки, найгірші першими |
| `reset()` | Забути лічильники перебудов запитів |
| `frameBudgetUsec`, `volatilityWarning`, `loadFactorWarning`, `storeFillWarning`, `spikeRatioWarning`, `dominantSharePercent`, `excessShareWarning` | Пороги |
| `Diagnostics.Finding` | `severity`, `source`, `title`, `detail`, `hint`, `formatted()` |
| `Diagnostics.Extras` | `clock`, `queries`, `grids` — передається в `inspect()` |

### `Report`

| Метод | Опис |
|---|---|
| `static text(recorder:stats:world:findings:) -> String` | Повний звіт, готовий для консолі чи тікета |

Це скорочений порт: пооб'єктні JSON/CSV-записувачі оригіналу не включені —
напишіть свій поверх публічних акцесорів `FrameRecorder` і `FrameStats`, якщо
він вам потрібен.

---

[← Повний приклад](11-povnyi-pryklad.md) | [Зміст](README.md) | [Інспектор →](13-inspektor.md)
