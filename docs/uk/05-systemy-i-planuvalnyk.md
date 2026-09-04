[← Компоненти](04-komponenty-i-skhovyshcha.md) | [Зміст](README.md) | [Пошук сутностей →](06-poshuk-sutnostei.md)

---

# 5. Системи і планувальник

---

## 5.1. Анатомія системи

```swift
final class MovementSystem: System {
    private var context: Context!      // ваш власний клас

    override init() {
        super.init()
        systemName = "Movement"        // потрапляє у профілювання
        requiresTime = true            // не запускати, коли час стоїть
    }

    override func setup(world: World, context: Any?) {
        self.context = context as? Context   // кешуємо посилання один раз
    }

    override func execute(delta: Float) {
        // робота з даними
    }
}
```

### `setup()`

Викликається **один раз**, коли всі сховища зареєстровані й весь конвеєр
зібраний. Це правильне місце, щоб зберегти посилання на контекст або на
конкретні сховища.

Кешувати тут посилання — не порушення принципу «системи не зберігають даних»:
кешується **посилання** на існуюче сховище, а не копія даних.

Параметр `context` навмисно типізований як `Any?`: бібліотека нічого не знає
про вашу гру. Приведіть його до потрібного типу один раз у `setup` і збережіть
у типізованому полі — далі працюйте зі статичною типізацією.

### `execute()`

Викликається раз на кадр, у порядку, заданому планувальником.

### `teardown()`

Викликається `scheduler.teardownAll()` у **зворотному** порядку реєстрації —
ресурси розбираються як стек відносно `setup()`.

---

## 5.2. Порядок реєстрації — це контракт

```swift
scheduler.addSystem(SpawnSystem())                     // 1
scheduler.addSystem(MovementSystem())                  // 2
scheduler.addSystem(SpatialIndexSystem())               // 3
scheduler.addSystem(CollisionSystem())                  // 4
scheduler.addSystem(DamageSystem())                     // 5
scheduler.addSystem(ReaperSystem(world: world))          // 6
```

Планувальник **ніколи не сортує системи**. Порядок реєстрації — повна
специфікація поведінки.

Правило: **якщо система Б читає те, що система А пише в цьому ж кадрі, А
реєструється раніше.**

У прикладі вище індекс сусідів (3) перебудовується **після** руху (2) і **до**
пошуку зіткнень (4). Поміняйте 2 і 3 місцями — зіткнення шукатимуться за
позиціями минулого кадру. Помилки не буде; буде інша гра.

Ставтеся до цього списку як до алгоритму, а не як до оформлення. У серйозному
проєкті варто написати коментар біля кожного рядка з поясненням, чому система
стоїть саме тут.

---

## 5.3. Пауза і `requiresTime`

Пауза в цій бібліотеці — це **нульовий крок**, а не пропуск кадру:

```swift
scheduler.executeAll(delta: 0)      // пауза
```

Так рендер, камера, HUD і ввід продовжують працювати, а симуляція стоїть.

Щоб система, залежна від часу, не виконувалася на паузі, оголосіть це один раз:

```swift
override init() {
    super.init()
    systemName = "Movement"
    requiresTime = true
}
```

Планувальник пропустить виклик повністю.

| `requiresTime` | Для чого |
|---|---|
| `true` | Рух, таймери, кулдауни, старіння, AI, фізика — усе, що вимірюється в секундах |
| `false` (типово) | Рендер, камера, HUD, ввід, вивантаження буферів, **жнець** |

> **`ReaperSystem` навмисно лишає `requiresTime` дефолтним `false`.** Сутності,
> позначені на знищення перед паузою, мають бути прибрані, інакше вони
> висітимуть у черзі й у всіх сховищах увесь час паузи.

---

## 5.4. Фази

Фаза — це **мітка й фільтр**, а не спосіб упорядкування. Планувальник як не
сортував системи, так і не сортує.

```swift
enum Phase: Int32 {
    case input = 100
    case simulation = 200
    case presentation = 300
}

scheduler.addSystem(InputSystem(), phase: Phase.input.rawValue)
scheduler.addSystem(MovementSystem(), phase: Phase.simulation.rawValue)
scheduler.addSystem(CollisionSystem(), phase: Phase.simulation.rawValue)
scheduler.addSystem(RenderUploadSystem(), phase: Phase.presentation.rawValue)
```

Звичайний кадр:

```swift
scheduler.executeAll(delta: delta)
```

Кадр із фіксованим кроком, де симуляція виконується кілька разів, а рендер —
один (див. [розділ 7](07-chas-podii-yemnist.md)):

```swift
scheduler.beginFrame()                                          // закрити попередній кадр
for _ in 0..<substeps {
    scheduler.executePhase(Phase.simulation.rawValue, delta: clock.fixedStep)
}
scheduler.executePhase(Phase.presentation.rawValue, delta: delta)
```

`beginFrame()` обов'язковий перед серією `executePhase()`: він завершує
вимірювання попереднього кадру й обнуляє лічильники. `executeAll()` викликає
його сам, першим кроком.

**Заміри часу накопичуються** між двома `beginFrame()`. Тому кадр із чотирма
суб-кроками покаже сумарну вартість цих чотирьох викликів — тобто саме те, що
реально потрапило в бюджет кадру.

### Вимикачі

```swift
scheduler.setSystemEnabled(index, false)          // вимкнути одну систему
scheduler.setPhaseEnabled(Phase.simulation.rawValue, false)   // вимкнути цілу групу
let index = scheduler.findSystem("Movement")
```

Вимкнена система зберігає свій індекс у профайлері (щоб таблиця не «стрибала»)
і показує нульовий час.

**Фаза системи фіксується назавжди в момент виклику `addSystem(_:phase:)`** —
жодного методу, щоб змінити її потім, немає взагалі, навіть через планувальник.
Якщо системі потрібна інша фаза, зареєструйте новий екземпляр; один екземпляр
`System` належить **одному** планувальнику на все своє життя, а спроба
зареєструвати той самий об'єкт у другому планувальнику відхиляється.

---

## 5.5. Профілювання

Головний інструмент діагностики продуктивності — просто прямо на пристрої.

```swift
for i in 0..<scheduler.systemCount {
    let name = scheduler.getSystemName(i)
    print("\(name)  \(Int(scheduler.getTimingUsec(i))) мкс  (сер. \(Int(scheduler.getAverageTimingUsec(i))))")
}
```

- `getTimingUsec(i)` — час за **останній кадр**. Стрибає.
- `getAverageTimingUsec(i)` — експоненційно згладжене значення (вага
  `Scheduler.averageSmoothing = 0.1`). Саме його варто виводити на екранний
  оверлей: воно читабельне.
- `getTotalTimingUsec()` — сума за кадр.
- `wasSystemExecuted(i)` — чи виконувалася система (вимкнена або пропущена
  через `requiresTime` поверне `false`).
- `resetProfiling()` — обнулити все.

Вимірювання в **мікросекундах**, а не мілісекундах, навмисно: дешеві системи
вкладаються в одиниці мікросекунд, і мілісекундний звіт складався б із нулів.

Саме вимірювання коштує два виклики годинника на систему за кадр. Якщо треба
вичавити останнє:

```swift
scheduler.profilingEnabled = false
```

### Форма звіту

Лише ілюстрація — щоб отримати реальні числа, прожене́ свою сцену через
`swift test` або власну збірку застосунку:

```
  EnemySpawn                              0   avg      0
  SpatialIndex                          338   avg    336     ← домінує в кадрі
  MissileSpatialIndex                     6   avg      6
  TurretTargeting                        41   avg     34
  ProjectileImpact                       54   avg     55
  EntityReaper                            1   avg      4
```

Сенс такої таблиці по системах рівно в цьому: не гадати, куди йде кадр, а
бачити це напряму.

---

## 5.6. Метадані доступу

Необов'язковий опис того, що система читає й пише. **Не впливає ні на порядок,
ні на швидкість** — використовується інструментами.

```swift
override init() {
    super.init()
    systemName = "Movement"
    requiresTime = true
    _ = declareRead(ComponentType.velocity.rawValue)
        .declareWrite(ComponentType.position.rawValue)
        .declareStructuralWrite(ComponentType.sleeping.rawValue)   // attach/detach цього типу
        .completeAccessMetadata()                                  // «опис повний»
    writesWorldStructure = true                                    // create/destroy/reset
}
```

`declareRead`, `declareWrite`, `declareStructuralWrite` і
`completeAccessMetadata` повертають `Self`, тож їх можна ланцюжком.

Навіщо:

```swift
scheduler.validatePipeline(world: world)   // чи всі типи зареєстровані, чи не спадають фази
scheduler.systemsConflict(a, b)            // чи можна було б виконати паралельно
view.validateOwnerAccess()                 // чи оголосила система те, що читає через View
```

`systemsConflict()` — консервативний аналіз залежностей. Доки система не
викликала `completeAccessMetadata()`, її доступ вважається **невідомим**, і
вона конфліктує з усіма — щоб старий код не потрапив випадково в небезпечний
паралельний батч.

`writesWorldStructure = true` завжди конфліктує з усіма: створення й знищення
змінюють валідність сирих id і всіх `View`.

> Поточний планувальник **послідовний**. Метадані — це підготовлений ґрунт, а
> не працююча багатопотоковість. Не розраховуйте на автоматичне
> розпаралелювання.

---

## 5.7. Готові системи

### `ReaperSystem`

Та сама «одна точка знищення»:

```swift
let reaper = ReaperSystem(world: world)
scheduler.addSystem(reaper)      // останньою

// після кадру:
reaper.lastReaped      // скільки знищено цього кадру
reaper.totalReaped     // скільки всього
```

`lastReaped` зручний, щоб запускати звук чи ефект смерті: він каже, скільки
сутностей загинуло, не змушуючи їх рахувати вручну.

### `CapacityPolicySystem`

Автоматичне зростання світу — див. [розділ 7](07-chas-podii-yemnist.md).

---

## Головне з розділу

1. `setup()` — кешувати посилання; `execute()` — робота; `teardown()` — у
   зворотному порядку.
2. **Порядок реєстрації — це поведінка**, а не оформлення.
3. Пауза — це `delta == 0`; система виставляє `requiresTime = true`, і
   планувальник пропустить її сам.
4. Фази — фільтр і мітка; сортування не відбувається ніколи, а фаза системи
   фіксується назавжди в момент реєстрації.
5. Заміри накопичуються між викликами `beginFrame()`, тому суб-кроки сумуються
   коректно.
6. Метадані доступу нічого не змінюють у виконанні — вони для валідації.
7. `ReaperSystem` — останнім і рівно один.

---

[← Компоненти](04-komponenty-i-skhovyshcha.md) | [Зміст](README.md) | [Пошук сутностей →](06-poshuk-sutnostei.md)
