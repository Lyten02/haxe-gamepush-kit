package gamepushkit.bootstrap;

import haxe.Json;
import gamepushkit.bootstrap.BootstrapTypes.SaveProviderState;

#if js
import js.Browser;
#end

/**
 * Save provider abstraction used by backend bootstrap and public API.
 *
 * Policy:
 * - Cloud is source of truth when available.
 * - If cloud profile is empty, we intentionally ignore local cache and start from defaults.
 * - Local storage is used as fallback provider when GamePush Player API is unavailable.
 * - Local storage may be used as a mirror cache while in cloud mode.
 */
class SaveProvider {
	static inline var LOCAL_STORAGE_KEY:String = "gp-samples:save-cache-v1";

	public var mode(default, null):String;
	public var cloudHadData(default, null):Bool;
	public var cloudAvailable(default, null):Bool;
	public var localAvailable(default, null):Bool;

	var data:Dynamic;
	var knownKeys:Array<String>;

	public function new(mode:String, data:Dynamic, knownKeys:Array<String>, cloudAvailable:Bool, cloudHadData:Bool) {
		this.mode = mode;
		this.data = data;
		this.knownKeys = knownKeys;
		this.cloudAvailable = cloudAvailable;
		this.cloudHadData = cloudHadData;
		this.localAvailable = true;
	}

	public static function initialize(
		playerAvailable:Bool,
		usePlayerLoad:Bool,
		defaults:Dynamic,
		fieldNames:Array<String>,
		onComplete:SaveProvider->Void
	):Void {
		if (!playerAvailable) {
			onComplete(createLocalProvider(defaults, fieldNames));
			return;
		}

		#if js
		var player:Dynamic = untyped __js__("window.gamePushSDK && window.gamePushSDK.player");
		if (player == null) {
			onComplete(createLocalProvider(defaults, fieldNames));
			return;
		}

			// GamePush docs: cloud fields are available after SDK init.
			// Optional explicit player.load() can be toggled for stricter refresh.
			if (!usePlayerLoad || untyped player.load == null) {
				onComplete(createCloudProvider(player, defaults, fieldNames));
				return;
			}

			try {
				var loadPromise:Dynamic = untyped(player.load());
				var loadChain:Dynamic = untyped loadPromise.then(function(_):Dynamic {
					onComplete(createCloudProvider(player, defaults, fieldNames));
					return null;
				});

				var loadCatch:Dynamic = Reflect.field(loadChain, "catch");
				if (loadCatch != null) {
					Reflect.callMethod(loadChain, loadCatch, [function(_):Dynamic {
						onComplete(createCloudProvider(player, defaults, fieldNames));
						return null;
					}]);
				}
			} catch (e) {
				onComplete(createCloudProvider(player, defaults, fieldNames));
			}
		#else
		onComplete(createLocalProvider(defaults, fieldNames));
		#end
	}

	public function get(key:String):Dynamic {
		rememberKey(key);
		return Reflect.field(data, key);
	}

	public function set(key:String, value:Dynamic):Void {
		rememberKey(key);
		Reflect.setField(data, key, value);

		if (mode == "local") {
			persistLocalSnapshot();
		}
	}

	public function sync(onComplete:Bool->Void):Void {
		if (mode == "cloud") {
			syncCloud(onComplete);
			return;
		}

		persistLocalSnapshot();
		onComplete(true);
	}

	public function snapshot():Dynamic {
		return cloneData(data, knownKeys);
	}

	public function state():SaveProviderState {
		return {
			mode: mode,
			cloudAvailable: cloudAvailable,
			localAvailable: localAvailable,
			cloudHadData: cloudHadData
		};
	}

	function syncCloud(onComplete:Bool->Void):Void {
		#if js
		var player:Dynamic = untyped __js__("window.gamePushSDK && window.gamePushSDK.player");
		if (player == null) {
			onComplete(false);
			return;
		}

		try {
			for (key in knownKeys) {
				untyped player.set(key, Reflect.field(data, key));
			}

			var syncPromise:Dynamic = untyped player.sync();
			var syncChain:Dynamic = untyped syncPromise.then(function(success:Dynamic):Dynamic {
				var isSuccess = resolveSyncResult(success);
				if (isSuccess) {
					persistLocalSnapshot();
				}
				onComplete(isSuccess);
				return null;
			});

			var syncCatch:Dynamic = Reflect.field(syncChain, "catch");
			if (syncCatch != null) {
				Reflect.callMethod(syncChain, syncCatch, [function(_):Dynamic {
					onComplete(false);
					return null;
				}]);
			}
		} catch (e) {
			onComplete(false);
		}
		#else
		onComplete(false);
		#end
	}

	function resolveSyncResult(result:Dynamic):Bool {
		// GamePush SDK responses are not stable across versions:
		// success can be `true`, an object, or even undefined.
		if (result == null) {
			return true;
		}

		if (Std.isOfType(result, Bool)) {
			return cast result;
		}

		var successField = Reflect.field(result, "success");
		if (successField != null) {
			return successField == true;
		}

		var okField = Reflect.field(result, "ok");
		if (okField != null) {
			return okField == true;
		}

		var errorField = Reflect.field(result, "error");
		if (errorField != null) {
			return false;
		}

		return true;
	}

	function rememberKey(key:String):Void {
		if (key == null || key == "") {
			return;
		}
		for (existing in knownKeys) {
			if (existing == key) {
				return;
			}
		}
		knownKeys.push(key);
	}

	function persistLocalSnapshot():Void {
		#if js
		try {
			Browser.window.localStorage.setItem(LOCAL_STORAGE_KEY, Json.stringify(snapshot()));
		} catch (e) {
			// Ignore local persistence errors (quota/private mode).
		}
		#end
	}

	static function createCloudProvider(player:Dynamic, defaults:Dynamic, fieldNames:Array<String>):SaveProvider {
		var cloudHadData = hasAnyCloudData(player, fieldNames);
		var cloudData = cloudHadData ? readCloudData(player, defaults, fieldNames) : cloneData(defaults, fieldNames);
		var provider = new SaveProvider("cloud", cloudData, copyKeys(fieldNames), true, cloudHadData);
		provider.persistLocalSnapshot();
		return provider;
	}

	static function createLocalProvider(defaults:Dynamic, fieldNames:Array<String>):SaveProvider {
		var localData = readLocalData(defaults, fieldNames);
		var keys = mergeKeys(fieldNames, Reflect.fields(localData));
		return new SaveProvider("local", localData, keys, false, false);
	}

	static function hasAnyCloudData(player:Dynamic, fieldNames:Array<String>):Bool {
		for (field in fieldNames) {
			try {
				if (untyped player.has(field) == true) {
					return true;
				}
			} catch (e) {}
		}
		return false;
	}

	static function readCloudData(player:Dynamic, defaults:Dynamic, fieldNames:Array<String>):Dynamic {
		var out = cloneData(defaults, fieldNames);
		for (field in fieldNames) {
			try {
				var value:Dynamic = untyped player.get(field);
				if (value != null) {
					Reflect.setField(out, field, value);
				}
			} catch (e) {}
		}
		return out;
	}

	static function readLocalData(defaults:Dynamic, fieldNames:Array<String>):Dynamic {
		var out = cloneData(defaults, fieldNames);

		#if js
		try {
			var raw = Browser.window.localStorage.getItem(LOCAL_STORAGE_KEY);
			if (raw == null || raw == "") {
				return out;
			}

			var parsed:Dynamic = Json.parse(raw);
			if (parsed == null) {
				return out;
			}

			for (field in Reflect.fields(parsed)) {
				Reflect.setField(out, field, Reflect.field(parsed, field));
			}
		} catch (e) {
			// Corrupted local cache falls back to defaults.
		}
		#end

		return out;
	}

	static function cloneData(source:Dynamic, fields:Array<String>):Dynamic {
		var out:Dynamic = {};
		for (field in fields) {
			Reflect.setField(out, field, Reflect.field(source, field));
		}
		return out;
	}

	static function copyKeys(keys:Array<String>):Array<String> {
		var out:Array<String> = [];
		for (key in keys) {
			out.push(key);
		}
		return out;
	}

	static function mergeKeys(left:Array<String>, right:Array<String>):Array<String> {
		var out = copyKeys(left);
		for (key in right) {
			var exists = false;
			for (saved in out) {
				if (saved == key) {
					exists = true;
					break;
				}
			}
			if (!exists) {
				out.push(key);
			}
		}
		return out;
	}
}
