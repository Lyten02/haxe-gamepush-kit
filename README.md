# haxe-gamepush-kit

Reusable GamePush + React bridge layer for Haxe/Heaps projects.

## What is inside

- `gamepushkit/GamePushSampleBackend.hx` - backend API export, ads wrappers, lifecycle and pause/mute policies.
- `gamepushkit/Bridge.hx` - Haxe <-> React event bridge via `CustomEvent`.
- `gamepushkit/WebFocusLifecycle.hx` - browser focus/visibility lifecycle observer.

## How to reuse in another project

1. Copy folder `modules/haxe-gamepush-kit` into the target project `modules/` directory.
2. Ensure your web build includes `-cp modules/haxe-gamepush-kit/src`.
3. In game class:

```haxe
import gamepushkit.GamePushSampleBackend;

class Game extends GamePushSampleBackend {
	public function new() {
		super();
	}
}
```

Or pass your own sample menu config via constructor.
