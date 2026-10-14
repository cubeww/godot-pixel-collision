# Godot Pixel Collision

A C++ GDExtension for GameMaker-style pixel-mask collision queries in Godot 4.

- `MaskedSprite2D` extends `Sprite2D` for textures, regions, and sprite sheets.
- `MaskedAnimatedSprite2D` extends `AnimatedSprite2D` for SpriteFrames and animation.
- Both share baked `PixelCollisionMask` resources, Node Group filters, and the
  native `PixelCollision` singleton. No world node or Autoload setup is needed.

Masks support precise alpha or rectangles, current/union/fixed frames, flips,
rotation, scaling, and inherited transforms. Queries sample the original masks
without generating transformed bitmaps. Exact GameMaker compatibility is not guaranteed.

## Setup

The Windows build requires Visual Studio C++ Build Tools, a Windows SDK,
CMake 3.21+, and Python. Tested with Godot 4.7.2; the extension targets the 4.5 API.

```powershell
git submodule update --init --recursive
./tools/build_windows.ps1
```

1. Open `project.godot`, or copy `addons/pixel_collision/` (including the built
   binary) into your project and enable **Pixel Collision** in Project Settings > Plugins.
2. Add either masked sprite class and assign its Texture or SpriteFrames.
3. Use **Create Mask** and **Bake / Refresh** in the Inspector. Save the resource or scene.
4. Add obstacle sprites to a Node Group such as `solid`.

## Usage

The same methods work on both sprite classes, and they can collide with each other.

```gdscript
extends MaskedSprite2D

func try_move(offset: Vector2) -> void:
    var destination := global_position + offset
    if not place_meeting(destination, &"solid"):
        global_position = destination

func find_ground() -> Node2D:
    return instance_place(global_position + Vector2.DOWN, &"solid")

func move_down_to_contact() -> void:
    move_contact(270.0, 12.0, &"solid")
```

Queries use absolute global positions and exclude the source. `instance_place`
returns either masked sprite type as `Node2D`, or `null`. Groups belong to the
sprite itself; an empty group matches all eligible sprites in the global space.

`move_contact` takes a required Group and uses degrees: 0 right, 90 up, 180 left,
270 down. It stops before overlap in unit steps. Positive distances truncate to
whole steps; zero or negative distances select a 1,000-step limit.

Bake again after editing source pixels or layout. For generated assets, call
`mask.bake_sprite(sprite)` or `mask.bake(sprite_frames)` explicitly. Frame changes
need no rebake. Keep externally saved masks and their paired source resources
external together, or embed both in one scene.

## Development

```powershell
./tools/run_tests.ps1 -Godot C:/path/to/godot.exe
./tests/editor/run_editor_tests.ps1 -Godot C:/path/to/godot.exe
```

The build script also runs the standalone C++ core tests. Source lives in
`src/core/` and `src/godot/`; editor tooling lives in `addons/pixel_collision/`.
Generated binaries, build output, and test logs are ignored by Git.

- [API and collision semantics](docs/implementation-contract.md)
- [Examples and benchmarks](examples/README.md)
- [Validation and measured performance](docs/validation.md)
