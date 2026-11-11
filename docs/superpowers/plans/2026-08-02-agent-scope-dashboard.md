# AgentScope Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native SwiftUI audit dashboard for automatic startup items, scheduled tasks, login items, shell startup, and development ecosystems, while safely operating only user LaunchAgents.

**Architecture:** Add a multi-source `ProductionServiceInventory` aggregation boundary above read-only audit collectors, then expose immutable inventory state through a `@MainActor` `DashboardViewModel`. SwiftUI views only render ViewModel state and send user intents; they never call `CommandRunner`, `launchctl`, or Core Data directly. User LaunchAgent actions are routed through the existing `LaunchAgentController`; system, scheduled, login, shell, and ecosystem items expose no mutation controls. Unmanaged process enumeration is retained only as isolated collector/test code and is not part of the production inventory.

**Tech Stack:** Swift 6, SwiftUI, XCTest, macOS 13 deployment target, existing `AgentScopeCore` framework, existing collector/controller protocols, Core Data `LocalStore`.

## Revised implementation checkpoint — 2026-08-03

The implementation expanded the source boundary to user LaunchAgents, user cron, shell startup, Login Items, Homebrew, Docker, and tmux. System Launchd/periodic entries and the system process list are excluded from the production inventory. Each item carries trigger metadata, execution evidence, project attribution, and deterministic review status. Local rule analysis is available behind an explicit provider interface; cloud analysis is disabled unless explicitly enabled and configured.

---

## File map

- Create `AgentScope/AgentScope/Core/Inventory/ServiceInventory.swift` — merge collector snapshots and warnings.
- Create `AgentScope/AgentScope/Core/Controllers/ServiceControlling.swift` — testable operation boundary for LaunchAgent actions.
- Create `AgentScope/AgentScope/Core/UI/DashboardState.swift` — filter, sort, loading, selection, and operation state types.
- Create `AgentScope/AgentScope/Core/UI/DashboardViewModel.swift` — `@MainActor` orchestration for inventory, controller, and history.
- Create `AgentScope/AgentScope/UI/DashboardView.swift` — three-column `NavigationSplitView` composition and toolbar.
- Create `AgentScope/AgentScope/UI/SourceSidebar.swift` — source filter navigation.
- Create `AgentScope/AgentScope/UI/ServiceListView.swift` — searchable, sortable service list and rows.
- Create `AgentScope/AgentScope/UI/ServiceDetailView.swift` — detail sections, evidence, history, and operation buttons.
- Create `AgentScope/AgentScope/UI/OperationConfirmationView.swift` — confirmation sheet for mutating user LaunchAgent actions.
- Modify `AgentScope/AgentScope/AgentScopeApp.swift` — construct production dependencies and present `DashboardView`.
- Create `AgentScope/AgentScopeTests/ServiceInventoryTests.swift` — aggregation, deduplication, and warning tests.
- Create `AgentScope/AgentScopeTests/DashboardViewModelTests.swift` — state, filtering, selection, loading, and action tests.
- Modify `AgentScope/AgentScope.xcodeproj/project.pbxproj` — register all new source and test files in the existing target phases.

## Task 1: Add inventory aggregation

**Files:**
- Create: `AgentScope/AgentScope/Core/Inventory/ServiceInventory.swift`
- Create: `AgentScope/AgentScopeTests/ServiceInventoryTests.swift`
- Modify: `AgentScope/AgentScope.xcodeproj/project.pbxproj`

- [x] **Step 1: Write failing aggregation tests**

Define fake collectors and verify that inventory returns all items sorted by stable ID, merges warnings, and keeps the first item when two collectors emit the same ID:

```swift
func testCollectMergesItemsAndWarnings() async {
    let inventory = ServiceInventory(collectors: [
        FixedCollector(result: CollectorResult(items: [item("b")], warnings: ["launch warning"])),
        FixedCollector(result: CollectorResult(items: [item("a")], warnings: ["process warning"]))
    ])

    let result = await inventory.collect()

    XCTAssertEqual(result.items.map(\.id), ["a", "b"])
    XCTAssertEqual(result.warnings, ["launch warning", "process warning"])
}

func testCollectDeduplicatesByStableID() async {
    let inventory = ServiceInventory(collectors: [
        FixedCollector(result: CollectorResult(items: [item("same", name: "first")], warnings: [])),
        FixedCollector(result: CollectorResult(items: [item("same", name: "second")], warnings: []))
    ])

    let result = await inventory.collect()

    XCTAssertEqual(result.items.count, 1)
    XCTAssertEqual(result.items.first?.name, "first")
}
```

- [x] **Step 2: Run the focused test and verify it fails**

Run:

```bash
xcodebuild -quiet -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData test \
  -only-testing:AgentScopeTests/ServiceInventoryTests
```

Expected: compile failure because `ServiceInventory` and its result type do not exist.

- [x] **Step 3: Implement the minimal inventory boundary**

Add `InventoryResult` and a `Sendable` `ServiceInventory` with this API:

```swift
public struct InventoryResult: Sendable {
    public let items: [ServiceItem]
    public let warnings: [String]
    public init(items: [ServiceItem], warnings: [String]) {
        self.items = items
        self.warnings = warnings
    }
}

public struct ServiceInventory: Sendable {
    private let collectors: [any Collector]
    public init(collectors: [any Collector]) { self.collectors = collectors }

    public func collect() async -> InventoryResult {
        // await every collector, append warnings in collector order,
        // retain the first item for each ID, and return IDs sorted ascending.
    }
}
```

Do not make the inventory call real commands, mutate items, or throw for one collector's failure; collectors already convert source failures into warnings.

- [x] **Step 4: Run the focused test and verify it passes**

Run the same command. Expected: all `ServiceInventoryTests` pass.

- [x] **Step 5: Register the new files**

Add the inventory source file to the `AgentScopeCore` sources phase and the test file to the `AgentScopeTests` sources phase. Re-run the focused test to verify the Xcode project includes both files.

## Task 2: Build dashboard state and ViewModel tests first

**Files:**
- Create: `AgentScope/AgentScope/Core/UI/DashboardState.swift`
- Create: `AgentScope/AgentScope/Core/UI/DashboardViewModel.swift`
- Create: `AgentScope/AgentScope/Core/Controllers/ServiceControlling.swift`
- Create: `AgentScope/AgentScopeTests/DashboardViewModelTests.swift`
- Modify: `AgentScope/AgentScope.xcodeproj/project.pbxproj`

- [x] **Step 1: Define state types and write failing ViewModel tests**

Define these public state types and injected boundaries:

```swift
public enum SourceFilter: String, CaseIterable, Sendable {
    case all, launchAgents, processes, systemReadonly
}

public enum ServiceSort: String, CaseIterable, Sendable {
    case name, source, state
}

public enum DashboardLoadState: Sendable, Equatable {
    case idle, loading, loaded, partiallyFailed, failed(String)
}

public protocol ServiceInventoryProviding: Sendable {
    func collect() async -> InventoryResult
}

public protocol OperationHistoryProviding: Sendable {
    func fetchOperationRecords(serviceID: String?) throws -> [OperationRecord]
}

public protocol ServiceControlling: Sendable {
    func start(_ item: ServiceItem) async throws
    func stop(_ item: ServiceItem) async throws
    func restart(_ item: ServiceItem) async throws
    func setEnabled(_ enabled: Bool, for item: ServiceItem) async throws
    func testRun(_ item: ServiceItem) async throws
}

extension ServiceInventory: ServiceInventoryProviding {}
extension LocalStore: OperationHistoryProviding {}
extension LaunchAgentController: ServiceControlling {}
```

Use fake inventory, fake controller, and fake history provider to test:

```swift
func testFilteringBySourceAndSearch() async throws {
    let viewModel = makeViewModel(items: [launchAgentItem, processItem, systemItem])
    await viewModel.refresh()

    viewModel.sourceFilter = .launchAgents
    viewModel.searchText = "worker"

    XCTAssertEqual(viewModel.visibleItems.map(\.id), [launchAgentItem.id])
}

func testSystemItemHasNoMutationActions() async throws {
    let viewModel = makeViewModel(items: [systemItem])
    await viewModel.refresh()

    XCTAssertTrue(viewModel.availableActions(for: systemItem).isEmpty)
}

func testRefreshPreservesSelectionWhenItemRemains() async throws {
    let viewModel = makeViewModel(items: [launchAgentItem])
    await viewModel.refresh()
    viewModel.selectedServiceID = launchAgentItem.id

    await viewModel.refresh()

    XCTAssertEqual(viewModel.selectedServiceID, launchAgentItem.id)
}

func testPartialCollectorFailureIsVisible() async throws {
    let viewModel = makeViewModel(items: [launchAgentItem], warnings: ["process scan failed"])
    await viewModel.refresh()

    XCTAssertEqual(viewModel.loadState, .partiallyFailed)
    XCTAssertEqual(viewModel.warnings, ["process scan failed"])
}
```

- [x] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
xcodebuild -quiet -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData test \
  -only-testing:AgentScopeTests/DashboardViewModelTests
```

Expected: compile failure because the ViewModel, state types, and injected test doubles do not exist.

- [x] **Step 3: Implement pure filtering and sorting**

`DashboardViewModel.visibleItems` must derive from the immutable `items` snapshot. Search lowercases the query and checks `name`, `label`, `programPath`, and `configurationPath`. Source filters map as follows:

```swift
switch sourceFilter {
case .all: true
case .launchAgents: item.sourceType == .launchAgent
case .processes: item.sourceType == .process
case .systemReadonly: item.scope == .system || item.state == .systemReadonly
}
```

Sort by the selected key and break ties with `id`, so tests and UI order are deterministic.

- [x] **Step 4: Implement async refresh and selection reconciliation**

`DashboardViewModel` is `@MainActor`, stores `items`, `warnings`, `loadState`, `sourceFilter`, `searchText`, `sort`, and `selectedServiceID`, and is initialized with `any ServiceInventoryProviding`, an optional `any ServiceControlling`, and `any OperationHistoryProviding`. It exposes:

```swift
public func refresh() async
public var visibleItems: [ServiceItem] { get }
public func availableActions(for item: ServiceItem) -> [OperationAction] { get }
public func history(for serviceID: String) throws -> [OperationRecord]
```

Refresh sets `.loading`, awaits inventory, replaces the snapshot, sets `.loaded` or `.partiallyFailed`, and clears selection only when its ID is absent from the new snapshot. An inventory result with no items and warnings is still `.partiallyFailed`; an inventory result with no items and no warnings is `.loaded` with an empty list.

- [x] **Step 5: Implement action routing and operation state**

Expose an async method:

```swift
public func perform(_ action: OperationAction, on item: ServiceItem) async
```

Only `.launchAgent` items with `.user` scope can route to `LaunchAgentController`; all other items set a user-visible action error without calling the controller. Set `operatingServiceID` before the call, clear it afterward, record the localized error message on failure, and call `refresh()` after success or failure so the displayed state is never stale.

- [x] **Step 6: Run the focused tests and verify they pass**

Run the same focused test command. Expected: all ViewModel tests pass without launching real `launchctl`.

- [x] **Step 7: Register the state/ViewModel/test files**

Add the two core files to the framework source phase and the test file to the test source phase. Re-run both focused test classes.

## Task 3: Implement the three-column SwiftUI surface

**Files:**
- Create: `AgentScope/AgentScope/UI/DashboardView.swift`
- Create: `AgentScope/AgentScope/UI/SourceSidebar.swift`
- Create: `AgentScope/AgentScope/UI/ServiceListView.swift`
- Create: `AgentScope/AgentScope/UI/ServiceDetailView.swift`
- Create: `AgentScope/AgentScope/UI/OperationConfirmationView.swift`
- Modify: `AgentScope/AgentScope.xcodeproj/project.pbxproj`

- [x] **Step 1: Use the app target as the SwiftUI view compilation gate**

The current executable app module cannot be imported by the unit-test target, so use the app target's `build-for-testing` compilation as the view construction gate. Keep behavioral checks in `DashboardViewModelTests`; do not introduce screenshot tests that depend on a live launchd environment.

- [x] **Step 2: Implement `SourceSidebar`**

Render `SourceFilter.allCases` in a `List(selection:)`, show localized labels and counts from `viewModel.items`, and bind selection to `viewModel.sourceFilter`. The sidebar must not own a duplicate filter state.

- [x] **Step 3: Implement `ServiceListView` and `ServiceRowView`**

Use `List(viewModel.visibleItems, selection: $viewModel.selectedServiceID)` with `.searchable(text:)`, a sort menu, and rows containing:

```swift
Text(item.name)
Text(item.sourceType.displayName)
Text(item.state.displayName)
if item.scope == .system || item.state == .systemReadonly { Text("只读") }
```

Show an inline warning banner when `loadState == .partiallyFailed` and an empty state when `visibleItems.isEmpty` after loading.

- [x] **Step 4: Implement `ServiceDetailView`**

Render overview, startup information, validity/signature/evidence, history, and an operation toolbar. Use `RunTimePrecision` to format recent runtime as exact, approximate, or unknown. Hide all mutation buttons when `availableActions(for:)` is empty.

- [x] **Step 5: Implement confirmation and action feedback**

For mutating actions, present `OperationConfirmationView` as a sheet with service name, scope, configuration path, and backup note. Confirm invokes `viewModel.perform`; cancel does nothing. While `operatingServiceID == item.id`, disable operation buttons and show progress. Show `viewModel.actionError` in an alert and clear it after dismissal.

- [x] **Step 6: Register all SwiftUI files and compile**

Register the five UI files in the app target source phase. Run:

```bash
xcodebuild -quiet -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData build-for-testing
```

Expected: successful app and test-target compilation with only known Xcode beta/CoreSimulator environment warnings.

## Task 4: Wire production dependencies into the app

**Files:**
- Modify: `AgentScope/AgentScope/AgentScopeApp.swift`
- Modify: `AgentScope/AgentScope/Core/Inventory/ServiceInventory.swift`
- Modify: `AgentScope/AgentScope.xcodeproj/project.pbxproj` if dependency registration needs adjustment.

- [x] **Step 1: Add an app dependency factory test seam**

Define a factory or initializer that accepts `ServiceInventory`, optional `LaunchAgentController`, and `LocalStore`; tests continue to inject fakes. Do not create Core Data or run collectors from a SwiftUI view initializer.

- [x] **Step 2: Construct production collectors**

Create the user LaunchAgent collector first. Feed its result into a process collector configured with `persistentItems` so matched LaunchAgent processes are not duplicated. Compose both in `ServiceInventory`.

- [x] **Step 3: Construct production storage and controller**

Use Application Support URLs under `AgentScope` for the local store and backup root. If storage/controller initialization fails, construct the ViewModel in a read-only/degraded state and show the initialization error instead of crashing the app.

- [x] **Step 4: Replace the current app body**

Present `DashboardView` in the existing `WindowGroup`, set the minimum window size to 900×600, and trigger `Task { await viewModel.refresh() }` from the dashboard lifecycle.

- [x] **Step 5: Build the app target**

Run the build-for-testing command from Task 3. Expected: production app launches to the dashboard dependency graph and test target compiles.

## Task 5: Full verification and delivery checkpoint

**Files:**
- Modify: `docs/2026-08-02-macos-agent-service-manager-design.md` only if the dashboard implementation exposes a necessary first-phase clarification.
- Modify: `docs/superpowers/plans/2026-08-02-agent-scope-dashboard.md` to mark completed steps.

- [x] **Step 1: Run all tests**

Run:

```bash
xcodebuild -quiet -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/DerivedData \
  -resultBundlePath .build/Task7-data-fix.xcresult test
```

Expected: zero failed tests, zero skipped tests, and all existing collector/controller tests still pass.

- [x] **Step 2: Inspect the result summary**

Run:

```bash
xcrun xcresulttool get test-results summary --path .build/Task7-data-fix.xcresult --compact
```

Expected: JSON with `result: "Passed"` and `failedTests: 0`.

Latest verification: 35 tests passed, 0 failed, and 0 skipped. The runtime check also confirmed 14 user LaunchAgents and 225 current user processes in the built app.

- [x] **Step 3: Review the app target manually**

Launch the built app or use Xcode Preview to confirm the window has the three columns, a visible empty/loading state, a read-only system item treatment, and a confirmation sheet for user LaunchAgent actions. Do not invoke real mutating actions against the user's services during verification.

- [x] **Step 4: Record the delivery checkpoint**

Update the plan checkboxes and the main phase plan. This workspace is not a Git worktree, so use the plan/result bundle as the verification record rather than attempting a commit.
