# Aegis ECS

A compact Entity-Component-System engine in **pure Swift**, distributed as a
Swift Package. Built for simulations where thousands to tens of thousands of
objects update every frame.

No third-party dependencies. No class instance per game object — data lives in
flat, contiguous columns (`PackedStore`). Runs anywhere Swift runs.

## 📘 Documentation

- **[docs/en/](docs/en/README.md)** — full user guide (English): an introduction
  to the ECS approach, every feature with examples, the API reference, common
  mistakes, and a walk-through of a working mini-simulation.
- **[docs/uk/](docs/uk/README.md)** — the same guide in Ukrainian.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/logdok/AegisECS.git", from: "1.0.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "AegisECS", package: "AegisECS"),
            // Optional: the SwiftUI debug panel, only where you draw it.
            // .product(name: "AegisECSInspectorUI", package: "AegisECS"),
        ]
    ),
]
```

Then `import AegisECS`. There is nothing to enable — Swift Package Manager
resolves and builds the dependency, and every public type in the module is
available the moment you import it.

Verify it landed:

```bash
swift build
swift test
```

`swift test` runs the package's own test suite; it should finish with no
failures.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Vitalii Yurchenko.
