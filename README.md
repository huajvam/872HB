# HuajHub v1.2

**Last updated: April 2026**

Multi-game Roblox hub with shared features for enhanced gameplay across supported titles.

## Features

HuajHub includes modular features that can be enabled per game:

- **Auto Parry**: Automated parrying system with configurable timing, animation detection, and dash/block actions for combat-focused games.
- **ESP (Entity Scan and Visualization)**: Player/NPC tracking and visualization overlays for better awareness.
- **Movement**: Enhanced movement utilities including speed hacks, flight, noclip, and anti-fall damage.

These features are built on shared utilities like `CharacterUtils`, `AnimatorUtils`, and `AnimationInfo` for consistency.

## Structure

- `source.lua`: Main loader script users execute to initialize the hub.
- `games/gameList.lua`: Maps `PlaceId` and `GameId` to specific game scripts.
- `games/<GameName>.lua`: Self-contained script for each game, integrating shared features and UI.
- `classes/`: Shared class-style modules (e.g., `EntityESP` for ESP, `TrackedAnimatorRegistry` for entity tracking).
- `utils/`: Shared utility modules (e.g., `Services.lua` for Roblox service access, `Maid.lua` for cleanup, `AutoParryConfigUtils.lua` for parry settings).

Current shared foundation:
- `sharedRequire(...)` exposed by `source.lua` for loading modules.
- Core components like `loader.lua`, `registry.lua`, and `bootstrap.lua` in `src/core/` handle initialization and modularity.

This structure follows the Aztup Hub pattern for scalability.

## Current Games

- **MashleAcademy**: Full implementation with auto parry, ESP, local cheats (speed, fly, noclip, god mode, anti-stun), teleports (7 waypoints), and comprehensive UI tabs.
- **DeepWoken**: Placeholder - basic scaffold in place, features under development.
- **Universal**: Placeholder - planned for cross-game utilities.

## Usage

1. Copy the loadstring below and execute it in your Roblox executor (e.g., Synapse X, Fluxus).
2. Select your game from the hub menu.
3. Configure features via the UI; settings are automatically saved to your device.

## Current Loadstring

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/huajvam/872HB/main/source.lua"))()
```
