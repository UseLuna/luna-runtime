# Luna Runtime — Animation Runtime for Roblox

## Project Overview
Luna Runtime is the open-source animation runtime extracted from the Luna animation system. It handles playback, blending, modifiers, LOD, and serialization. Game developers embed it to play Luna animations without the editor.

This repo is published as a Wally/pesde package (`useluna/luna-runtime`). The closed-source Luna Animator editor consumes it as a git submodule.

## Architecture (strict downward dependency)
```
Core  <-  Solver
```

- **Core** — Pure math and data. Keyframe types, curve evaluation (bezier, linear, stepped), interpolation, easing, serialization, binary search. ZERO Roblox API calls. Could run in any Luau environment.
- **Solver** — Playback engine. Applies Core output to Motor6D rigs. Animation blending, modifier stack (noise, spring), LOD management, import/export codecs. Includes LunaRuntimeWrapper convenience API.
- **Types** — Shared type definitions (CoreTypes, ExportTypes, SolverTypes, etc.)
- **Shared** — Logger, Signal (pub/sub utility).

## Source Layout
```
src/
  Core/           -- Math, data model, evaluator, curves, serialization, SearchUtils
  Solver/         -- Playback, blending, LOD, import/export, LunaRuntimeWrapper
  Types/          -- Shared type definitions
  Shared/         -- Logger, Signal
tests/
  spec/           -- Jest-Lua tests
internal/         -- Private docs, specs, research (gitignored on public repo)
```

## Rojo Project Files
- `default.project.json` — library build → `ReplicatedStorage.LunaRuntime`
- `test.project.json` — test build → `ReplicatedStorage.Luna` (matches monorepo test paths)

## Related Repos
- `UseLuna/luna-animator` — Closed-source editor. Consumes this package via pesde workspace dep during private dev, will flip to `{ name = "useluna/luna_runtime", version = "^..." }` at public release.
- `UseLuna/luna-bridge` — Future convenience layer (auto-discovery, replication).

## Commands
```
# Dev / Build
rojo serve default.project.json   # Sync to Studio (standalone)
rojo build default.project.json -o build/runtime.rbxl

# Tooling
selene src/             # Lint
stylua src/             # Format
pesde install           # Install packages
```

Luna Animator consumes this package as a pesde workspace dep from
`~/Documents/luna-workspace/luna-animator/pesde.toml`. Edits here
propagate automatically on the animator's next `rojo serve` — no
`cp -r`, no commit round-trip.

## Code Style — CRITICAL
- `--!strict` on first line of every file
- `--!optimize 2` and `--!native` on all hot-path modules (Evaluator, AnimationSolver, AnimationPlayer, PoseApplier, Quaternion, CFrameUtils, Curves, SearchUtils, Pose, BoneMask, SolverLodManager)
- **PascalCase everything** — locals, params, functions, properties. No abbreviations (`Player` not `Plr`, `DeltaTime` not `dt`)
- Method definitions use **dot syntax + explicit typed self**: `function Foo.Bar(self: Foo, X: number)` — NEVER colon syntax for definitions
- Booleans prefixed: `Is`, `Has`, `Was`, `Can`, `Should`
- Constants: `UPPER_SNAKE_CASE`, centralized in `Core/Constants.luau`
- Internal: `_SingleUnderscore`. Private: `__DoubleUnderscore`
- Use `CoreTypes.Array<T>` not `{T}`, `CoreTypes.StringIndexable<T>` not `{[string]: T}`
- NEVER use `print()`/`warn()` — use `Logger.Debug/Info/Warn/Error()` (DOT syntax, not colon)
- Use string interpolation (`` `text {Var}` ``) not concatenation
- Tabs not spaces. Double quotes.
- Early returns / guard clauses over deep nesting
- Janitor for all cleanup (events, instances, state)
- Use `//` floor division instead of `math.floor(x / y)` — avoids function call overhead

## Performance Rules
- No table allocations in hot loops — pre-allocate and rewrite
- Use `table.create(N)` for known-size arrays
- Count + direct index write instead of `table.insert` in hot paths
- Cache last keyframe index per track for O(1) lookup during linear playback
- Binary search via `SearchUtils.FindLastAtOrBefore` / `FindInsertIndex` (DRY, shared)
- Decompose CFrames to position + quaternion for interpolation
- Pre-compile bezier handles to polynomial coefficients at compile step
- Dirty-flag caches for expensive scans (`__MaxBoneWeight`, `__UpdateLiveBoneWeights`)
- Cached marker index for O(1) sequential playback marker detection
- Two-pass Evaluate + Apply for cross-rig motor write batching
- Generalized iteration (`for _, v in t`) is fine in Luau — do NOT switch to numeric for "for performance"

## Key Design Decisions
1. **Decompose CFrames at compile time** — Edit format stores CFrames. Runtime format stores Vector3 + Quaternion separately.
2. **Slerp with shortest-path + Nlerp fallback** — Check `dot(q1, q2) < 0` and negate before interpolation.
3. **Cached index + binary search** — O(1) for sequential playback, O(log n) fallback for scrubbing.
4. **Constant track detection** — Flag tracks where all keyframes have same value, skip evaluation.
5. **Pre-compile bezier to polynomials** — Convert handles to `A*t³ + B*t² + C*t + D` coefficients at compile time.
6. **Two runtime sub-formats** — Live eval (for editor/procedural) and pre-sampled (for gameplay).
7. **AnimationSolver.Evaluate + Apply split** — Evaluate all rigs first, then batch motor writes. Enables hitbox/spatial query hooks between phases.
8. **LunaRuntimeWrapper** — Convenience wrapper: LoadAndPlay, Crossfade, FadeTo, global LOD, batch Step. Zero overhead vs manual wiring.

## MCP Servers

### Context7 — Live Documentation
Use Context7 for any Roblox API or library docs. Append "use context7" to prompts.

## Shared Documentation (~/Documents/luna-shared/)
Both repos share documentation via `luna-shared/` (configured as additional working directory).
- `luna-shared/STYLEGUIDE.md` — Code style rules (authoritative)
- `luna-shared/CHANGELOG.md` — What was built and why
- `luna-shared/decisions/LEARNINGS.md` — Gotchas, discoveries (tag entries with [Runtime]/[Animator]/[Shared])
- `luna-shared/architecture/` — ARCHITECTURE.md, VISION.md, ROADMAP.md, research docs
- `luna-shared/research/` — LUAU-PERFORMANCE-FINDINGS.md

When adding to LEARNINGS.md or CHANGELOG.md, tag entries with `[Runtime]` since you're working in this repo.

## Repo-Specific Documentation (internal/ — gitignored on public repo)
- `internal/specs/` — Design specifications (LunaRuntimeWrapper, AnimationSolver optimization)
- `internal/research/` — Performance findings specific to this repo
- `internal/guides/` — Development workflow, publish checklist
- `internal/shelved/` — Temporarily removed code with restore instructions

## Self-Improvement
When Claude makes a mistake, add a rule here so it never repeats. This file is a living document.
