[← Вступ до ECS](01-vstup-do-ecs.md) | [Зміст](README.md) | [Світ і сутності →](03-svit-sutnosti-zhyttievyi-tsykl.md)

---

# 2. Швидкий старт

---

## 2.1. Встановлення

Додайте пакет у свій `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/logdok/AegisECS.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "AegisECS", package: "AegisECS"),
        ]
    ),
]
```

Далі — `import AegisECS`. Це все: нічого вмикати не треба, немає списку
плагінів, немає налаштувань проєкту — Swift Package Manager сам розв'яже й
збере залежність, і кожен публічний тип модуля стає доступним одразу після
`import`.

Перевірка, що все стало на місце:

```bash
swift build
swift test
```

`swift test` запускає власний набір тестів пакета XCTest
(`Tests/AegisECSTests/*.swift`) на тому самому коді, від якого ви залежите —
придатно для CI як є.

### Про конфлікт імен

Типи Swift обмежені модулем, а не реєструються глобально, як у скриптових
мовах деяких рушіїв. `import AegisECS` вносить `World`, `System`,
`Scheduler`, `ComponentStore` та решту у видимість вашого файлу; якщо у
вашому застосунку вже є тип з такою самою назвою, розрізняйте їх повним
іменем `AegisECS.World`, а не перейменовуйте щось у бібліотеці.

### Два продукти, одна залежність

Пакет надає два продукти SwiftPM з однієї залежності:

| Продукт | Що всередині | Залежить від |
|---|---|---|
| `AegisECS` | Ядро (світ, сховища, системи, планувальник, `ReaperSystem`, `CapacityPolicySystem`), просторовий пошук, фіксований годинник, кутова математика та безголовий шар діагностики й відладки | нічого |
| `AegisECSInspectorUI` | SwiftUI-панель розробника, описана в [розділі 13](13-inspektor.md) | `AegisECS` |

Безголовий таргет — сервер, перевірка бюджету в CI — залежить лише від
звичайного `AegisECS` і ніколи не лінкує SwiftUI. Додавайте
`AegisECSInspectorUI` тільки там, де панель справді потрібно показувати.

---

## 2.2. Повний робочий приклад

Ось симуляція цілком. 500 частинок розлітаються з центру, ті, що вийшли за
межу, знищуються. Це працює як є — покладіть у `main.swift` виконуваного
таргету SwiftPM і запустіть.

```swift
import AegisECS

// --- 1. Сховище компонентів ---------------------------------------------------
// PackedStore генерує зберігання, зростання і перенесення даних при
// swap-remove для колонок, які ви оголошуєте; ви лише обираєте їхні типи.

final class Particles: PackedStore {
    init() { super.init(schema: [.float32, .float32, .float32, .float32]) } // x, y, vx, vy
    var x: UnsafeMutablePointer<Float> { columnF32(0)! }
    var y: UnsafeMutablePointer<Float> { columnF32(1)! }
    var vx: UnsafeMutablePointer<Float> { columnF32(2)! }
    var vy: UnsafeMutablePointer<Float> { columnF32(3)! }
}

// --- 2. Контекст --------------------------------------------------------------
// Бібліотека нічого не знає про ваш застосунок: вона просто передає цей
// об'єкт у setup(world:context:) кожної системи, нетипізованим. Тримайте
// тут посилання на сховища й спільний стан.

final class Context {
    let world: World
    let particles: Particles
    var escaped = 0
    init(world: World, particles: Particles) {
        self.world = world
        self.particles = particles
    }
}

// --- 3. Системи ---------------------------------------------------------------

final class MovementSystem: System {
    private var context: Context!

    override init() {
        super.init()
        systemName = "Movement"
        requiresTime = true          // не запускати на паузі
    }

    override func setup(world: World, context: Any?) {
        self.context = context as? Context
    }

    override func execute(delta: Float) {
        let p = context.particles
        let x = p.x, y = p.y, vx = p.vx, vy = p.vy
        for slot in 0..<Int(p.count) {
            x[slot] += vx[slot] * delta
            y[slot] += vy[slot] * delta
        }
    }
}

final class BoundsSystem: System {
    private var context: Context!

    override init() {
        super.init()
        systemName = "Bounds"
        requiresTime = true
    }

    override func setup(world: World, context: Any?) {
        self.context = context as? Context
    }

    override func execute(delta: Float) {
        let p = context.particles
        let x = p.x
        for slot in 0..<Int(p.count) {
            if abs(x[slot]) > 100.0 {
                // Тільки позначає. Сутність доживе до кінця кадру, тому
                // обхід не розсиплеться на ходу.
                context.world.queueDestroy(p.entityAt(Int32(slot)))
                context.escaped += 1
            }
        }
    }
}

// --- 4. Складання та запуск ---------------------------------------------------

enum ComponentType: Int32 { case particle }

let world = World(entityCapacity: 1000)          // початкова ємність

let particles = Particles()
world.registerStore(particles, typeID: ComponentType.particle.rawValue)

let context = Context(world: world, particles: particles)

// Порядок реєстрації = порядок виконання = поведінка.
let scheduler = Scheduler()
scheduler.addSystem(MovementSystem())
scheduler.addSystem(BoundsSystem())
scheduler.addSystem(ReaperSystem(world: world))   // завжди останній
scheduler.setupAll(world: world, context: context)

// Пакетне створення: один виклик замість 500.
var ids = [Entity](repeating: kInvalidEntity, count: 500)
let spawned = world.createEntities(500, into: &ids)

let firstSlot = Int(particles.count)
particles.attachMany(ids, count: spawned)

var seed: UInt64 = 12345
func nextRandom(_ lo: Float, _ hi: Float) -> Float {
    seed = seed &* 6364136223846793005 &+ 1
    return lo + (hi - lo) * Float(seed >> 40) / Float(1 << 24)
}
for i in 0..<Int(spawned) {
    let slot = firstSlot + i
    particles.x[slot] = 0
    particles.y[slot] = 0
    particles.vx[slot] = nextRandom(-40, 40)
    particles.vy[slot] = nextRandom(-40, 40)
}

for _ in 0..<600 {
    scheduler.executeAll(delta: 1.0 / 60.0)
}

print("залишилось: \(world.getLiveCount()), вилетіло: \(context.escaped)")
```

Запуск: `swift run` із пакета, де це оголошено як виконуваний таргет.

---

## 2.3. Розбір: що тут відбулося

### Крок 1 — сховище

```swift
final class Particles: PackedStore {
    init() { super.init(schema: [.float32, .float32, .float32, .float32]) }
    var x: UnsafeMutablePointer<Float> { columnF32(0)! }
    ...
}
```

`PackedStore` — рекомендована база для звичайних сховищ даних. Ви оголошуєте
схему з типів колонок і отримуєте типізовані покажчики за індексом. Все
інше — виділення пам'яті під ємність світу, зростання, перенесення даних при
swap-remove — робиться за вас.

Іменовані обчислювані властивості (`x`, `y`, `vx`, `vy`) — це тонка,
необов'язкова зручність над `columnF32(_:)`; сам покажчик стабільний **доки
не зросте ємність світу**, тож його безпечно прочитати один раз на початку
`execute(delta:)` системи й індексувати напряму в циклі, на повній
швидкості. **Плати за зручність немає.**

> Є й нижчий рівень — `ComponentStore`, де `reserveDense` і `relocateDense`
> пишуться руками. Він потрібен для екзотичних розкладок; для звичайних
> даних беріть `PackedStore`. Подробиці — у
> [розділі 4](04-komponenty-i-skhovyshcha.md).

### Крок 2 — контекст

Бібліотека **нічого не знає про ваш застосунок**. `System.setup(world:
context:)` отримує `context` як `Any?`, і саме там ви тримаєте посилання на
сховища — приведіть тип один раз, у `setup`, і зберігайте типізоване
посилання.

Це навмисно: завдяки цьому пакет переносний між застосунками без жодної
правки самої бібліотеки.

### Крок 3 — системи

Три речі, на які варто звернути увагу:

1. **`systemName`** задається в ініціалізаторі — воно потрапляє у
   профілювання і в [панель інспектора](13-inspektor.md).
2. **`requiresTime = true`** означає «не запускати мене, коли час стоїть».
   Пауза в цій бібліотеці — це крок нульової довжини, а не пропущений
   виклик, тож рендер та інші системи, незалежні від часу, продовжують
   працювати.
3. **Покажчики на колонки беруться один раз на виклик `execute`**, а не
   зберігаються між кадрами. Буфери під `PackedStore` можуть переїхати, коли
   зростає ємність світу (`CapacityPolicySystem`, або явний
   `world.reserveCapacity(_:)`), тож покажчик, утриманий через цю межу,
   протухає.

### Крок 4 — складання

```swift
scheduler.addSystem(MovementSystem())
scheduler.addSystem(BoundsSystem())
scheduler.addSystem(ReaperSystem(world: world))
```

`ReaperSystem` — це та сама «одна точка знищення» з
[розділу 1.7](01-vstup-do-ecs.md#17-чому-знищення-відкладене), оформлена як
готовий клас. **Ставте його останнім і рівно один раз** у конвеєрі.

### Пакетне створення

```swift
let spawned = world.createEntities(500, into: &ids)
let firstSlot = Int(particles.count)
particles.attachMany(ids, count: spawned)
```

`createEntities(_:into:)` і `attachMany(_:count:)` роблять за один виклик те,
на що інакше пішло б по 500 викликів кожен.

Слоти новоприкріплених компонентів ідуть підряд, починаючи зі значення
`count`, знятого **до** виклику, — тому дані можна писати одразу за індексом
`firstSlot + i`.

---

## 2.4. Кадр у реальному застосунку

У прикладі вище кадр крутиться в циклі `for`. `AegisECS` не має власного
run loop — ваш застосунок сам викликає `scheduler.executeAll(delta:)` один
раз за тік, з того місця, де вже живе його власний цикл: колбек рушія на
кадр, `CADisplayLink`, `Timer`, SwiftUI `TimelineView` або тік сервера.

```swift
final class GameLoop {
    let context: Context
    let scheduler: Scheduler
    var isPaused = false

    func tick(delta: Float) {
        let step = isPaused ? Float(0) : min(delta, 0.1)
        scheduler.executeAll(delta: step)
    }
}
```

Два зауваження:

- **Пауза — це `0`, а не пропуск виклику.** Системи з `requiresTime = true`
  планувальник пропустить сам, а рендер та все, що не оголосило
  `requiresTime`, працюватиме далі.
- **`min(delta, 0.1)`** обмежує крок: якщо застосунок завис на секунду, без
  цього обмеження всі об'єкти телепортуються. Для серйозної симуляції
  візьміть натомість `SimulationClock` — див.
  [розділ 7](07-chas-podii-yemnist.md).

---

## 2.5. Куди далі

- Не зрозуміло, чому сутність — це число, і що таке handle →
  [розділ 3](03-svit-sutnosti-zhyttievyi-tsykl.md)
- Потрібне сховище зі складнішими даними, або з ручним перенесенням →
  [розділ 4](04-komponenty-i-skhovyshcha.md)
- Треба обробляти не всі сутності, а лише з певним набором компонентів →
  [розділ 6](06-poshuk-sutnostei.md)
- Потрібно прискорювати або сповільнювати час без розсинхрону →
  [розділ 7](07-chas-podii-yemnist.md)
- Потрібно шукати сусідів («хто поруч») → [розділ 8](08-prostorovyi-poshuk.md)

---

[← Вступ до ECS](01-vstup-do-ecs.md) | [Зміст](README.md) | [Світ і сутності →](03-svit-sutnosti-zhyttievyi-tsykl.md)
