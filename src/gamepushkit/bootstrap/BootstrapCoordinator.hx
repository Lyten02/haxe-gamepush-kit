package gamepushkit.bootstrap;

import gamepush.AdManager;
import gamepushkit.bootstrap.BootstrapTypes.BootstrapProgress;
import gamepushkit.bootstrap.BootstrapTypes.BootstrapSnapshot;
import StringTools;

/**
 * Coordinates the startup bootstrap sequence before React menu becomes interactive.
 *
 * Notes about decisions:
 * - Manual language changes are runtime-only and not persisted between sessions.
 * - Leaderboard warmup is opportunistic and bounded by timeout, so it never blocks readiness forever.
 * - Cloud-empty profile intentionally starts from defaults and ignores local cache.
 */
class BootstrapCoordinator {
	static inline var LEADERBOARD_TAG:String = "main";
	static inline var LEADERBOARD_LIMIT:Int = 10;
	static inline var LEADERBOARD_TIMEOUT_MS:Int = 900;
	// Debug tuning:
	// - Read player/saves from already initialized SDK state.
	// - Keep explicit player.load() disabled to avoid extra API call.
	// - Allow leaderboard warmup call.
	static inline var GAMEPUSH_PLAYER_SNAPSHOT_ENABLED:Bool = true;
	static inline var GAMEPUSH_PLAYER_LOAD_ENABLED:Bool = false;
	static inline var GAMEPUSH_LEADERBOARD_API_CALLS_ENABLED:Bool = true;

	var adManager:AdManager;
	var saveDefaults:Dynamic;
	var saveFields:Array<String>;

	public var snapshot(default, null):BootstrapSnapshot;
	public var saveProvider(default, null):SaveProvider;
	public var currentLanguage(default, null):String = "en";
	public var leaderboardWarmup(default, null):Null<Array<Dynamic>> = null;
	public var leaderboardWarmupVariant(default, null):Null<String> = null;

	public function new(adManager:AdManager, saveDefaults:Dynamic, saveFields:Array<String>) {
		this.adManager = adManager;
		this.saveDefaults = saveDefaults;
		this.saveFields = copyKeys(saveFields);
		snapshot = createPendingSnapshot();
	}

	public function run(onProgress:BootstrapProgress->Void, onDone:BootstrapSnapshot->Void):Void {
		emitProgress(onProgress, "detectSdk", "Checking platform capabilities", 10);

		var gamePushAvailable = isGamePushAvailable();
		var playerAvailable = GAMEPUSH_PLAYER_SNAPSHOT_ENABLED && isPlayerAvailable();
		var leaderboardAvailable = GAMEPUSH_LEADERBOARD_API_CALLS_ENABLED && isLeaderboardAvailable();
		var warnings:Array<String> = [];

		emitProgress(onProgress, "resolveLanguage", "Resolving language", 25);
		var languageResolution = LanguageResolver.resolve(
			gamePushAvailable ? getProviderLanguage() : null,
			LanguageResolver.getSystemLanguage()
		);
		currentLanguage = languageResolution.language;

		emitProgress(onProgress, "prepareSaves", "Preparing save provider", 45);
		SaveProvider.initialize(playerAvailable, GAMEPUSH_PLAYER_LOAD_ENABLED, saveDefaults, saveFields, function(provider:SaveProvider) {
			saveProvider = provider;
			if (playerAvailable && provider.mode == "local") {
				warnings.push("Cloud save provider is unavailable, local fallback enabled");
			}

			emitProgress(onProgress, "loadPlayer", "Loading player snapshot", 65);
			var playerSnapshot = collectPlayerSnapshot(playerAvailable);

			emitProgress(onProgress, "loadAds", "Preparing ads status", 78);
			var adsStatus = adManager != null ? adManager.getStatus() : null;

			emitProgress(onProgress, "warmupLeaderboard", "Warming leaderboard cache", 90);
			warmupLeaderboard(leaderboardAvailable, function(warmup:Array<Dynamic>) {
				leaderboardWarmup = warmup;
				snapshot = {
					completed: true,
					gamePushAvailable: gamePushAvailable,
					playerAvailable: playerAvailable,
					leaderboardAvailable: leaderboardAvailable,
					fallbackToLocal: provider.mode == "local",
					language: currentLanguage,
					languageSource: languageResolution.source,
					saveProvider: provider.mode,
					saveInfo: provider.state(),
					saves: provider.snapshot(),
					player: playerSnapshot,
					adsStatus: adsStatus,
					leaderboardWarmup: leaderboardWarmup,
					warnings: warnings,
					startedAt: snapshot.startedAt,
					finishedAt: nowMs()
				};

				emitProgress(onProgress, "complete", "Bootstrap completed", 100);
				onDone(snapshot);
			});
		});
	}

	public function applyManualLanguage(requestedLanguage:String):String {
		currentLanguage = LanguageResolver.normalize(requestedLanguage);
		if (snapshot != null) {
			snapshot.language = currentLanguage;
			snapshot.languageSource = "manual";
		}
		return currentLanguage;
	}

	public function getSnapshot():BootstrapSnapshot {
		return snapshot;
	}

	public function getLeaderboardWarmup():Null<Array<Dynamic>> {
		return leaderboardWarmup;
	}

	public function getLeaderboardWarmupVariant():Null<String> {
		return leaderboardWarmupVariant;
	}

	function warmupLeaderboard(leaderboardAvailable:Bool, onComplete:Array<Dynamic>->Void):Void {
		if (!leaderboardAvailable || !shouldWarmupLeaderboard()) {
			onComplete(null);
			return;
		}

		var finished = false;
		var finish = function(result:Array<Dynamic>) {
			if (finished)
				return;
			finished = true;
			onComplete(result);
		};

		// Time budget keeps warmup optional and prevents blocking readiness.
		haxe.Timer.delay(function() {
			finish(null);
		}, LEADERBOARD_TIMEOUT_MS);

		#if js
		try {
			var leaderboard:Dynamic = untyped __js__("window.gamePushSDK && window.gamePushSDK.leaderboard");
			if (leaderboard == null) {
				finish(null);
				return;
			}

				var fetchPromise:Dynamic = untyped leaderboard.fetch({
					tag: LEADERBOARD_TAG,
					limit: LEADERBOARD_LIMIT
				});
				var fetchChain:Dynamic = untyped fetchPromise.then(function(result:Dynamic):Dynamic {
					leaderboardWarmupVariant = null;
					if (result != null) {
						var directVariant:Dynamic = Reflect.field(result, "variant");
						if (Std.isOfType(directVariant, String)) {
							var directVariantString = StringTools.trim(cast directVariant);
							if (directVariantString != "")
								leaderboardWarmupVariant = directVariantString;
						}

						if (leaderboardWarmupVariant == null) {
							var leaderboardMeta:Dynamic = Reflect.field(result, "leaderboard");
							if (leaderboardMeta != null) {
								var metaVariant:Dynamic = Reflect.field(leaderboardMeta, "variant");
								if (!Std.isOfType(metaVariant, String))
									metaVariant = Reflect.field(leaderboardMeta, "defaultVariant");
								if (Std.isOfType(metaVariant, String)) {
									var metaVariantString = StringTools.trim(cast metaVariant);
									if (metaVariantString != "")
										leaderboardWarmupVariant = metaVariantString;
								}
							}
						}
					}

					var players:Array<Dynamic> = null;
					if (result != null && Reflect.hasField(result, "players")) {
						players = cast Reflect.field(result, "players");
					}
					finish(players);
					return null;
				});

			var fetchCatch:Dynamic = Reflect.field(fetchChain, "catch");
			if (fetchCatch != null) {
				Reflect.callMethod(fetchChain, fetchCatch, [function(_):Dynamic {
					finish(null);
					return null;
				}]);
			}
		} catch (e) {
			finish(null);
		}
		#else
		finish(null);
		#end
	}

	function collectPlayerSnapshot(playerAvailable:Bool):Dynamic {
		if (!playerAvailable) {
			return {
				id: "",
				name: "Guest",
				avatar: "",
				isLoggedIn: false,
				score: Reflect.field(saveProvider.snapshot(), "score")
			};
		}

		#if js
		return {
			id: untyped __js__("window.gamePushSDK.player.id") ?? "",
			name: untyped __js__("window.gamePushSDK.player.name") ?? "Guest",
			avatar: untyped __js__("window.gamePushSDK.player.avatar") ?? "",
			isLoggedIn: untyped __js__("window.gamePushSDK.player.isLoggedIn") ?? false,
			score: untyped __js__("window.gamePushSDK.player.get('score')") ?? 0
		};
		#else
		return {
			id: "",
			name: "Guest",
			avatar: "",
			isLoggedIn: false,
			score: 0
		};
		#end
	}

	function shouldWarmupLeaderboard():Bool {
		#if js
		var hasConnection = untyped __js__("typeof navigator !== 'undefined' && !!navigator.connection");
		if (!hasConnection)
			return false;

		var saveData:Bool = untyped __js__("!!navigator.connection.saveData");
		if (saveData)
			return false;

		var effectiveType:String = untyped __js__("navigator.connection.effectiveType || ''");
		return effectiveType == "4g";
		#else
		return false;
		#end
	}

	function getProviderLanguage():Null<String> {
		#if js
		if (!isGamePushAvailable())
			return null;
		return untyped __js__("window.gamePushSDK.language") ?? null;
		#else
		return null;
		#end
	}

	function isGamePushAvailable():Bool {
		#if js
		return untyped __js__("typeof window !== 'undefined' && !!window.gamePushSDK");
		#else
		return false;
		#end
	}

	function isPlayerAvailable():Bool {
		#if js
		return untyped __js__("typeof window !== 'undefined' && !!(window.gamePushSDK && window.gamePushSDK.player)");
		#else
		return false;
		#end
	}

	function isLeaderboardAvailable():Bool {
		#if js
		return untyped __js__("typeof window !== 'undefined' && !!(window.gamePushSDK && window.gamePushSDK.leaderboard)");
		#else
		return false;
		#end
	}

	function emitProgress(callback:BootstrapProgress->Void, stage:String, message:String, percent:Int):Void {
		if (callback == null)
			return;
		callback({
			stage: stage,
			message: message,
			percent: percent
		});
	}

	function createPendingSnapshot():BootstrapSnapshot {
		return {
			completed: false,
			gamePushAvailable: false,
			playerAvailable: false,
			leaderboardAvailable: false,
			fallbackToLocal: true,
			language: "en",
			languageSource: "default",
			saveProvider: "local",
			saveInfo: {
				mode: "local",
				cloudAvailable: false,
				localAvailable: true,
				cloudHadData: false
			},
			saves: {
				score: 0
			},
			player: null,
			adsStatus: null,
			leaderboardWarmup: null,
			warnings: [],
			startedAt: nowMs(),
			finishedAt: 0
		};
	}

	function nowMs():Float {
		return Date.now().getTime();
	}

	function copyKeys(keys:Array<String>):Array<String> {
		var out:Array<String> = [];
		for (key in keys) {
			out.push(key);
		}
		return out;
	}
}
