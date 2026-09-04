[← Типові помилки](10-typovi-pomylky.md) | [Зміст](README.md) | [Довідник API →](12-dovidnyk-api.md)

---

# 11. Повний приклад: колонія в чашці Петрі

Цей розділ розбирає одну показову симуляцію, зібрану так, щоб задіяти
**все**, що описано в попередніх розділах. Це навчальний приклад, наведений
повністю нижче, — а не скрипт, що постачається в цьому репозиторії, як
`colony_example.gd` в оригінальному GDScript-аддоні; покладіть його у власну
виконувану ціль чи одноразовий `XCTestCase`, якщо хочете справді його
запустити.

Клітини блукають, витрачають енергію, відштовхують одна одну, діляться, коли
ситі, і гинуть, коли голодні.

| Що використано | Навіщо воно тут |
|---|---|
| `PackedStore` | корисне навантаження без шаблонного коду |
| `TagStore` | ознака «готова ділитися» без даних |
| `UniformSpatialGrid` | «хто поруч», у пласкому режимі |
| `SimulationClock` | прискорення часу без розсинхронізації |
| журнал змін | реакція на народження й смерть |
| `CapacityPolicySystem` | популяція може подвоюватися за секунди |
| `ReaperSystem` | єдина точка знищення |
| фази | суб-кроки симуляції проти роботи раз на кадр |

Правдоподібний запуск виглядає так:

```
grid: cellSize=6.00, cells=441, flat=true
seeded 200 cells

frame  population  births  deaths  capacity
    0         200     200       0       512
   60         584     584       0      1024
  120        1210    1210       0      2048
  180        1416    1418       2      2048
  240        1401    1474      73      2048
  300        1332    1533     201      2048

--- result ---
simulated 48.0 s of colony time in 360 rendered frames (timeScale 8)
population 1322, peak 1440, births 1600, deaths 278
capacity grew 2 times, now 2048
dropped substeps: 0
```

Зростання → ємність зростає двічі → насичення зі смертністю →
стабілізація. Жодного відкинутого суб-кроку.

---

## 11.1. Компоненти

```swift
enum ComponentType: Int32 {
    case cell, dividing
}

final class ColonyCellStore: PackedStore {
    private enum Column: Int32 {
        case position, heading, energy, age, crowding
    }

    init() {
        super.init(schema: [.vec3, .float32, .float32, .float32, .float32])
    }

    var position: UnsafeMutablePointer<SIMDVector3> {
        columnData(Column.position.rawValue)!.assumingMemoryBound(to: SIMDVector3.self)
    }
    var heading: UnsafeMutablePointer<Float> { columnF32(Column.heading.rawValue)! }
    var energy: UnsafeMutablePointer<Float> { columnF32(Column.energy.rawValue)! }
    var age: UnsafeMutablePointer<Float> { columnF32(Column.age.rawValue)! }
    var crowding: UnsafeMutablePointer<Float> { columnF32(Column.crowding.rawValue)! }
}

let cells = ColonyCellStore()
let dividing = TagStore()
world.registerStore(cells, typeID: ComponentType.cell.rawValue)
world.registerStore(dividing, typeID: ComponentType.dividing.rawValue)
```

**Чому все в одному сховищі.** Ці п'ять колонок читаються **разом**, щокроку,
одними й тими самими системами. Розбити їх на п'ять сховищ означало б додати
чотири пошуки в `sparseIndex` до найгарячішого циклу — і нічого не виграти
(розділ 4).

**Чому `crowding` — колонка, а не обчислення на льоту.** Просторовий запит
дорогий. Система руху вже запитує сітку про сусідів, тож вона записує їхню
кількість; система метаболізму просто читає число. **Дорога операція
сплачується рівно один раз.** Це типова й дуже вигідна техніка в ECS: одна
система готує дані для іншої через компонент.

**Чому тег, а не колонка `Bool`.** Тег дає системі поділу **щільний список
рівно тих клітин, що готові** — `dividing.count` і `dividing.denseEntities`.
З колонкою `Bool` довелося б сканувати всі ~1400 клітин, щоб знайти
дюжину готових.

Обчислювані властивості підкласу (`position`, `heading`, ...) щоразу заново
резолвлять свій базовий покажчик — дешевий пошук покажчика, не пошук за
значенням, — тож вони лишаються коректними навіть після зростання ємності без
жодної дисципліни кешування з боку викликача (правило про час життя покажчика
з розділу 4).

---

## 11.2. Порядок систем — і чому він саме такий

```swift
enum Phase: Int32 {
    case simulation, statistics
}

scheduler.addSystem(ColonyMovementSystem(),      phase: Phase.simulation.rawValue)
scheduler.addSystem(ColonySpatialIndexSystem(),  phase: Phase.simulation.rawValue)
scheduler.addSystem(ColonyMetabolismSystem(),    phase: Phase.simulation.rawValue)
scheduler.addSystem(ColonyDivisionSystem(),      phase: Phase.simulation.rawValue)
scheduler.addSystem(ReaperSystem(world: world),  phase: Phase.simulation.rawValue)
scheduler.addSystem(policy,                      phase: Phase.simulation.rawValue)
scheduler.addSystem(ColonyStatisticsSystem(),    phase: Phase.statistics.rawValue)
```

Читайте цей список як алгоритм — саме ним він і є:

1. **Movement** — усі рухнулись і дізналися власну crowding.
2. **SpatialIndex** — індекс перебудовується з **нових** позицій. Якби він
   стояв до руху, кожен запит наступного кроку працював би із застарілими
   даними.
3. **Metabolism** — витрата енергії залежить від crowding, щойно виміряної
   кроком 1. Позначає голодних на знищення, ситих — тегом.
4. **Division** — ділить позначених.
5. **Reaper** — **єдина точка знищення**, і вона остання серед тих, що
   торкаються складу світу.
6. **CapacityPolicy** — одразу після жнеця, бо зростання переалоковує всі
   буфери й вимагає, щоб ніхто не тримав щільний слот чи закешований покажчик
   колонки.
7. **Statistics** — після жнеця, щоб бачити і народження, і смерті цього
   кроку.

---

## 11.3. Просторовий запит усередині циклу руху

```swift
final class ColonyMovementSystem: System {
    let cells: ColonyCellStore
    let grid: UniformSpatialGrid

    init(cells: ColonyCellStore, grid: UniformSpatialGrid) {
        self.cells = cells
        self.grid = grid
        super.init()
        systemName = "Movement"
        _ = declareRead(ComponentType.cell.rawValue).declareWrite(ComponentType.cell.rawValue)
            .completeAccessMetadata()
    }

    override func execute(delta: Float) {
        let position = cells.position, heading = cells.heading
        let energy = cells.energy, crowding = cells.crowding

        for slot in 0..<Int(cells.count) {
            let me = cells.entityAt(Int32(slot))
            let point = position[slot]
            let neighbours = grid.querySphere(center: point, radius: crowdRadius, resultLimit: maxNeighbours)
            crowding[slot] = Float(max(neighbours - 1, 0))

            if neighbours > 1 {
                var away = SIMDVector3(0, 0, 0)
                for i in 0..<neighbours {
                    if grid.queryBuffer[i] == me { continue }   // це я
                    let other = grid.queryPointBuffer[i]
                    away = SIMDVector3(away.x + point.x - other.x, 0, away.z + point.z - other.z)
                }
                if away.x * away.x + away.z * away.z > 0.0001 {
                    let desired = atan2(away.x, away.z)
                    heading[slot] = AngleMath.approach(heading[slot], desired, 4.0 * delta)
                }
            }

            position[slot] = SIMDVector3(point.x + sin(heading[slot]) * speed * delta, 0,
                                          point.z + cos(heading[slot]) * speed * delta)
        }
    }
}
```

Три речі, вартi уваги:

- **`grid.storeQueryPoints = true`** вмикається один раз при конфігурації
  сітки, і тоді `grid.queryPointBuffer` повертає позиції разом з
  ідентифікаторами з `grid.queryBuffer`. Без цього довелося б повертатися в
  сховище через `cells.indexOf(_:)` для кожного сусіда.
- **Себе треба відфільтрувати явно** — сітка не знає, хто питає.
- **`maxNeighbours` (тут 16)** обмежує роботу в найгустіших місцях. Клітині в
  тисняві не потрібні всі сусіди, щоб зрозуміти, куди відштовхуватися.

---

## 11.4. Поділ: створення сутностей посеред кадру

```swift
final class ColonyDivisionSystem: System {
    let cells: ColonyCellStore
    let dividing: TagStore
    var spawnBuffer: [Entity]

    override func execute(delta: Float) {
        let parents = min(Int(dividing.count), spawnBuffer.count)
        guard parents > 0 else { return }
        let born = Int(world.createEntities(Int32(parents), into: &spawnBuffer))
        guard born > 0 else { return }

        let firstSlot = cells.count
        cells.attachMany(spawnBuffer, count: Int32(born))

        for i in 0..<born {
            let parent = dividing.entityAt(Int32(i))
            let parentSlot = cells.indexOf(parent)
            guard parentSlot != -1 else { continue }
            let childSlot = Int(firstSlot) + i
            cells.position[childSlot] = cells.position[Int(parentSlot)]
            cells.energy[childSlot] = cells.energy[Int(parentSlot)] * 0.5
            cells.energy[Int(parentSlot)] *= 0.5
        }

        dividing.clear()
    }
}
```

> **Чому створювати сутності посеред кадру безпечно, а знищувати — ні.**
>
> `attach()`/`attachMany()` лише **додають у кінець** щільного масиву. Вони
> нічого не переносять, тож жоден уже отриманий слот не псується, і цикл, що
> вже виконується, не втрачає своє місце.
>
> `detach()`, навпаки, робить **swap-remove** — переносить останній елемент у
> звільнений слот. Саме тому знищення відкладається (через `queueDestroy` +
> `ReaperSystem`), а створення — ні.

Слоти дочірніх клітин ідуть підряд від `firstSlot`, прочитаного **до**
`attachMany()`. Це і є контракт, що робить пакетний спавн зручним.

`dividing.clear()` спорожняє тег **без алокацій** — заповнює `sparseIndex`
значенням -1 і обнуляє `count`. Значно дешевше, ніж викликати `detach()` для
кожної клітини окремо.

---

## 11.5. Фіксований крок

```swift
let clock = SimulationClock()
clock.fixedStep = 1.0 / 30.0
clock.timeScale = 8.0
clock.maxSubsteps = 12
```

```swift
for _ in 0..<360 {
    let frameDelta: Float = 1.0 / 60.0
    let substeps = clock.advance(realDelta: frameDelta)

    scheduler.beginFrame()
    for _ in 0..<substeps {
        scheduler.executePhase(Phase.simulation.rawValue, delta: clock.fixedStep)
    }
    scheduler.executePhase(Phase.statistics.rawValue, delta: frameDelta)
}
```

При `timeScale = 8` і кадрі 1/60 накопичується 8/60 с — це **чотири** кроки по
1/30. Фаза симуляції виконується чотири рази, фаза статистики — один.

Без фіксованого кроку крок симуляції становив би 8/60 ≈ 0.133 с, і клітина з
порогом поділу `age >= 1.0` перетинала б його нерівномірно, залежно від
частоти кадрів. З фіксованим кроком результат **відтворюваний**: та сама
послідовність насіння дає ту саму колонію на будь-якій машині.

`droppedSubsteps == 0` наприкінці підтверджує, що запобіжник жодного разу не
спрацював — машина встигає при `timeScale = 8`.

---

## 11.6. Журнал змін замість подій

```swift
cells.trackChanges = true
```

```swift
final class ColonyStatisticsSystem: System {
    let world: World
    let cells: ColonyCellStore
    var births = 0
    var deaths = 0
    var peakPopulation: Int32 = 0

    override func execute(delta: Float) {
        births += Int(cells.addedCount)
        deaths += Int(cells.removedCount)
        peakPopulation = max(peakPopulation, world.getLiveCount())
        world.clearChangeLogs()
    }
}
```

Система стоїть **після жнеця** (і після поділу, який теж іде до жнеця в цьому
конвеєрі), тож у цей момент `addedCount` містить усіх народжених цього кроку,
а `removedCount` — усіх, хто помер. Прочитавши журнал, вона його очищає.

У реальній грі саме тут спрацював би звук смерті, частинки чи оновлення UI.

---

## 11.7. Зростання ємності

```swift
policy.onCapacityGrown = { previous, next in
    context.resizeScratch(to: next)
    context.grid.configure(arenaRadius: dishRadius, verticalExtent: 0, cellSize: cellSize, entryCapacity: Int(next))
}
```

Це найважливіший рядок усього прикладу з погляду типових помилок.

**Бібліотека вирощує тільки власні буфери.** Все, що застосунок виділив поряд
— скретч-масиви для індексу, саму сітку, батч рендера, мережевий буфер — треба
вирощувати самостійно. Забути про це означає, що після зростання світу індекс
будується лише з перших N клітин, а решта стають невидимими для пошуку
сусідів. Помилки при цьому не буде.

У прикладі виводу вище колбек спрацював двічі: 512 → 1024 → 2048.

---

## 11.8. Що міг би показати профіль

Підключіть `Inspector` (розділ 13), і показова таблиця систем одного кадру
могла б виглядати так:

```
Movement          13743      ← 82% кадру
SpatialIndex       1417
Metabolism          612
Division             10
Reaper               11
CapacityPolicy        1
Statistics            3
```

Movement з'їдає більшість. Це очікувано: система робить **просторовий запит на
клітину на суб-крок** — приблизно 1300 клітин × 4 кроки ≈ 5200 запитів на
кадр.

Якби це потребувало оптимізації, порядок дій такий (розділ 9):

1. **Не робити роботу.** Оновлювати crowding не щокроку, а раз на 4 кроки —
   клітини не встигають відійти достатньо далеко, щоб це мало значення частіше.
2. **Параметри.** Зменшити `maxNeighbours` з 16 до 6.
3. **Менше сутностей.** Запитувати лише клітини, близькі до порогу поділу.
4. **І лише тоді** — мікрооптимізація самого циклу.

Профіль тут не вказує на `Division` чи `Metabolism`, хоч би якими складними
вони виглядали в коді. У цьому й суть: **вимірюйте, а не вгадуйте**.

---

## 11.9. Що спробувати самостійно

Цей приклад — зручний майданчик. Кілька вправ:

1. **Хижаки.** Додайте другий «тип» клітин (власний тег чи сховище) і тег
   `predator`. Хижак знаходить найближчу здобич через
   `grid.queryNearest(center:radius:)`, переслідує й з'їдає її (`queueDestroy`
   + приріст власної енергії). Куди в список систем ви поставите полювання?
2. **Ділянки їжі.** Замініть постійну швидкість харчування на другий
   `UniformSpatialGrid` з поживними ділянками. Який `cellSize` йому потрібен
   для 30 ділянок проти 1300 клітин? (Підказка: розділ 8, про вибір
   `cellSize`.)
3. **Мутації.** Додайте колонку `divisionThreshold` і передавайте дочірній
   клітині значення батьківської ± трохи шуму. Поверніться за кілька хвилин і
   подивіться, яке значення перемогло.
4. **Прискорення.** Встановіть `timeScale = 100`. Що показує
   `droppedSubsteps`? Що зміниться, якщо підняти `maxSubsteps` до 40?
5. **Пауза.** Додайте систему, орієнтовану на рендер, без `requiresTime =
   true`, і перевірте, що вона й далі працює на паузі (`delta == 0`), а фаза
   симуляції (чиї системи оголошують `requiresTime = true`) стоїть на місці.

---

## Головне з розділу

1. Тримайте разом те, що читається разом; сплачуйте за дорогий запит один раз
   і зберігайте результат у компоненті.
2. Тег дає щільний список кандидатів — дешевше за прапорець у сховищі.
3. **Створювати** сутності посеред кадру безпечно (додавання);
   **знищувати** — ні (swap-remove) — саме ця асиметрія і є причиною, чому
   знищення йде через відкладену чергу, а створення — ні.
4. Фіксований крок робить симуляцію відтворюваною за будь-якого прискорення.
5. При зростанні ємності **власні буфери — ваша відповідальність** —
   `World.reserveCapacity()` (тут — через `CapacityPolicySystem`) вирощує
   тільки те, чим володіє сама бібліотека.
6. Профайлер каже, що оптимізувати. Інтуїція — ні.

---

[← Типові помилки](10-typovi-pomylky.md) | [Зміст](README.md) | [Довідник API →](12-dovidnyk-api.md)
