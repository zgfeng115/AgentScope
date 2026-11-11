# AgentScope Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS AgentScope prototype that discovers local LaunchAgents and running user processes, displays their status, and safely manages user-owned LaunchAgents.

**Architecture:** Use a SwiftUI macOS app with a testable `AgentScopeCore` module. Collectors produce normalized `ServiceItem` values, a controller performs validated launchd operations, and a local Core Data store records snapshots and operation history. The first phase is deterministic and local; AI, broad source adapters, and Endpoint Security remain follow-on work.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 13+, Core Data with SQLite backing store, `launchctl`, `ProcessInfo`, `NSWorkspace`, `codesign`, XCTest.

---

## Phase 1 scope

Included:

- User LaunchAgent discovery from `~/Library/LaunchAgents`.
- Current launchd state enrichment through `launchctl`.
- Current non-system process discovery.
- User LaunchAgent start, stop, restart, enable, disable, and test-run actions.
- Read-only system service placeholders when visible through the current user session.
- Dashboard, detail inspector, action confirmation, operation history, and configuration backup.
- Deterministic validity checks for target paths and interpreters.

Deferred:

- Cloud or local LLM integration.
- Full Disk Access dependent Login Item parsing.
- Endpoint Security system extension.
- cron, shell rc, Homebrew, Docker, and tmux management.
- Deletion and automatic conversion of unmanaged processes into LaunchAgents.

## Project file map

Create the following files in the `AgentScope` Xcode project:

```text
AgentScope/
├── AgentScopeApp.swift
├── AppModel.swift
├── Views/
│   ├── ContentView.swift
│   ├── ServiceListView.swift
│   ├── ServiceDetailView.swift
│   ├── ConfirmationSheet.swift
│   └── EmptyStateView.swift
├── Resources/
│   └── Assets.xcassets
├── Core/
│   ├── Domain/ServiceItem.swift
│   ├── Domain/ServiceState.swift
│   ├── Domain/SourceType.swift
│   ├── Domain/OperationRecord.swift
│   ├── Execution/CommandRunner.swift
│   ├── Execution/CommandResult.swift
│   ├── Collectors/Collector.swift
│   ├── Collectors/LaunchAgentCollector.swift
│   ├── Collectors/ProcessCollector.swift
│   ├── Controllers/LaunchAgentController.swift
│   ├── Enrichment/ValidityChecker.swift
│   ├── Enrichment/SignatureInspector.swift
│   └── Persistence/LocalStore.swift
└── AgentScopeTests/
    ├── Fixtures/launchagents/com.example.valid.plist
    ├── Fixtures/launchagents/com.example.missing-target.plist
    ├── ServiceItemTests.swift
    ├── LaunchAgentCollectorTests.swift
    ├── CommandRunnerTests.swift
    ├── LaunchAgentControllerTests.swift
    └── ValidityCheckerTests.swift
```

`AgentScopeApp.swift` and all SwiftUI views belong to the app target. `Core/` belongs to a separate `AgentScopeCore` framework target referenced by the app and the test target. The framework has no SwiftUI dependency.

## Task 1: Create the native project and test targets

**Files:**

- Create: `AgentScope/AgentScope.xcodeproj`
- Create: `AgentScope/AgentScopeApp.swift`
- Create: `AgentScope/Core/` source groups
- Create: `AgentScope/AgentScopeTests/`

- [ ] **Step 1: Create the macOS App target**

In Xcode, create a macOS App named `AgentScope` with SwiftUI and Swift, minimum deployment target macOS 13.0. Add a framework target named `AgentScopeCore` and a unit test target named `AgentScopeTests`.

- [ ] **Step 2: Configure target membership**

Add `AgentScopeCore` as a target dependency of the app and test targets. Enable the Core Data capability only on the app target. Keep the framework free of UI and application lifecycle code.

- [ ] **Step 3: Add the first smoke test**

Create `AgentScopeTests/ServiceItemTests.swift` with a test that constructs a `ServiceItem` and verifies its stable identifier is unchanged after encoding and decoding.

```swift
func testServiceItemRoundTripPreservesIdentity() throws {
    let item = ServiceItem(
        id: "launchagent:user:com.example.valid",
        name: "com.example.valid",
        sourceType: .launchAgent,
        scope: .user,
        configurationPath: "/tmp/com.example.valid.plist",
        programPath: "/usr/bin/true"
    )

    let restored = try JSONDecoder().decode(
        ServiceItem.self,
        from: JSONEncoder().encode(item)
    )

    XCTAssertEqual(restored.id, item.id)
}
```

- [ ] **Step 4: Run the smoke test**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope -destination 'platform=macOS' test
```

Expected: the test target builds and the smoke test passes.

## Task 2: Define the normalized domain model

**Files:**

- Create: `AgentScope/Core/Domain/ServiceItem.swift`
- Create: `AgentScope/Core/Domain/ServiceState.swift`
- Create: `AgentScope/Core/Domain/SourceType.swift`
- Create: `AgentScope/Core/Domain/OperationRecord.swift`
- Modify: `AgentScope/AgentScopeTests/ServiceItemTests.swift`

- [ ] **Step 1: Define source and state enums**

Implement `SourceType` cases `launchAgent`, `launchDaemon`, `loginItem`, `cron`, `shellStartup`, `homebrew`, `docker`, `tmux`, `process`, and `unknown`. Implement `ServiceState` cases `discovered`, `enabled`, `running`, `stopped`, `disabled`, `failed`, `stale`, `permissionDenied`, and `systemReadonly`.

Persist English raw values so future storage and filtering remain stable.

- [ ] **Step 2: Define run-time and evidence types**

Add `RunTimePrecision` with `exact`, `approximate`, and `unknown`. Add `Evidence` with a title, detail, and severity. Add `Attribution` with `kind`, `confidence`, and evidence strings.

- [ ] **Step 3: Define `ServiceItem`**

`ServiceItem` must be `Codable`, `Hashable`, and `Identifiable`. It must include:

```swift
struct ServiceItem: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var sourceType: SourceType
    var scope: Scope
    var label: String?
    var configurationPath: String?
    var programPath: String?
    var arguments: [String]
    var state: ServiceState
    var pid: Int32?
    var startedAt: Date?
    var lastRunAt: Date?
    var lastRunPrecision: RunTimePrecision
    var lastExitCode: Int32?
    var disabled: Bool
    var validity: ValidityStatus
    var attribution: Attribution?
    var evidence: [Evidence]
}
```

Define `Scope` as `user`, `global`, and `system`; define `ValidityStatus` as `healthy`, `missingTarget`, `missingInterpreter`, `invalidConfiguration`, and `unknown`.

- [ ] **Step 4: Define `OperationRecord`**

Record operation ID, service ID, action, timestamp, success, user-visible message, and optional backup path. Actions must include `start`, `stop`, `restart`, `enable`, `disable`, `testRun`, `backup`, and `restore`.

- [ ] **Step 5: Run model tests**

Run the focused test:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope -destination 'platform=macOS' test -only-testing:AgentScopeTests/ServiceItemTests
```

Expected: all model round-trip and enum raw-value tests pass.

## Task 3: Add safe command execution and launchctl parsing

**Files:**

- Create: `AgentScope/Core/Execution/CommandRunner.swift`
- Create: `AgentScope/Core/Execution/CommandResult.swift`
- Create: `AgentScope/Core/Execution/LaunchctlParser.swift`
- Create: `AgentScope/AgentScopeTests/Fixtures/launchctl/print-valid.txt`
- Create: `AgentScope/AgentScopeTests/CommandRunnerTests.swift`

- [ ] **Step 1: Define command results**

Create a result type with `stdout`, `stderr`, `exitCode`, `timedOut`, and `duration`. Create a typed error for executable-not-found, timeout, permission-denied, and non-zero-exit.

- [ ] **Step 2: Implement `CommandRunner`**

Use `Process` and `Pipe`. Accept an explicit executable URL, argument array, timeout, and environment dictionary. Never invoke a shell for launchd operations, and never inherit sensitive environment variables into logs. Kill the child process on timeout and return a typed timeout result.

- [ ] **Step 3: Implement defensive launchctl parsing**

Parse only optional anchors from `launchctl print` output: `state`, `pid`, `last exit code`, `program`, and `path`. Unknown lines must be ignored. Missing anchors must produce `nil`, not a parse failure.

- [ ] **Step 4: Test parsing with fixtures**

Add fixtures for a running job, a stopped job, and output with unknown fields. Verify that parsing never crashes on missing fields and never treats a missing PID as a running state.

- [ ] **Step 5: Run focused execution tests**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope -destination 'platform=macOS' test -only-testing:AgentScopeTests/CommandRunnerTests
```

Expected: parser fixtures pass; timeout and non-zero exit behavior are covered with a test helper executable or `/usr/bin/true` and `/usr/bin/false`.

## Task 4: Implement LaunchAgent discovery

**Files:**

- Create: `AgentScope/Core/Collectors/Collector.swift`
- Create: `AgentScope/Core/Collectors/LaunchAgentCollector.swift`
- Create: `AgentScope/Core/Enrichment/ValidityChecker.swift`
- Create: `AgentScope/Core/Enrichment/SignatureInspector.swift`
- Create: `AgentScope/AgentScopeTests/Fixtures/launchagents/com.example.valid.plist`
- Create: `AgentScope/AgentScopeTests/Fixtures/launchagents/com.example.missing-target.plist`
- Create: `AgentScope/AgentScopeTests/LaunchAgentCollectorTests.swift`
- Create: `AgentScope/AgentScopeTests/ValidityCheckerTests.swift`

- [ ] **Step 1: Define the collector protocol**

Create:

```swift
protocol Collector {
    func collect() async -> CollectorResult
}

struct CollectorResult {
    let items: [ServiceItem]
    let warnings: [String]
}
```

Collectors must return partial results with warnings instead of throwing for one unreadable file.

- [ ] **Step 2: Scan the user LaunchAgents directory**

Enumerate `FileManager.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")`. Read only `.plist` files. Use `PropertyListSerialization` and skip malformed files with a warning.

- [ ] **Step 3: Normalize each plist**

Derive the stable ID from scope and label: `launchagent:user:<label>`. Read `Label`, `Program`, and `ProgramArguments`. If neither `Program` nor the first argument exists, mark the item invalid rather than inventing a target.

- [ ] **Step 4: Enrich validity and signature**

Check target existence, executable bit, interpreter existence, and plist readability. For app or binary targets, run `/usr/bin/codesign --verify --verbose=2` with a timeout and store only a normalized signature class, not raw command output.

- [ ] **Step 5: Enrich current launchd status**

Use the user launchd domain `gui/<uid>/<label>` and the safe command runner to query state. Merge PID, state, program, and last exit code into the normalized item. If the job is not loaded, keep the plist item and mark it stopped or disabled based on the available evidence.

- [ ] **Step 6: Test discovery and validity**

Use fixture directories injected into the collector instead of the real home directory. Verify valid plist parsing, missing target detection, malformed plist warnings, stable IDs, and unknown last-run precision when no execution event exists.

- [ ] **Step 7: Run collector tests**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope -destination 'platform=macOS' test -only-testing:AgentScopeTests/LaunchAgentCollectorTests -only-testing:AgentScopeTests/ValidityCheckerTests
```

Expected: fixture-based tests pass without modifying the real user's LaunchAgents.

## Task 5: Implement current process discovery

**Files:**

- Create: `AgentScope/Core/Collectors/ProcessCollector.swift`
- Modify: `AgentScope/Core/Domain/ServiceItem.swift`
- Create: `AgentScope/AgentScopeTests/ProcessCollectorTests.swift`

- [ ] **Step 1: Enumerate visible processes**

Use `NSWorkspace.shared.runningApplications` for GUI applications and a safe process enumeration API for command-line processes. Do not require root privileges. Skip AgentScope itself and Apple system processes from the default user-facing list, but keep them available to a system-readonly filter.

- [ ] **Step 2: Resolve process metadata**

For each visible user-owned process, capture PID, executable path when available, command name, launch date when available, parent PID when available, and whether a matching LaunchAgent label or program path exists.

- [ ] **Step 3: Mark unmanaged processes**

Create process items only when no persistent source is matched. Label them `sourceType = .process`, `lastRunPrecision = .exact` when launch time is available, and add evidence `No persistent launch source found`.

- [ ] **Step 4: Test filtering and matching**

Use injected process records to test that AgentScope is excluded, system processes are hidden by default, and a process matching a LaunchAgent is not duplicated as an unmanaged item.

## Task 6: Implement safe user LaunchAgent management

**Files:**

- Create: `AgentScope/Core/Controllers/LaunchAgentController.swift`
- Create: `AgentScope/Core/Persistence/LocalStore.swift`
- Create: `AgentScope/AgentScopeTests/LaunchAgentControllerTests.swift`

- [ ] **Step 1: Define controller actions**

Expose async methods:

```swift
func start(_ item: ServiceItem) async throws
func stop(_ item: ServiceItem) async throws
func restart(_ item: ServiceItem) async throws
func setEnabled(_ enabled: Bool, for item: ServiceItem) async throws
func testRun(_ item: ServiceItem) async throws
```

Reject system scope, missing configuration paths, and non-user LaunchAgents before invoking any command.

- [ ] **Step 2: Implement backup before mutation**

Before enable/disable or configuration edits, copy the plist to an app-owned backup directory under `Application Support/AgentScope/Backups/<service-id>/`. Use an atomic temporary file and record the backup path in `OperationRecord`.

- [ ] **Step 3: Implement launchctl operations**

Use the user GUI domain and explicit argument arrays. After every operation, re-collect the affected item and verify the expected state. Return a typed failure when the command succeeds but the postcondition is not met.

- [ ] **Step 4: Implement local history storage**

Create a Core Data model with `ServiceSnapshotEntity` and `OperationRecordEntity`. Store snapshots after each scan and operation. Use a SQLite-backed persistent container in Application Support and disable cloud synchronization.

- [ ] **Step 5: Test action guards and postconditions**

Use a fake command runner and fake collector. Verify user items can be controlled, system items are rejected before command execution, backups are created before mutation, and failed postconditions become visible typed errors.

- [ ] **Step 6: Run controller tests**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope -destination 'platform=macOS' test -only-testing:AgentScopeTests/LaunchAgentControllerTests
```

Expected: no test mutates the real user's launchd state.

## Task 7: Build the SwiftUI dashboard and detail workflow

**Files:**

- Create: `AgentScope/AppModel.swift`
- Create: `AgentScope/Views/ContentView.swift`
- Create: `AgentScope/Views/ServiceListView.swift`
- Create: `AgentScope/Views/ServiceDetailView.swift`
- Create: `AgentScope/Views/ConfirmationSheet.swift`
- Create: `AgentScope/Views/EmptyStateView.swift`
- Modify: `AgentScope/AgentScopeApp.swift`

- [ ] **Step 1: Create the app model**

`AppModel` owns the current items, selected item ID, scan state, warnings, and operation status. It calls collectors concurrently, merges by stable ID, sorts user items before system-readonly items, and exposes a `refresh()` method.

- [ ] **Step 2: Build the main navigation**

Use a `NavigationSplitView` with sidebar filters: Overview, All Services, Running, Needs Attention, Manual Processes, and User LaunchAgents. Show counts derived from the current normalized snapshot.

- [ ] **Step 3: Build the service table**

Columns: name, state, type, scope, and last started. Add search, state filter, source filter, and sortable columns. Render `Exact`, `Approximate`, and `Unknown` distinctly.

- [ ] **Step 4: Build the detail inspector**

Show runtime facts, command, working directory, validity evidence, configuration path, and recent operation history. Show management controls only when `LaunchAgentController` says the action is allowed.

- [ ] **Step 5: Add confirmation sheets**

Before stop, restart, enable, disable, or test-run, show target path, current state, requested action, required permission, and whether the action changes future auto-start behavior. Require explicit confirmation.

- [ ] **Step 6: Add loading, permission, and error states**

Display per-collector warnings without hiding successful results. Show a read-only badge for system items and a clear message when a user action is unavailable due to permissions or missing targets.

- [ ] **Step 7: Run the app and inspect layouts**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope -configuration Debug build
open AgentScope/build/Debug/AgentScope.app
```

Verify the sidebar, table, detail panel, long paths, empty states, confirmation sheet, and narrow window layout without text overlap.

## Task 8: Add phase-1 verification and documentation

**Files:**

- Create: `AgentScope/AgentScopeTests/Integration/Phase1ScenarioTests.swift`
- Modify: `AgentScope/README.md`
- Modify: `AgentScope/docs/2026-08-02-macos-agent-service-manager-design.md`

- [ ] **Step 1: Create a disposable fixture service**

Add a test-only LaunchAgent fixture that executes `/usr/bin/true` in a temporary directory. Never install it into the real user's LaunchAgents during unit tests; integration tests must use an isolated user domain or be marked manual.

- [ ] **Step 2: Add the phase-1 scenario checklist**

Cover: scan, display, validity failure, start, stop, restart, disable, enable, failed command, backup creation, operation history, and system-readonly guard.

- [ ] **Step 3: Run the full test suite**

Run:

```bash
xcodebuild -project AgentScope/AgentScope.xcodeproj -scheme AgentScope -destination 'platform=macOS' test
```

Expected: unit tests pass; manual integration scenarios are explicitly documented and do not run against production services.

- [ ] **Step 4: Update README usage notes**

Document minimum macOS version, read-only default behavior, supported first-phase sources, permission limitations, backup location, and the fact that “recent run” may be approximate or unknown.

## Self-review checklist

- The plan covers discovery, normalized data, process visibility, runtime management, UI, persistence, and verification for the first-phase scope.
- AI, broad collectors, Endpoint Security, and deletion are explicitly deferred rather than silently omitted.
- No task executes arbitrary user code; test-run only invokes a user-confirmed LaunchAgent through launchd.
- System services are rejected by the controller before mutation.
- Every reported last-run time carries a precision value.
- A failure in one collector is represented as a warning and does not discard successful collectors.
