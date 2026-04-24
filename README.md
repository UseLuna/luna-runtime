# Luna Runtime

Animation runtime for Roblox. Playback, blending, modifiers.

## Install

### pesde

```bash
pesde add useluna/luna-runtime
```

### Wally

```toml
[dependencies]
LunaRuntime = "useluna/luna-runtime@0.1.0"
```

## Quick Start

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LunaRuntime = ReplicatedStorage.LunaRuntime

local RigResolver = require(LunaRuntime.Solver.RigResolver)
local AnimationPlayer = require(LunaRuntime.Solver.AnimationPlayer)
local AnimationData = require(LunaRuntime.Core.AnimationData)
local Evaluator = require(LunaRuntime.Core.Evaluator)

-- Resolve a rig
local RigInfo = RigResolver.ResolveRig(workspace.MyCharacter)

-- Load an animation
local EditAnim = AnimationData.CreateEmptyAnimation("Walk", 1.0)
local RuntimeAnim = AnimationData.CompileEditToRuntime(EditAnim)

-- Create a player and play
local Player = AnimationPlayer.new(RuntimeAnim)
Player:Play()
```

## Architecture

```
Core  <-  Solver
```

- **Core** — Pure math and data. Keyframes, curves, evaluation, serialization. Zero Roblox API calls.
- **Solver** — Playback engine. Applies Core output to Motor6D rigs. Blending, modifiers, bone masks.

## License

MIT
