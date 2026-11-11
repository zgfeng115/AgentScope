# Login Items Native Collection and Application Grouping Implementation Plan

**Status:** Tasks 1–6 completed and verified. Focused `DashboardViewModelTests`: 18 passed; full macOS test suite: 82 passed; Debug macOS build: `** BUILD SUCCEEDED **`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the startup-time `sfltool` login-item scan with the Tencent Lemon-style `LSSharedFileList` reader and present login items as application groups with expandable details.

**Architecture:** Keep `ServiceItem` as the source-level audit record. Introduce a `LoginItemReading` protocol with a test reader and a CoreServices-backed `SharedFileListLoginItemReader`; `LoginItemCollector` consumes records from that protocol and has no command-runner or `sfltool` path. Add a ViewModel-derived application grouping layer used only when the Login Items source filter is selected, leaving LaunchAgent and other source semantics unchanged.

**Tech Stack:** Swift 6, macOS 13 deployment target, SwiftUI, CoreServices SharedFileList, XCTest, existing `ProductionServiceInventory` and `DashboardViewModel`.

---

### Task 1: Define the injectable login-item reader and failing collector tests

**Files:**
- Modify: `AgentScope/AgentScopeTests/EcosystemCollectorsTests.swift`
- Modify: `AgentScope/AgentScope/Core/Collectors/EcosystemCollectors.swift`

- [x] **Step 1: Write the failing tests for reader injection and no command execution**

Add these tests to `EcosystemCollectorsTests.swift` before changing production behavior:

```swift
func testLoginItemCollectorUsesInjectedReaderWithoutRunningSfltool() async {
    let reader = FixedLoginItemReader(records: [
        LoginItemRecord(name: "Mos.app", path: "/Applications/Mos.app", bundleIdentifier: "com.caldis.Mos")
    ])
    let result = await LoginItemCollector(reader: reader, userID: 501).collect()

    XCTAssertEqual(result.items.count, 1)
    XCTAssertTrue(result.warnings.isEmpty)
    XCTAssertEqual(result.items.first?.sourceType, .loginItem)
    XCTAssertEqual(result.items.first?.programPath, "/Applications/Mos.app")
}

func testLoginItemCollectorPreservesReaderFailureAsScopedWarning() async {
    let result = await LoginItemCollector(
        reader: FailingLoginItemReader(),
        userID: 501
    ).collect()

    XCTAssertTrue(result.items.isEmpty)
    XCTAssertEqual(result.warnings, ["Login Items unavailable: test failure"])
}
```

Add test-only helpers in the same file:

```swift
private struct FixedLoginItemReader: LoginItemReading {
    let records: [LoginItemRecord]

    func read() throws -> [LoginItemRecord] { records }
}

private struct FailingLoginItemReader: LoginItemReading {
    func read() throws -> [LoginItemRecord] {
        throw LoginItemReaderError.unavailable("test failure")
    }
}
```

- [x] **Step 2: Run the focused tests and verify the expected RED failure**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS' test \
  -only-testing:AgentScopeTests/EcosystemCollectorsTests
```

Expected result: compilation fails because `LoginItemRecord`, `LoginItemReading`, and the reader-injected `LoginItemCollector` initializer do not yet exist. Do not modify the tests to make the failure disappear.

- [x] **Step 3: Add the minimal public reader types and collector initializer**

Define these types in `EcosystemCollectors.swift` before `LoginItemCollector`:

```swift
public struct LoginItemRecord: Equatable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let bundleIdentifier: String?

    public init(name: String, path: String, bundleIdentifier: String? = nil) {
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
    }
}

public protocol LoginItemReading: Sendable {
    func read() throws -> [LoginItemRecord]
}

public enum LoginItemReaderError: LocalizedError, Equatable, Sendable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}
```

Change `LoginItemCollector` to store `reader: any LoginItemReading` and accept this initializer:

```swift
public init(
    reader: any LoginItemReading = SharedFileListLoginItemReader(),
    userID: UInt32 = getuid()
) {
    self.reader = reader
    self.userID = userID
}
```

Remove `sourceText`, `commandRunner`, `LoginItemParser`, and the `sfltool` invocation from `LoginItemCollector`. Update the existing source-text parser tests to use injected `LoginItemRecord` fixtures.

- [x] **Step 4: Run the focused tests and verify GREEN**

Run the same `xcodebuild` command. Expected result: the two new tests and all existing `EcosystemCollectorsTests` pass. Existing source-text parser tests should be replaced by reader-record tests if they no longer exercise production behavior.

---

### Task 2: Implement the CoreServices SharedFileList reader

**Files:**
- Modify: `AgentScope/AgentScope/Core/Collectors/EcosystemCollectors.swift`
- Modify: `AgentScope/AgentScopeTests/EcosystemCollectorsTests.swift`

- [x] **Step 1: Add a deterministic normalization test**

Add a test proving that duplicate paths and missing bundle metadata remain usable:

```swift
func testLoginItemCollectorDeduplicatesReaderRecordsByNormalizedPath() async {
    let reader = FixedLoginItemReader(records: [
        LoginItemRecord(name: "Mos", path: "/Applications/Mos.app/"),
        LoginItemRecord(name: "Mos.app", path: "/Applications/Mos.app")
    ])

    let result = await LoginItemCollector(reader: reader, userID: 501).collect()

    XCTAssertEqual(result.items.count, 1)
    XCTAssertEqual(result.items.first?.configurationPath, "/Applications/Mos.app")
}
```

- [x] **Step 2: Run the test and verify RED**

Run the focused `EcosystemCollectorsTests` command. Expected result: the new test fails because the collector does not yet consume `LoginItemRecord` values or normalize reader paths.

- [x] **Step 3: Implement `SharedFileListLoginItemReader`**

Add `import CoreServices` and implement a `SharedFileListLoginItemReader` that:

1. Calls `LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems, nil)`.
2. Calls `LSSharedFileListCopySnapshot` and obtains each `LSSharedFileListItemRef`.
3. Resolves each item with `LSSharedFileListItemResolve` to an `NSURL`.
4. Converts the URL to a standardized file path and derives the display name from the bundle’s `CFBundleDisplayName`, `CFBundleName`, or last path component.
5. Reads the bundle identifier through `Bundle(url:)` when the path is an app bundle.
6. Returns `LoginItemReaderError.unavailable` when the list, snapshot, or all records are unavailable.
7. Releases Core Foundation objects on every success and failure path.

The reader must be read-only. It must not call `sfltool`, `sudo`, AppleScript, System Events, `SMAppService.register`, or any enable/disable API.

- [x] **Step 4: Make `LoginItemCollector` consume records and build audited `ServiceItem`s**

For each record, normalize its path by removing trailing slashes, deduplicate by normalized path, and construct:

```swift
ServiceItem(
    id: "loginitem:user:\(normalizedPath)",
    name: record.name,
    sourceType: .loginItem,
    scope: .user,
    label: record.bundleIdentifier,
    configurationPath: record.path,
    programPath: record.path,
    state: .enabled,
    lastRunPrecision: .unknown,
    disabled: false,
    validity: .healthy,
    signature: .unknown,
    triggers: [TriggerInfo(kind: .loginItem, summary: "用户登录时启动")],
    executionEvidence: ExecutionEvidence(
        lastExecutionAt: nil,
        precision: .unknown,
        lastExitCode: nil,
        consecutiveFailures: 0,
        source: "LSSharedFileList",
        detail: "传统用户登录项只读记录"
    )
)
```

Use `.enabled` for the actual row state so the list can show “已启用” instead of making every login item look like a system-only item. Keep the item’s scope `.user` and make the detail view explicitly read-only because this task does not add mutation support.

- [x] **Step 5: Run the focused tests and verify GREEN**

Run the focused `EcosystemCollectorsTests` command. Expected result: all reader, deduplication, warning, and existing ecosystem tests pass without any `sfltool` command execution.

---

### Task 3: Wire production inventory without startup authorization

**Files:**
- Modify: `AgentScope/AgentScope/AgentScopeApp.swift`
- Modify: `AgentScope/AgentScopeTests/ProductionServiceInventoryTests.swift`

- [x] **Step 1: Add a production inventory regression test**

Add a test that constructs `ProductionServiceInventory` with a fixed login-item reader and a launch-agent collector, then asserts that both sources remain distinct:

```swift
func testProductionInventoryKeepsLoginItemsSeparateFromLaunchAgents() async {
    let loginItems = LoginItemCollector(reader: FixedLoginItemReader(records: [
        LoginItemRecord(name: "Mos.app", path: "/Applications/Mos.app", bundleIdentifier: "com.caldis.Mos")
    ]))
    let launchAgent = FixedCollectorForProduction(result: CollectorResult(items: [ServiceItem(
        id: "launchagent:user:mos",
        name: "Mos Agent",
        sourceType: .launchAgent,
        scope: .user
    )], warnings: []))

    let result = await ProductionServiceInventory(collectors: [loginItems, launchAgent]).collect()

    XCTAssertEqual(result.items.filter { $0.sourceType == .loginItem }.count, 1)
    XCTAssertEqual(result.items.filter { $0.sourceType == .launchAgent }.count, 1)
    XCTAssertTrue(result.warnings.isEmpty)
}
```

- [x] **Step 2: Run the regression test and verify RED**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS' test \
  -only-testing:AgentScopeTests/ProductionServiceInventoryTests
```

Add a local `FixedLoginItemReader` helper to `ProductionServiceInventoryTests.swift` (the helper in `EcosystemCollectorsTests.swift` is file-private). Expected result: the test cannot compile until the production factory and test fixtures accept the new reader model.

- [x] **Step 3: Remove command-based login-item collection from the production factory**

Keep the production collector list in `AgentScopeApp.swift` as:

```swift
collectors: [
    launchdCollector,
    CronCollector(),
    ShellStartupCollector(),
    LoginItemCollector(reader: SharedFileListLoginItemReader()),
    HomebrewCollector(),
    DockerCollector(),
    TmuxCollector()
]
```

Do not add a `CommandRunner` or `sfltool` fallback to this path. The only external process sources should remain the intentionally configured Homebrew, Docker, and tmux collectors.

- [x] **Step 4: Run the production inventory test and verify GREEN**

Run the same focused command. Expected result: the login item and LaunchAgent records are both present with distinct `SourceType` values and no warning from the login-item source.

---

### Task 4: Add application grouping in the dashboard model

**Files:**
- Modify: `AgentScope/AgentScope/Core/UI/DashboardViewModel.swift`
- Modify: `AgentScope/AgentScope/Core/UI/DashboardState.swift`
- Modify: `AgentScope/AgentScopeTests/DashboardViewModelTests.swift`

- [x] **Step 1: Write the failing grouping tests**

Add tests for same-application grouping, project aggregation, and partial enabled state:

```swift
func testLoginItemGroupsAggregateMultipleEntriesByBundleIdentifier() async {
    let project = ProjectIdentity(
        id: "app:/Applications/Mos.app",
        displayName: "Mos",
        rootPath: "/Applications/Mos.app",
        kind: .appBundle,
        confidence: 1,
        evidence: ["bundle"]
    )
    let items = [
        ServiceItem(id: "loginitem:user:mos", name: "Mos.app", sourceType: .loginItem, scope: .user, label: "com.caldis.Mos", programPath: "/Applications/Mos.app", project: project, state: .enabled),
        ServiceItem(id: "loginitem:user:mos-helper", name: "MosHelper", sourceType: .loginItem, scope: .user, label: "com.caldis.Mos", programPath: "/Applications/Mos.app/Contents/Library/LoginItems/MosHelper.app", project: project, state: .disabled)
    ]
    let viewModel = makeViewModel(items: items)

    await viewModel.refresh()

    XCTAssertEqual(viewModel.visibleLoginItemGroups.count, 1)
    XCTAssertEqual(viewModel.visibleLoginItemGroups.first?.items.count, 2)
    XCTAssertEqual(viewModel.visibleLoginItemGroups.first?.enabledState, .partiallyEnabled)
}

func testLoginItemCountUsesApplicationGroups() async {
    let viewModel = makeViewModel(items: [
        makeItem(id: "loginitem:user:one", name: "One", sourceType: .loginItem, scope: .user),
        makeItem(id: "loginitem:user:two", name: "Two", sourceType: .loginItem, scope: .user)
    ])

    await viewModel.refresh()

    XCTAssertEqual(viewModel.count(for: .loginItems), 2)
}
```

Define `LoginItemEnabledState` with `.enabled`, `.disabled`, `.partiallyEnabled`, and `.unknown` in `DashboardState.swift`, and define `LoginItemApplicationGroup` as specified in the design document.

- [x] **Step 2: Run the focused dashboard tests and verify RED**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS' test \
  -only-testing:AgentScopeTests/DashboardViewModelTests
```

Expected result: compilation fails because the grouping model and ViewModel properties do not yet exist.

- [x] **Step 3: Implement deterministic login-item grouping**

Add `visibleLoginItemGroups` to `DashboardViewModel`. It must:

1. Filter `items` to `.loginItem` only.
2. Group first by `label` when it is a non-empty Bundle ID.
3. Otherwise group by the nearest normalized `.app` path from `programPath` or `configurationPath`.
4. Otherwise use the item ID as a stable singleton group.
5. Sort groups by application name and items by name.
6. Apply `searchText` to application name, bundle ID, project name/path, and child item fields.
7. Calculate `LoginItemEnabledState` from child states.

Change `count(for: .loginItems)` to return the number of application groups, while all other source counts continue returning source-item counts. Do not change `.automaticStartup` or `.projects` semantics.

- [x] **Step 4: Run the dashboard tests and verify GREEN**

Run the focused dashboard command. Expected result: all existing dashboard tests plus the new grouping tests pass.

---

### Task 5: Render the scheme-A login-item list with expandable details

**Files:**
- Modify: `AgentScope/AgentScope/UI/ServiceListView.swift`
- Modify: `AgentScope/AgentScope/UI/ServiceDetailView.swift`

- [x] **Step 1: Confirm the existing view-test boundary**

No runtime UI test is required for the deprecated system API. Keep the view test surface in the ViewModel tests and use the macOS target build as the rendering verification. Do not add a new UI test target in this change.

- [x] **Step 2: Implement `LoginItemGroupListView`**

When `viewModel.sourceFilter == .loginItems`, render `LoginItemGroupListView` instead of the flat `visibleItems` list. Use `DisclosureGroup` keyed by group ID and keep only the currently expanded group ID in local optional state.

The application row must show:

```swift
HStack {
    appIcon
    VStack(alignment: .leading) {
        Text(group.applicationName).font(.headline)
        Text("项目：\(group.project?.displayName ?? "未识别") · Login Item · 用户")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    Spacer()
    Text(group.enabledState.displayName)
        .foregroundStyle(group.enabledState.color)
    Text("\(group.items.count) 项")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

The expanded child row must show item name, source/scope, project, trigger summary, application path and read-only badge. Preserve list selection by tagging each child with its `ServiceItem.id`.

- [x] **Step 3: Add login-item-specific empty and warning states**

If the login-item source is empty, show:

```text
未发现传统登录项
当前仅读取用户可见的传统登录项；系统现代 Background Items 不通过未公开接口读取。
```

If the reader is unavailable, show the warning inside the Login Items view (in the empty state or above a non-empty group list) rather than displaying a global startup authorization error banner. Other collectors must continue to render normally.

- [x] **Step 4: Make detail state match the new source semantics**

For `item.sourceType == .loginItem`, show “用户登录时启动”、application path、bundle identifier and `LSSharedFileList` evidence. Keep all mutation actions hidden and use a read-only note that distinguishes user-level login items from system-level read-only records.

- [x] **Step 5: Build the macOS target and verify GREEN**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS' build
```

Expected result: `** BUILD SUCCEEDED **`, with no new compile errors from the expandable login-item view.

---

### Task 6: Full verification and runtime smoke test

**Files:**
- Modify: `docs/superpowers/specs/2026-08-05-login-items-design.md` only if implementation behavior requires a documented correction.

- [x] **Step 1: Run the complete test suite**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS' test
```

Expected result: all tests pass, including the login-item reader, grouping, inventory, and existing AI/audit tests.

- [x] **Step 2: Build the final Debug App**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope \
  -destination 'platform=macOS' build
```

Record the resulting `.app` path from Xcode’s DerivedData output.

- [x] **Step 3: Launch and inspect the runtime behavior**

Open the built app and verify:

1. Startup does not execute `/usr/bin/sfltool` and does not display an authorization prompt.
2. The Login Items sidebar count represents application groups.
3. The list shows app name, project, enabled state and item count.
4. Expanding an app shows its concrete Login Item entries and paths.
5. Automatic Startup and Login Items remain separate categories.
6. AI settings and manual AI analysis remain available and unchanged.

- [x] **Step 4: Report the final app path and verification summary**

Include the build path, test count, any known macOS deprecation warnings for `LSSharedFileList`, and the fact that no privileged helper or `sfltool` fallback was added.
