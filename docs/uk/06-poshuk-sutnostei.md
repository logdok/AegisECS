[← Системи](05-systemy-i-planuvalnyk.md) | [Зміст](README.md) | [Час і події →](07-chas-podii-yemnist.md)

---

# 6. Пошук потрібних сутностей

Типова система обробляє не всі сутності, а ті, що мають певний набір
компонентів: «усі, хто має позицію І швидкість, але НЕ оглушений».

У Aegis для цього є три рівні, від найшвидшого до найзручнішого. Це не «поганий,
середній і хороший спосіб» — це три різні компроміси, і кожен доречний у своєму
місці.

---

## 6.1. Рівень 1: прямий цикл (найшвидший)

Ідея проста: **вести обхід по щільному масиву найменшого зі сховищ**, а решту
компонентів добирати через `sparseIndex`.

```swift
final class MovementSystem: System {
    private var velocities: PackedStore!
    private var positions: PackedStore!

    override func setup(world: World, context: Any?) {
        velocities = world.getStore(ComponentType.velocity.rawValue) as? PackedStore
        positions = world.getStore(ComponentType.position.rawValue) as? PackedStore
    }

    override func execute(delta: Float) {
        guard let velocities, let positions,
              let vx = velocities.columnF32(0), let px = positions.columnF32(0) else { return }

        // Локальні псевдоніми — виносяться один раз, перед циклом.
        let owners = velocities.denseEntities
        let posSlots = positions.sparseIndex

        for dense in 0..<Int(velocities.count) {
            let slot = posSlots[Int(owners[dense])]
            if slot < 0 { continue }                // у цієї сутності немає позиції
            px[Int(slot)] += vx[dense] * delta
        }
    }
}
```

`sparseIndex` і `denseEntities` публічні (для читання ззовні сховища) саме для
того, щоб система могла взяти їх у локальні змінні так, як тут. `columnF32`
повертає сирий вказівник у колонку `PackedStore`, дійсний до зміни ємності
світу — див. [розділ 4](04-komponenty-i-skhovyshcha.md).

**Чому вести саме по найменшому сховищу.** Якщо швидкість мають 300 сутностей, а
позицію — 10 000, то обхід по швидкостях дає 300 ітерацій, а по позиціях — 10 000
з 9 700 марними перевірками.

**Коли використовувати.** У найгарячіших системах із відомою наперед схемою. Це
основний робочий інструмент бібліотеки. `has(_:)`, `indexOf(_:)` і
`entityAt(_:)` оголошені `@inline(__always)` — у джерелі вони прямо названі
«навмисно неперевіреними примітивами гарячого циклу», саме під цей патерн.

Абстракції запиту в ядрі навмисно немає — саме тому, що вона була б помітна в
профілі найгарячіших систем.

---

## 6.2. Рівень 2: `View` (без алокацій)

Коли набір компонентів складніший, ніж «два конкретні сховища», або коли
потрібні **виключення**, зручніше описати умову декларативно.

```swift
final class MovementSystem: System {
    private let moving = View()

    override func setup(world: World, context: Any?) {
        _ = moving.configure(
            world: world,
            required: [ComponentType.position.rawValue, ComponentType.velocity.rawValue],
            excluded: [ComponentType.stunned.rawValue],
            ownerSystem: self)                      // власник, для валідації
    }

    override func execute(delta: Float) {
        moving.refreshDriver()                      // обрати найменше сховище
        guard let driver = moving.candidateStore else { return }

        for dense in 0..<Int(driver.count) {
            let entity = driver.entityAt(Int32(dense))
            if !moving.matches(entity) { continue }
            // ...
        }
    }
}
```

`View` **нічого не матеріалізує й нічого не алокує**. `configure()` — холодна
операція (один раз у `setup`), `refreshDriver()` обирає найменше з обов'язкових
сховищ, а `matches(_:)` робить прямі перевірки sparse-множин.

### Швидший варіант: вбудувати перевірку

`matches(_:)` — це виклик на кожного кандидата. У гарячій системі краще взяти у
`View` тільки **розв'язані sparse-масиви** і вбудувати перевірку у власний цикл:

```swift
moving.refreshDriver()
guard let driver = moving.candidateStore,
      let positionSlots = moving.requiredSparse(0),
      let stunnedSlots = moving.excludedSparse(0) else { return }

for dense in 0..<Int(driver.count) {
    let entity = driver.entityAt(Int32(dense))
    if positionSlots[Int(entity)] == -1 || stunnedSlots[Int(entity)] != -1 { continue }
    // ...
}
```

Так ви отримуєте зручність декларативного опису й швидкість прямого циклу
одночасно. `driverRequiredIndex` підкаже, яке саме обов'язкове сховище обрав
`refreshDriver()` — його окремо перевіряти не треба, приналежність до нього вже
гарантована самим обходом.

---

## 6.3. Рівень 3: `Query` (кешований результат)

`Query` **матеріалізує** перетин у заздалегідь виділений буфер і перебудовує
його лише тоді, коли склад учасників справді змінився.

```swift
final class DamageSystem: System {
    private let query = Query()

    override func setup(world: World, context: Any?) {
        _ = query.configure(
            world: world,
            required: [ComponentType.position.rawValue, ComponentType.health.rawValue],
            excluded: [ComponentType.invulnerable.rawValue],
            ownerSystem: self)
    }

    override func execute(delta: Float) {
        query.refresh()                              // перебудує, тільки якщо треба
        query.withEntities { entities in
            for index in 0..<Int(query.count) {
                let entity = entities[index]
                // ...
            }
        }
    }
}
```

`refresh()` повертає `true`, якщо кеш було перебудовано, і `false`, якщо склад
не змінився. Він відстежує `structuralVersion` кожного сховища-учасника
(`isCurrent` дає ту саму перевірку без перебудови).

**Що інвалідує кеш:** `attach`, `detach`, `clear`, зростання ємності.
**Що НЕ інвалідує:** запис у payload. Змінили здоров'я — склад запиту той самий.

Це і є сенс `Query`: якщо перетин читають кілька систем або він змінюється
рідко, перебудова просто не відбувається. Попадання в кеш — це кілька перевірок
версії; промах — повний обхід ведучого сховища, як і в `View`. `rebuildCountValue`
показує, скільки перебудов уже відбулося, — для діагностики.

### Обмеження розміру буфера

Типово результат виділяється на `world.capacity`. Для вузького запиту це
марнотратно:

```swift
_ = query.configure(world: world, required: required, excluded: excluded,
                     ownerSystem: self, maximumResults: 256)   // максимум 256 результатів

query.refresh()
if query.isTruncated {
    // підійшло більше сутностей, ніж вміщує буфер на 256
}
```

`maximumResults: -1` (типове значення) означає «настільки велике, як світ»; будь-
яке інше значення має бути додатним і обмежує матеріалізований набір. Без ліміту
кожен запит займає приблизно `4 байти × world.capacity`. Для великої схеми або
ставте ліміти, або користуйтеся `View`/прямим циклом.

### Швидкий доступ до буфера

```swift
query.withEntities { entities in
    for index in 0..<Int(query.count) {
        let entity = entities[index]
        // ...
    }
}
```

`withEntities` передає в замикання `UnsafeBufferPointer<Entity>` — без виклику
методу на кожен елемент. Буфер вважається **тільки для читання**, і його не
можна зберігати через `refresh()` або `world.reserveCapacity()`.

---

## 6.4. Як обрати

| | Прямий цикл | `View` | `Query` |
|---|---|---|---|
| Швидкість обходу | найвища | висока | найвища (по буферу) |
| Вартість підготовки | нема | `refreshDriver()` | `refresh()`, іноді перебудова |
| Алокації | нема | нема | буфер один раз |
| Виключення компонентів | руками | так | так |
| Коли брати | гаряча система, фіксована схема | змінна схема, виключення | перетин читають кілька разів або він рідко змінюється |

Практична порада: **починайте з прямого циклу**. Переходьте на `View`, коли
умова стає складною й код перестає читатися; на `Query` — коли профайлер
показує, що той самий перетин будується кілька разів за кадр.

---

## 6.5. Обмеження, спільне для View і Query

Обидва вимагають **щонайменше один обов'язковий тип**. `View.configure` прямо
відмовляє на порожньому списку `required`. Світ навмисно не тримає другого
щільного списку «всіх живих» тільки заради запиту без компонентів.

Якщо треба обійти справді всіх — заведіть тег, який має кожна сутність (див.
[`TagStore`](04-komponenty-i-skhovyshcha.md)), і ведіть обхід по ньому.

---

## 6.6. Правило безпеки

**Не змінюйте склад сховищ-учасників посеред активного обходу.**

```swift
// НЕПРАВИЛЬНО
for dense in 0..<Int(positions.count) {
    let entity = positions.entityAt(Int32(dense))
    if shouldRemove(entity) {
        positions.detach(entity)      // swap-remove зсунув масив під ногами
    }
}
```

Правильно — позначити й прибрати пізніше:

```swift
for dense in 0..<Int(positions.count) {
    let entity = positions.entityAt(Int32(dense))
    if shouldRemove(entity) {
        world.queueDestroy(entity)    // знищить ReaperSystem наприкінці кадру
    }
}
```

Якщо треба зняти саме **компонент**, а не сутність, — зберіть жертв у масив і
викличте `detachMany(_:count:)` після циклу.

---

## Головне з розділу

1. **Прямий цикл** — основний інструмент; вести обхід по найменшому сховищу.
2. **`View`** — декларативний опис без алокацій; для швидкості беріть із нього
   sparse-масиви (`requiredSparse`/`excludedSparse`) і вбудовуйте перевірку самі.
3. **`Query`** — коли перетин читають багато разів або він рідко змінюється;
   попадання — перевірка версії, промах — повна перебудова.
4. Запис у payload **не** інвалідує кеш запиту; `attach`/`detach` — інвалідує.
5. Ніколи не змінюйте склад сховища посеред обходу.

---

[← Системи](05-systemy-i-planuvalnyk.md) | [Зміст](README.md) | [Час і події →](07-chas-podii-yemnist.md)
