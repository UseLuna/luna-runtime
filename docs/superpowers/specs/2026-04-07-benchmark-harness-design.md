# Benchmark Harness Design Spec

**Date:** 2026-04-07
**Status:** Approved
**Scope:** Interactive benchmark harness for Luna Runtime with regression detection, Roblox native comparison, and MicroProfiler integration.

---

## 1. Goals

1. **Interactive profiling** — Rojo-served place where you spawn NPCs, toggle configs, and see live timing overlays via Iris UI.
2. **Head-to-head comparison** — Side-by-side and sequential benchmarking against Roblox's native C++ Animator on identical rigs and KeyframeSequences, with an "x factor" metric.
3. **Regression detection** — Baseline snapshot system with delta comparison, color-coded results, run notes, and export.
4. **MicroProfiler integration** — Compile-time `debug.profilebegin`/`debug.profileend` labels for granular Studio MicroProfiler timeline inspection; runtime toggle for coarse `os.clock()` timing feeding the Iris panels.
5. **Rig cache validation** — Measure skeleton fingerprinting hit/miss rates, ref counts, and memory savings under mixed rig populations.
6. **Maximum control, minimum friction** — Numeric inputs instead of preset buttons (except LOD presets). Quick-start presets for common configs. Sensible defaults so you can one-click into a benchmark.

---

## 2. Non-Goals

- Editor-specific features (graph editor, onion skin, etc.)
- CI/CD pipeline integration (no external tooling, no file I/O — results stay in-place)
- Automated change detection / smart module fingerprinting (manual "Run Suite" with user-typed notes)
- Hot-reloading benchmark panels at runtime

---

## 3. Architecture

### 3.1 Project Structure

New `benchmark.project.json` alongside existing `default.project.json` and `test.project.json`. Benchmark code lives entirely outside `src/` — never ships with the runtime package.

```
benchmark.project.json
  DataModel
    ReplicatedStorage/
      LunaRuntime/              -> src/ (Core, Solver, Types, Shared)
      Packages/                 -> Packages/ (Janitor, Iris)
      Benchmark/
        Panels/
          ControlPanel.luau
          TimingPanel.luau
          ComparisonPanel.luau
          CachePanel.luau
          RegressionPanel.luau
          LodPanel.luau
        Harness/
          NpcSpawner.luau
          AnimationProvider.luau
          TimingCollector.luau
          BaselineStore.luau
          NativeAnimatorRunner.luau
        BenchmarkConstants.luau
    StarterPlayer/
      StarterPlayerScripts/
        BenchmarkRunner.client.luau
    Workspace/
      Templates/                 (Pre-placed in .rbxl — R6 and R15 rig models.
                                  Cannot be Rojo-synced as .rbxm; place them
                                  manually in Studio and save the place file.)
      Animations/                (Pre-placed in .rbxl — drop KeyframeSequences
                                  here manually in Studio. Rojo creates the
                                  empty folder; you populate it in Studio.)
```

### 3.2 Dependencies

- **Janitor** — already a runtime dependency (wally.toml / pesde.toml)
- **Iris** — added as a dev dependency (benchmark-only, does not ship with the runtime package). Installed via pesde/wally into shared `Packages/` folder.

### 3.3 Panel Registry

Every panel exports a standard interface:

```lua
export type Panel = {
    Name: string,
    Render: (Iris: any, SharedState: SharedState) -> (),
    Init: ((SharedState: SharedState) -> ())?,
    Destroy: ((SharedState: SharedState) -> ())?,
}
```

BenchmarkRunner discovers panels from the `Panels` folder, calls `Init` on each, then calls `Render` each frame inside the Iris render loop. New panels drop in without touching existing code.

### 3.4 SharedState

Single table passed to all panels — the shared nervous system:

```lua
type AnimationSourceKind = "Synthetic" | "FromPlace" | "AssetId"

-- Discriminated union: exactly one payload field is non-nil, matching Kind.
-- Assert at runtime: if Kind == "Synthetic" then assert(SyntheticType ~= nil), etc.
type AnimationSource = {
    Kind: AnimationSourceKind,
    SyntheticType: ("Simple" | "WalkCycle" | "Heavy")?,  -- required when Kind == "Synthetic"
    KeyframeSequence: KeyframeSequence?,                  -- required when Kind == "FromPlace"
    AssetId: string?,                                      -- required when Kind == "AssetId"
}

type CacheSnapshot = {
    UniqueFingerprints: number,
    Entries: { { Fingerprint: string, BoneCount: number, RefCount: number } },
    HitCount: number,
    MissCount: number,
    EstimatedMemorySavedBytes: number,
}

type LodSnapshot = {
    TierCounts: { number },         -- T0 through T4
    SolversUpdated: number,
    TotalRegistered: number,
    SavingsPercent: number,
}

type NativeTimingSnapshot = {
    AvgTotalMs: number,
    PeakTotalMs: number,
    PerNpcUs: number,
    CurrentFps: number,
    HeapKb: number,
}

type BaselineSnapshot = {
    Results: { SuiteResult },
    Note: string,
    Timestamp: string,
}

type SuiteResultConfig = {
    NpcCount: number,
    RigType: "R6" | "R15",
    EvalMode: "Sampled" | "Live",
    SampleRate: number,
    LayerCount: number,
    IsolationMode: string,
    AnimationSourceKind: AnimationSourceKind,
    SyntheticType: string?,
    LodEnabled: boolean,
    LodPreset: string?,
}

type SuiteResult = {
    Config: SuiteResultConfig,
    Timing: TimingSnapshot,
    NativeTiming: NativeTimingSnapshot?,
}

type SharedState = {
    -- Config (ControlPanel writes, others read)
    NpcCount: number,
    Density: number,
    RigType: "R6" | "R15",
    EvalMode: "Sampled" | "Live",
    SampleRate: number,
    LayerCount: number,
    IsolationMode: "Full" | "No Render" | "No Apply" | "No Eval",
    AnimationSource: AnimationSource,
    RigVariants: RigVariantConfig,

    -- LOD (LodPanel writes)
    LodEnabled: boolean,
    LodPreset: string,

    -- Runtime (Harness writes, panels read)
    IsRunning: boolean,
    Timing: TimingSnapshot,
    CacheStats: CacheSnapshot,
    LodStats: LodSnapshot,
    NativeStats: NativeTimingSnapshot?,
    Baseline: BaselineSnapshot?,

    -- Callbacks (BenchmarkRunner wires these)
    OnConfigChanged: () -> (),
    OnStart: () -> (),
    OnStop: () -> (),
}
```

### 3.5 BenchmarkRunner Entry Point

`BenchmarkRunner.client.luau` — the single entry point:

1. Init Iris (single-context, in-game mode).
2. Discover and register all panels from the Panels folder.
3. Create SharedState with sensible defaults: 100 R15, 6-stud density, Sampled, 1 layer, Full isolation, LOD off.
4. Main loop on `RunService.RenderStepped`:
   - If running: `LunaRuntimeWrapper.Step(DeltaTime)`, collect timing via `TimingCollector`, optionally step native animators.
   - Iris frame: render each registered panel in order.
5. Wire SharedState callbacks to Harness modules (spawn/despawn/reconfigure).
6. **Config change transitions:**
   - LOD-only changes: hot-swap the preset without respawning. No timing disruption.
   - Structural changes (NPC count, rig type, animation source, density, variants, eval mode, layer count, isolation mode): trigger a full transition sequence:
     1. **Pause** — timing collection pauses (no frames accumulated during transition).
     2. **Cleanup** — destroy existing rigs.
     3. **Respawn** — spawn new rigs per updated config.
     4. **Warmup** — variance-based warmup (same as sequential comparison: CV < 5% over 30-frame window, min 30 frames, max 120 frames). Timing collection remains paused.
     5. **Auto-resume** — timing collection resumes. No manual restart needed.
   - The panel shows transition state: "Respawning..." → "Warming up (42/120)" → live metrics.

---

## 4. Panels

### 4.1 ControlPanel

The main configuration surface. Numeric inputs for maximum control, quick presets for minimum friction.

**NPC & Layout Section:**
- `NpcCount` — Iris numeric input (drag or type). Default: 100. Range: 1-2000.
- `Density` — Iris numeric input (studs between NPCs). Default: 6. Range: 1-20.
- `RigType` — Two buttons (R6 / R15), mutually exclusive, color-coded active state.

**Rig Variant Section** (collapsible, off by default):
- `PristinePercent` — slider 0-100%. Default: 100%.
- `MissingLimbPercent` — slider. Default: 0%. Randomly destroys one limb Motor6D before resolve (produces different skeleton fingerprint).
- `ToolEquippedPercent` — slider. Default: 0%. Adds Tool with Handle + grip Motor6D (extra bone).
- **Normalization behavior:** When a slider changes, Pristine absorbs the difference (it's the "remainder" category). If non-Pristine sliders sum to > 100%, clamp the last-edited slider to fit and show a yellow warning: "Adjusted to fit 100%." Always display the **effective percentages** and **effective NPC counts** next to each slider (e.g., "MissingLimb: 25% (50 NPCs)") so the actual distribution is never ambiguous.
- Display: "N unique fingerprints expected" based on config.

**Animation Section:**
- Source selector (radio-style buttons):
  - **Synthetic** — dropdown: Simple (6 track / 3 kf), WalkCycle (15 track / 9 kf), Heavy (30 track / 12 kf). Luna-only — cannot be used for native comparison.
  - **From Place** — dropdown listing KeyframeSequences found in `Workspace/Animations/`. Works for both Luna and native comparison.
  - **Asset ID** — text input for Roblox animation ID. Works for both Luna and native.
- `EvalMode` — two buttons: Sampled / Live.
- `SampleRate` — numeric input. Default: 30. Only visible in Sampled mode.

**Blend Section:**
- `LayerCount` — numeric input. Default: 1. Range: 1-16.
- Layers get equal weight (1 / LayerCount) with staggered time offsets to avoid synchronized evaluation.

**Isolation Mode:**
- Four buttons: Full / No Render / No Apply / No Eval.
- Tooltip text per mode:
  - Full: evaluate + apply + render (real-world cost)
  - No Render: evaluate + apply, meshes hidden (isolates Motor6D write cost)
  - No Apply: evaluate only, skip Motor6D writes (isolates pure eval cost)
  - No Eval: baseline frame cost with rigs in scene, nothing animated

**Action Buttons:**
- **Start / Stop** — toggle benchmark run.
- **Quick Presets** row (one-click, fills fields, user can tweak after):
  - "100 R15 Walk" — 100 NPCs, R15, WalkCycle, 1 layer, Full, LOD off
  - "1000 R6 Simple" — 1000 NPCs, R6, Simple, 1 layer, Full, LOD off
  - "Stress Test" — 500 NPCs, R15, WalkCycle, 4 layers, Full, LOD on
  - "Cache Test" — 200 NPCs, R15, 50% pristine / 25% missing limb / 25% tool

### 4.2 TimingPanel

Real-time performance overlay, visible while running.

**FPS Header:**
- Large color-coded FPS (green >= 60, yellow >= 30, red < 30).
- Frame time in ms: `60 FPS (16.7ms)`.

**Timing Breakdown:**
- Eval: average ms + peak ms.
- Apply: average ms + peak ms.
- Total: average ms + peak ms.
- Budget bar: visual eval% vs apply% split.

**Per-Unit Costs:**
- Per Track (us), Per Motor (us), Per NPC (us).

**Measurement Controls:**
- `Window` — numeric input for measurement window in **seconds**. Default: 5. The collector accumulates all frames within the time window. This avoids frame/time unit mismatch: at 60 FPS a 5-second window captures ~300 frames; at 30 FPS it captures ~150 frames, but both measure the same wall-clock duration.
- `Reset` button — clears accumulators, fresh measurement.
- `Snapshot` button — captures current stats to comparison log (persists in RegressionPanel).

### 4.3 ComparisonPanel

Luna vs Roblox native C++ Animator head-to-head.

**Two comparison modes:**

**Sequential (recommended for accuracy):**
1. Run Luna-only for configurable duration (default 15 seconds).
2. Cleanup + cooldown: destroy all rigs. Cooldown is **GC-stabilization-gated with a maximum timeout**:
   - Sample `gcinfo()` every 0.5 seconds.
   - Proceed when heap delta < 1KB over 1 second (GC has settled).
   - Maximum timeout: 15 seconds. If heap hasn't stabilized by then, proceed but **flag the result** with a warning: "GC may not have fully settled — cooldown timed out." The warning is displayed in the results and attached to any baseline snapshot.
   - No manual GC triggers — Roblox sandboxes `collectgarbage()` to `"count"` mode only. Cooldown relies on idle time for the incremental GC to reclaim naturally.
3. Run Roblox native-only for same duration.
4. Same cooldown logic (GC-gated, 15s max timeout).
5. Compare results.

**Simultaneous (quick visual check):**
- Both grids running side-by-side in the same frame.
- Less accurate (shared frame budget, GC cross-contamination) but useful for visual comparison.

**Warmup:** Variance-based detection instead of arbitrary frame count. Run frames until per-frame total timing variance drops below a threshold (coefficient of variation < 5% over a 30-frame sliding window), then start measuring. Minimum warmup: 30 frames (need at least one full window). Maximum warmup: 120 frames (cap so it doesn't spin forever on inherently noisy configs). This handles both fast-stabilizing simple configs and slow-warming `--!native` JIT compilation without wasting time.

**Measurement:** Pre-allocated timing buffers via `table.create()` before measurement begins. No closures or temporary tables in the timing hot path. `gcinfo()` sampled per-frame to track heap pressure difference.

**NativeAnimatorRunner.luau:**
- Clones identical rigs, inserts `Animator` into each `Humanoid`, loads + plays the same `KeyframeSequence` or `Animation` asset.
- Cannot instrument C++ internals. Uses **two-run isolation** (same strategy as Luna's "No Eval" mode applied to the native side):
  1. **Native Playing:** Rigs spawned, animations playing. Measure total frame time.
  2. **Native Idle:** Same rigs spawned, animations **stopped** (Animator exists but no AnimationTracks playing). Measure total frame time.
  3. **Native Animator cost** = Playing - Idle. This isolates the actual C++ animation evaluation cost from per-rig engine overhead (mesh rendering, Humanoid state machine, physics).
- Without this two-run approach, the "native cost" would include non-animation per-rig overhead (rendering, physics, Humanoid), making the comparison unfair since Luna's timing is precisely instrumented to only eval + apply.
- Only works with KeyframeSequence or AssetId sources (not synthetic).

**Results Display:**

```
                    Luna        Native      Factor      Delta
Anim cost (ms):     2.34        1.89        1.24x       +0.45ms
Per NPC (us):       23.4        18.9        1.24x       +4.5us
FPS (full):         142         168         0.85x       -26

Luna is 1.24x slower than Roblox native Animator.

Heap (Luau KB):     1,240       380         —           +860
  * Native memory is engine-internal (C++ allocations). gcinfo() only
    captures Luau heap. This comparison is apples-to-oranges. Luna's
    higher heap is expected — all animation data lives in Luau buffers.
    Native Animator stores equivalent data in engine memory invisible
    to gcinfo(). Shown for Luna-only memory tracking, not as a fair
    comparison.
```

Color coding for x factor:
- < 1.0: Luna is faster (green, bold)
- 1.0-1.1: Parity (green)
- 1.1-1.5: Acceptable overhead (yellow)
- \> 1.5: Significant overhead (red)

Sequential mode progress bar:
```
[Luna 15s] -> [Cooldown ...] -> [Native Playing 15s] -> [Cooldown ...] -> [Native Idle 15s] -> [Cooldown ...] -> Results
Progress: ████████████░░░░░░░░ Running Native Playing (8/15s)
Cooldown: GC stabilizing... (heap delta: 2.3KB/s)
```

Note: native comparison runs three measurement phases (Luna, Native Playing, Native Idle) with GC-gated cooldowns between each. The Native Idle phase measures per-rig overhead without animation, enabling accurate isolation of C++ Animator cost.

**Limitations (displayed in panel):**
- Native Animator can't play synthetic animations — only KeyframeSequence/AssetId.
- Native timing is indirect (two-run frame cost delta), not direct instrumentation.
- Roblox's Animator benefits from C++ engine optimizations (batch motor writes, native SIMD) that Luau cannot match.
- Heap comparison is informational only — `gcinfo()` captures Luau heap but not C++ engine memory. Native Animator's animation data, joint caches, and internal buffers live in engine memory invisible to `gcinfo()`. The heap row exists for tracking Luna's own memory usage, not for a fair comparison.

### 4.4 CachePanel

Skeleton cache inspection for RigResolver validation.

- **Unique Fingerprints** — count of distinct SkeletonInfo entries in cache.
- **Per-Fingerprint Breakdown** — table: fingerprint hash (truncated), bone count, ref count, rig type.
- **Cache Hit/Miss Rate** — during NPC spawning, track `RigResolver.Resolve()` calls that hit vs missed the cache.
- **Memory Savings** — estimated bytes saved by sharing skeleton data vs duplicating per-rig.

Requires exposing a `RigResolver.GetCacheStats()` function that reads from the existing `__SkeletonCache`.

### 4.5 RegressionPanel

Baseline snapshot system for regression detection.

**Baseline Management:**
- **Save as Baseline** — snapshots current full result set as the reference point.
- **Compare to Baseline** — always visible when baseline exists, shows deltas.
- **Reset Baseline** — clears stored baseline.
- **Export Results** — serializes full result set as JSON-like string to a StringValue (copy from Properties panel).

**Baseline storage:** Serialized buffer in a Configuration instance inside the benchmark place. Persists across Studio sessions when the place file is saved.

**Run Suite:**
- Manual "Run Suite" button — cycles through a predefined config matrix.
- Config matrix: animation types x NPC counts x eval modes x isolation modes.
- Per-config sequence:
  1. Spawn rigs.
  2. Variance-based warmup (CV < 5% over 30-frame sliding window, min 30 frames, max 120 frames).
  3. Measure for 5 seconds (time-based window, consistent with TimingCollector).
  4. Collect results.
  5. Cleanup + GC-stabilization-gated cooldown (< 1KB delta over 1 second, max 15 seconds).
- Results auto-compare against baseline. If any cooldown timed out, affected results are flagged.

**Run Notes:**
- Text input field where you type what changed (e.g., "optimized binary search in Evaluator").
- Note is attached to the result snapshot for later review.

**Result Display:**
```
[2026-04-07 14:32] "optimized binary search in Evaluator"
  100 R15 1L Sampled Full: Eval 2.34ms -> 2.12ms (-9.4%) [green]
  100 R15 4L Live Full:    Eval 8.24ms -> 7.91ms (-4.0%) [green]
  500 R15 1L Sampled Full: Eval 11.2ms -> 11.4ms (+1.8%) [green, within noise]
  vs Native:               1.24x -> 1.19x (improved)
```

Color coding for deltas:
- Improvement > 5%: green
- Within +/- 5%: white (noise)
- Regression 5-15%: yellow
- Regression > 15%: red

### 4.6 LodPanel

LOD configuration and debug overlays. Mirrors LunaAnimator's LOD controls.

**Controls:**
- **LOD Enable** — checkbox toggle.
- **LOD Preset** — buttons: Quality / Default / Performance / Aggressive.

**Debug Overlays** (collapsible):
- **Tier Billboards** — BillboardGui above each NPC head showing color-coded tier number (T0 gray, T1 green, T2 yellow, T3 orange, T4 red).
- **Frustum Visualization** — 12 wireframe edges showing LOD viewport boundary (neon cyan, 0.05 stud thickness).
- **Freecam** — detach camera for scene inspection. When toggled on:
  - LOD reference CFrame **freezes** to the position when freecam was activated.
  - LOD tiers remain stable as you fly around (system thinks camera is still at frozen position).
  - Frustum wireframe shows the frozen viewport, not your current camera.
  - Tier billboards reflect the frozen viewpoint.
  - On disable: LOD snaps back to real camera, normal behavior resumes.
  - Controls: WASD movement, QE vertical, right-click mouselook, Shift sprint.

**Live LOD Stats:**
- Tier distribution: `T0: 12  T1: 34  T2: 28  T3: 18  T4: 8`
- Solvers updated this frame / total registered.
- Estimated savings %.

---

## 5. Harness Modules

### 5.1 NpcSpawner

Template-based NPC spawning with grid layout and rig variant support.

**API:**
```lua
NpcSpawner.Spawn(Config: SpawnConfig): SpawnResult
NpcSpawner.Cleanup()
```

**SpawnConfig:**
```lua
type SpawnConfig = {
    Count: number,
    Density: number,
    RigType: "R6" | "R15",
    Variants: RigVariantConfig,
    IsolationMode: string,
}

type RigVariantConfig = {
    PristinePercent: number,
    MissingLimbPercent: number,
    ToolEquippedPercent: number,
}
```

**Behavior:**
- Clones from R6/R15 template into grid layout. Grid columns = `math.ceil(math.sqrt(Count))`. Spacing = `Density` studs.
- Applies rig variants: missing limb (destroy random limb Motor6D), tool equipped (add Tool with Handle + grip Motor6D).
- For "No Render" isolation: sets `Transparency = 1` on all parts except HumanoidRootPart.
- Returns `SpawnResult` with array of spawned models, rig bindings, and variant metadata.

### 5.2 AnimationProvider

Provides animations for both Luna and Roblox native.

**API:**
```lua
AnimationProvider.GetSynthetic(Type: "Simple" | "WalkCycle" | "Heavy"): EditAnimation
AnimationProvider.ScanPlaceAnimations(): { KeyframeSequence }
AnimationProvider.FromAssetId(AssetId: string): Animation
```

**Synthetic animations (Luna-only):**
- Simple: 6 tracks, 3 keyframes. Basic joint rotations.
- WalkCycle: 15 tracks, 9 keyframes. Full R15 walk with arm/leg cycles.
- Heavy: 30+ tracks, 12 keyframes. Stress-test with bezier curves on all tracks.

**Place animations:** Scans `Workspace/Animations/` folder for KeyframeSequence children, returns by name.

**Asset ID:** Creates an `Animation` instance with the given asset ID. Used by both NativeAnimatorRunner and Luna's Importer.

### 5.3 TimingCollector

Frame-level timing instrumentation using `os.clock()`.

**API:**
```lua
TimingCollector.BeginFrame()
TimingCollector.MarkEvalEnd()
TimingCollector.EndFrame()
TimingCollector.GetSnapshot(): TimingSnapshot
TimingCollector.Reset()
TimingCollector.SetWindow(Seconds: number)
```

**TimingSnapshot:**
```lua
type TimingSnapshot = {
    AvgEvalMs: number,
    AvgApplyMs: number,
    AvgTotalMs: number,
    PeakEvalMs: number,
    PeakApplyMs: number,
    PeakTotalMs: number,
    PerTrackUs: number,
    PerMotorUs: number,
    PerNpcUs: number,
    EvalPercent: number,
    ApplyPercent: number,
    CurrentFps: number,
    FrameCount: number,
    HeapKb: number,
}
```

**Implementation:**
- All timing buffers pre-allocated via `table.create(MaxExpectedFrames)` before measurement. Ring buffer sized for worst-case frame count at the configured window duration (e.g., 5s * 240fps = 1200 slots).
- Rolling **time-based** window: frames older than `WindowSeconds` are evicted from the ring buffer each frame. All units are wall-clock seconds throughout — no frame-count/time mixing.
- FPS: derived from frame count within the active window divided by window duration.
- Heap: `gcinfo()` sampled per frame.
- Peaks tracked per window, reset on `Reset()` or when oldest frame evicts.

**Runtime toggle:** Iris checkbox "Enable Timing" in TimingPanel. When off, `BeginFrame`/`MarkEvalEnd`/`EndFrame` are no-ops (single branch check, effectively zero overhead).

### 5.4 BaselineStore

Serialize/deserialize baseline snapshots.

**API:**
```lua
BaselineStore.Save(Results: SuiteResults, Note: string)
BaselineStore.Load(): (SuiteResults?, string?)
BaselineStore.Clear()
BaselineStore.Export(): string
```

**Storage:** Serialized into a Configuration instance (with StringValue children) inside the benchmark place. Persists when the place file is saved in Studio. No external files, no DataStore.

### 5.5 NativeAnimatorRunner

Roblox native Animator wrapper for head-to-head comparison.

**API:**
```lua
NativeAnimatorRunner.Spawn(Template: Model, Count: number, Source: KeyframeSequence | Animation): NativeRigArray
NativeAnimatorRunner.PlayAll()                -- Start all AnimationTracks
NativeAnimatorRunner.StopAll()                -- Stop all AnimationTracks (rigs remain, Animators remain)
NativeAnimatorRunner.GetFrameCost(): number   -- Frame time delta this frame
NativeAnimatorRunner.Cleanup()                -- Destroy all rigs
```

**Behavior:**
- Clones rigs, inserts `Animator` into each `Humanoid`, loads animation via `Animator:LoadAnimation()`.
- Uses **two-run isolation** for accurate cost measurement:
  1. `Spawn` + `PlayAll` → measure frame time (animation + rig overhead).
  2. `StopAll` (rigs stay in scene) → measure frame time (rig overhead only).
  3. Animator cost = delta between the two.
- This mirrors Luna's "No Eval" isolation mode applied to the native side.
- Only works with KeyframeSequence or AssetId sources. Panel auto-disables comparison when Synthetic source is selected.

---

## 6. Profiling

### 6.1 Two-Tier MicroProfiler Labels

Two separate flags in `BenchmarkConstants.luau`, addressing different needs:

```lua
-- BenchmarkConstants.luau
local BenchmarkConstants = {}
BenchmarkConstants.DEBUG_PROFILING = false          -- coarse labels (per-phase)
BenchmarkConstants.DEBUG_PROFILING_GRANULAR = false  -- fine-grained labels (per-operation)
return BenchmarkConstants
```

**Tier 1: Coarse labels (`DEBUG_PROFILING = true`)**

Wraps top-level phases. Called once per frame (or once per rig per frame). Negligible overhead.

```
"Luna:Step"                       LunaRuntimeWrapper.Step
  "Luna:LOD"                      SolverLodManager.Step
  "Luna:Evaluate"                 All rig evaluation (once per frame)
  "Luna:Blend"                    Layer blending (once per rig)
  "Luna:Apply"                    PoseApplier motor writes (once per rig)
  "Luna:Fade"                     Crossfade/fade processing (once per frame)
```

These are safe for always-on use during profiling sessions. The wrapper overhead is trivial relative to the work inside each phase.

**Tier 2: Granular labels (`DEBUG_PROFILING_GRANULAR = true`, requires `DEBUG_PROFILING = true`)**

Wraps per-operation functions called thousands of times per frame inside tight loops:

```
    "Luna:Eval:Bezier"            Bezier curve solve (Curves.luau)
    "Luna:Eval:Slerp"             Quaternion Slerp (Quaternion.luau)
    "Luna:Eval:BinarySearch"      Keyframe lookup (SearchUtils.luau)
    "Luna:Eval:Sampled"           Pre-sampled O(1) lookup (Sampler.luau)
    "Luna:Blend:BoneWeights"      LiveBoneWeights transitions (per bone)
    "Luna:Blend:MarkerDetect"     Marker event detection (per layer)
    "Luna:Apply:MotorWrite"       Individual Motor6D.Transform sets (per bone)
```

**Warning displayed in the Iris panel when granular profiling is active:** "Granular profiling is enabled. Per-operation labels add wrapper overhead that distorts relative timings between functions. Use for identifying which functions are hot, NOT for comparing their costs against each other. Functions called more often (e.g., Slerp) accumulate more wrapper overhead and will appear disproportionately expensive."

**Why two tiers:** Monkey-patching `debug.profilebegin`/`end` on every quaternion slerp or binary search call adds a function-call wrapper + profiler bookkeeping that becomes a significant fraction of the thing being measured. A slerp called 1500 times/frame accumulates 1500x the wrapper overhead vs a blend phase called once/frame. The coarse labels don't have this problem — they wrap large blocks of work.

Labels nest properly in Studio's MicroProfiler timeline, showing the full hierarchy.

When both flags are `false` (default): zero overhead. No wrapping occurs. The runtime modules are unmodified.

Implementation: `ProfilerInjector.luau` in the benchmark harness. BenchmarkRunner calls `ProfilerInjector.InstallCoarse()` when `DEBUG_PROFILING = true`, and additionally `ProfilerInjector.InstallGranular()` when `DEBUG_PROFILING_GRANULAR = true`. Both monkey-patch runtime functions from outside `src/`.

This approach keeps `src/` completely free of benchmark dependencies. The monkey-patching only happens in the benchmark place. When the runtime ships as a package, none of this code exists.

### 6.2 Runtime Coarse Timing

The `TimingCollector` uses `os.clock()` (sub-microsecond precision, confirmed best practice per Luau docs — `tick()` and `elapsedTime()` are deprecated). This is always available, toggled via Iris checkbox, and feeds the TimingPanel.

### 6.3 Memory Tracking

`gcinfo()` returns total Luau heap in KB. Sampled per frame. Used for:
- Heap row in ComparisonPanel (Luna memory tracking only — native C++ memory is invisible to `gcinfo()`, so this is not a fair cross-runtime comparison. See ComparisonPanel limitations).
- GC stabilization check during sequential comparison cooldowns (proceed when delta < 1KB over 1 second, max timeout 15 seconds).
- Memory savings estimate in CachePanel.

### 6.4 Memory Category Tagging

`debug.setmemorycategory("LunaBenchmark")` called at BenchmarkRunner startup. Tags all benchmark allocations under a dedicated category visible in Studio's memory profiler, separate from game/engine memory.

---

## 7. Rojo Project Configuration

`benchmark.project.json`:

```json
{
    "name": "LunaBenchmark",
    "tree": {
        "$className": "DataModel",
        "ReplicatedStorage": {
            "$className": "ReplicatedStorage",
            "LunaRuntime": {
                "$className": "Folder",
                "Core": { "$path": "src/Core" },
                "Solver": { "$path": "src/Solver" },
                "Types": { "$path": "src/Types" },
                "Shared": { "$path": "src/Shared" }
            },
            "Packages": { "$path": "Packages" },
            "Benchmark": {
                "$className": "Folder",
                "Panels": { "$path": "benchmark/Panels" },
                "Harness": { "$path": "benchmark/Harness" },
                "BenchmarkConstants": { "$path": "benchmark/BenchmarkConstants.luau" }
            }
        },
        "StarterPlayer": {
            "$className": "StarterPlayer",
            "StarterPlayerScripts": {
                "$className": "StarterPlayerScripts",
                "BenchmarkRunner": { "$path": "benchmark/BenchmarkRunner.client.luau" }
            }
        },
        "Workspace": {
            "$className": "Workspace",
            "Templates": {
                "$className": "Folder"
            },
            "Animations": {
                "$className": "Folder"
            }
        }
    }
}
```

Usage:
```bash
rojo serve benchmark.project.json   # Interactive benchmarking in Studio
```

---

## 8. Runtime API Additions

Minimal additions to the runtime source to support benchmarking (these ship with the package, guarded or zero-cost):

### 8.1 RigResolver.GetCacheStats()

New public function exposing read-only cache statistics:

```lua
function RigResolver.GetCacheStats(): CacheStats
    -- Reads from existing __SkeletonCache
    -- Returns: UniqueFingerprints, per-fingerprint bone count + ref count, total memory estimate
end
```

### 8.2 LunaRuntimeWrapper.Evaluate / .Apply split

Already exists per the AnimationSolver optimization spec. The benchmark harness calls these separately with `TimingCollector.MarkEvalEnd()` between them to isolate eval vs apply costs.

### 8.3 Profiler gates (two-tier, benchmark-only)

The profiler gates live **entirely in the benchmark harness**, not in `src/`. The runtime source is never modified with `debug.profilebegin`/`end` calls.

**Tier 1 (coarse):** The benchmark harness wraps the runtime API at the call site:

```lua
-- In BenchmarkRunner (benchmark code, not runtime code):
debug.profilebegin("Luna:Evaluate")
LunaRuntimeWrapper.Evaluate(DeltaTime)  -- calls existing public API
debug.profileend()

debug.profilebegin("Luna:Apply")
LunaRuntimeWrapper.Apply()              -- calls existing public API
debug.profileend()
```

**Tier 2 (granular):** `ProfilerInjector.InstallGranular()` monkey-patches individual hot-path functions:

```lua
-- benchmark/Harness/ProfilerInjector.luau
local Curves = require(LunaRuntime.Core.Curves)
local OriginalRemapAlpha = Curves.RemapAlpha
Curves.RemapAlpha = function(...)
    debug.profilebegin("Luna:Eval:Bezier")
    local Result = OriginalRemapAlpha(...)
    debug.profileend()
    return Result
end
```

This preserves the rule that `src/` has zero benchmark dependencies. The monkey-patching only happens in the benchmark place. When the runtime ships as a package, none of this code exists.

When both flags are `false`, no wrapping occurs — zero overhead.

---

## 9. File Layout Summary

```
benchmark/
  BenchmarkRunner.client.luau
  BenchmarkConstants.luau
  Panels/
    ControlPanel.luau
    TimingPanel.luau
    ComparisonPanel.luau
    CachePanel.luau
    RegressionPanel.luau
    LodPanel.luau
  Harness/
    NpcSpawner.luau
    AnimationProvider.luau
    TimingCollector.luau
    BaselineStore.luau
    NativeAnimatorRunner.luau
    ProfilerInjector.luau
```

Total new files: 14 Luau modules + 1 JSON project file. R6/R15 templates and KeyframeSequences are placed manually in Studio (not Rojo-synced).

---

## 10. Quick-Start Workflow

1. `pesde install` (or `wally install`) — installs Janitor + Iris into Packages/.
2. `rojo serve benchmark.project.json` — syncs to Studio.
3. Open Studio, connect to Rojo, hit Play.
4. Iris UI appears with ControlPanel showing defaults (100 R15, WalkCycle, Sampled, 1 layer, Full).
5. Hit "Start" — 100 NPCs spawn in grid, TimingPanel shows live metrics.
6. Tweak any parameter — change NPC count to 500, enable LOD, switch to Live eval.
7. Hit "Snapshot" to capture timing to comparison log.
8. Enable comparison mode — sequential run against Roblox native, see x factor.
9. Hit "Save as Baseline" — stores results.
10. Modify runtime code (e.g., optimize Evaluator), Rojo re-syncs.
11. Hit "Run Suite" with note "optimized binary search" — see deltas against baseline.
12. Toggle `DEBUG_PROFILING = true` in BenchmarkConstants, re-sync — open MicroProfiler for coarse phase timeline. Optionally also set `DEBUG_PROFILING_GRANULAR = true` for per-operation labels (see warning about timing distortion in the Iris panel).
