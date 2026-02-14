package gamepushkit;

import starter.IGame;
import starter.AppBase;
import gamepush.AdManager;
import gamepush.GamePush;
import gamepushkit.Bridge;
import gamepushkit.WebFocusLifecycle;
import gamepushkit.bootstrap.BootstrapCoordinator;
import gamepushkit.bootstrap.BootstrapTypes.BootstrapProgress;
import gamepushkit.bootstrap.BootstrapTypes.BootstrapSnapshot;
import gamepushkit.bootstrap.LanguageResolver;
import gamepushkit.bootstrap.SaveProvider;
import haxe.ds.StringMap;
import StringTools;

/**
 * GamePush Samples - Backend API.
 *
 * Весь UI рендерится в React.
 * Haxe/Heaps — только backend логика и GamePush API.
 *
 * Доступ из React: window.GamePushSamples.api.*
 */
class GamePushSampleBackend implements IGame {
	var app:hxd.App;
	var appBase:Null<AppBase> = null;
	var adManager:AdManager;
	var samples:Array<Dynamic>;
	var audioMuted:Bool = false;
	var manualAudioMuted:Bool = false;
	var adAudioMuteDepth:Int = 0;
	var adPauseDepth:Int = 0;
	var platformPaused:Bool = false;
	var platformAudioMuted:Bool = false;
	var gamePushPauseApplied:Bool = false;
	var webFocusLifecycle:Null<WebFocusLifecycle> = null;
	var bootstrapCoordinator:Null<BootstrapCoordinator> = null;
	var bootstrapSnapshot:BootstrapSnapshot;
	var saveProvider:Null<SaveProvider> = null;
	var currentLanguage:String = "en";
	var leaderboardFetchCache:StringMap<Dynamic> = new StringMap<Dynamic>();
	var leaderboardVariantByTag:StringMap<String> = new StringMap<String>();

	static inline var AD_PAUSE_TOKEN:String = "ads-blocking";
	static inline var PLATFORM_PAUSE_TOKEN:String = "platform-visibility";
	static final SAVE_FIELDS:Array<String> = ["score"];
	static inline var LEADERBOARD_CACHE_TTL_MS:Int = 60000;
	static inline var LEADERBOARD_DEFAULT_TAG:String = "main";
	static inline var LEADERBOARD_DEFAULT_LIMIT:Int = 10;
	static inline var LEADERBOARD_DEFAULT_VARIANT:String = "global";
	// Split API switches:
	// - Data API (player/login/provider writes)
	// - Leaderboard API (open/fetch/submit from UI sample)
	// - Ads API (show/close/refresh ads)
	// - Lifecycle API (gameStart/gameplayStart/pause/resume)
	// - Sounds API (sounds.mute/unmute)
	static inline var GAMEPUSH_DATA_API_CALLS_ENABLED:Bool = false;
	static inline var GAMEPUSH_LEADERBOARD_API_CALLS_ENABLED:Bool = true;
	static inline var GAMEPUSH_LANGUAGE_API_CALLS_ENABLED:Bool = true;
	static inline var GAMEPUSH_AD_API_CALLS_ENABLED:Bool = true;
	static inline var GAMEPUSH_LIFECYCLE_API_CALLS_ENABLED:Bool = true;
	static inline var GAMEPUSH_SOUNDS_API_CALLS_ENABLED:Bool = true;

	public function new(?samples:Array<Dynamic>) {
		this.samples = samples != null ? samples : defaultSamples();
		bootstrapSnapshot = defaultBootstrapSnapshot();
	}

	public function init(app:hxd.App):Void {
		this.app = app;
		appBase = Std.isOfType(app, AppBase) ? cast app : null;

		// Managers are created first; full readiness is published after bootstrap sequence.
		adManager = new AdManager();

		// Export API early, then block menu visibility in React until gdsite:ready arrives.
		exportAPI();
		initWebFocusLifecycle();
		runBootstrapSequence();
	}

	function runBootstrapSequence():Void {
		bootstrapCoordinator = new BootstrapCoordinator(adManager, defaultSaveValues(), SAVE_FIELDS);
		bootstrapSnapshot = bootstrapCoordinator.getSnapshot();
		currentLanguage = bootstrapSnapshot.language;

		bootstrapCoordinator.run(function(progress:BootstrapProgress) {
			Bridge.sendToReact("bootstrapProgress", progress);
		}, function(snapshot:BootstrapSnapshot) {
			bootstrapSnapshot = snapshot;
			saveProvider = bootstrapCoordinator != null ? bootstrapCoordinator.saveProvider : null;
			currentLanguage = snapshot.language;
			seedLeaderboardCache(snapshot);
			if (bootstrapCoordinator != null) {
				var warmupVariant = bootstrapCoordinator.getLeaderboardWarmupVariant();
				if (warmupVariant != null && StringTools.trim(warmupVariant) != "") {
					leaderboardVariantByTag.set(LEADERBOARD_DEFAULT_TAG, StringTools.trim(warmupVariant));
				}
			}
			syncProviderLanguageOnStartup();

			// Yandex Games 1.19: lifecycle starts only when session is genuinely ready for interaction.
			startGamePushLifecycle();

			Bridge.sendToReact("ready", {
				version: "1.0.0",
				samples: getSamplesList(),
				bootstrap: snapshot
			});
		});
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
		if (!GAMEPUSH_DATA_API_CALLS_ENABLED)
			return false;
		return untyped __js__("typeof window !== 'undefined' && !!(window.gamePushSDK && window.gamePushSDK.player)");
		#else
		return false;
		#end
	}

	function isLeaderboardAvailable():Bool {
		#if js
		if (!GAMEPUSH_LEADERBOARD_API_CALLS_ENABLED)
			return false;
		return untyped __js__("typeof window !== 'undefined' && !!(window.gamePushSDK && window.gamePushSDK.leaderboard)");
		#else
		return false;
		#end
	}

	#if gamepush
	function startGamePushLifecycle():Void {
		if (!GAMEPUSH_LIFECYCLE_API_CALLS_ENABLED)
			return;
		if (!isGamePushAvailable()) {
			trace("[Game] GamePush SDK not ready at init");
			return;
		}

		try {
			GamePush.gameStart();
			GamePush.gameplayStart();
		} catch (e) {
			trace('[Game] Failed to start GamePush lifecycle: $e');
		}
	}

	function stopGamePushLifecycle():Void {
		if (!GAMEPUSH_LIFECYCLE_API_CALLS_ENABLED)
			return;
		if (!isGamePushAvailable())
			return;

		try {
			GamePush.gameplayStop();
		} catch (e) {
			trace('[Game] Failed to stop GamePush lifecycle: $e');
		}
	}
	#else
	function startGamePushLifecycle():Void {}

	function stopGamePushLifecycle():Void {}
	#end

	function initWebFocusLifecycle():Void {
		webFocusLifecycle = new WebFocusLifecycle(function(isForeground:Bool, reason:String) {
			setPlatformInterruption(!isForeground, reason);
		});
		webFocusLifecycle.start();
	}

	function setPlatformInterruption(interrupted:Bool, reason:String):Void {
		if (platformPaused == interrupted && platformAudioMuted == interrupted)
			return;

		platformPaused = interrupted;
		platformAudioMuted = interrupted;

		applyPauseState();
		applyAudioMuteState();

		Bridge.sendToReact("platformFocusChanged", {
			foreground: !interrupted,
			reason: reason
		});
	}

	function exportAPI():Void {
		#if js
		var api = {
			ads: {
				showPreloader: jsShowPreloader,
				showFullscreen: jsShowFullscreen,
				showRewarded: jsShowRewarded,
				showSticky: jsShowSticky,
				closeSticky: jsCloseSticky,
				refreshSticky: jsRefreshSticky,
				isStickyShowing: jsIsStickyShowing,
				getStatus: jsGetAdsStatus,
				enableOverlayAutoShift: jsEnableOverlayAutoShift,
				disableOverlayAutoShift: jsDisableOverlayAutoShift,
				refreshOverlayAutoShift: jsRefreshOverlayAutoShift,
				getOverlayInsets: jsGetOverlayInsets
			},
			player: {
				getId: jsGetPlayerId,
				getName: jsGetPlayerName,
				getScore: jsGetPlayerScore,
				setScore: jsSetPlayerScore,
				getAvatar: jsGetPlayerAvatar,
				isLoggedIn: jsIsPlayerLoggedIn,
				login: jsPlayerLogin
			},
			leaderboard: {
				open: jsOpenLeaderboard,
				getEntries: jsGetLeaderboardEntries,
				submitScore: jsSubmitScore
			},
			language: {
				getCurrent: jsGetLanguage,
				change: jsChangeLanguage
			},
			saves: {
				get: jsGetSave,
				set: jsSetSave,
				sync: jsSyncSaves
			},
			audio: {
				mute: jsMuteAudio,
				unmute: jsUnmuteAudio,
				isMuted: jsIsAudioMuted
			},
			bootstrap: {
				getSnapshot: jsGetBootstrapSnapshot,
				getLeaderboardWarmup: jsGetBootstrapLeaderboardWarmup
			},
			getSamplesList: function() {
				return getSamplesList();
			}
		};

		untyped __js__("
			if (!window.GamePushSamples) window.GamePushSamples = {};
			window.GamePushSamples.api = {0};
		", api);
		#end
	}

	static function defaultSamples():Array<Dynamic> {
		return [
			{id: "ads", name: "Ads", description: "Test all ad types: preloader, fullscreen, rewarded, sticky"},
			{id: "saves", name: "Saves", description: "Cloud saves and local storage"},
			{id: "language", name: "Language", description: "Localization and language detection"},
			{id: "leaderboard", name: "Leaderboard", description: "Leaderboards and player ratings"},
			{id: "audio", name: "Audio", description: "Audio control and ad muting"},
			{id: "player", name: "Player", description: "Player data and authentication"}
		];
	}

	function defaultSaveValues():Dynamic {
		return {
			score: 0
		};
	}

	function defaultBootstrapSnapshot():BootstrapSnapshot {
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
			saves: defaultSaveValues(),
			player: null,
			adsStatus: null,
			leaderboardWarmup: null,
			warnings: [],
			startedAt: Date.now().getTime(),
			finishedAt: 0
		};
	}

	function getSamplesList():Array<Dynamic> {
		return samples;
	}

	function resolveSaveKey(key:String):String {
		return key == "testKey" ? "score" : key;
	}

	function updateSnapshotSave(key:String, value:Dynamic):Void {
		if (bootstrapSnapshot == null)
			return;
		if (bootstrapSnapshot.saves == null)
			bootstrapSnapshot.saves = {};
		Reflect.setField(bootstrapSnapshot.saves, key, value);
	}

	function getSaveValueFromSnapshot(key:String):Dynamic {
		if (bootstrapSnapshot == null || bootstrapSnapshot.saves == null)
			return null;
		return Reflect.field(bootstrapSnapshot.saves, key);
	}

	function activeSaveProvider():Null<SaveProvider> {
		if (saveProvider != null)
			return saveProvider;
		if (bootstrapCoordinator != null && bootstrapCoordinator.saveProvider != null) {
			saveProvider = bootstrapCoordinator.saveProvider;
			return saveProvider;
		}
		return null;
	}

	function normalizeLeaderboardTag(tag:String):String {
		if (tag == null)
			return LEADERBOARD_DEFAULT_TAG;
		var trimmed = StringTools.trim(tag);
		return trimmed != "" ? trimmed : LEADERBOARD_DEFAULT_TAG;
	}

	function leaderboardCacheKey(tag:String, limit:Int):String {
		var safeTag = normalizeLeaderboardTag(tag);
		var safeLimit = limit > 0 ? limit : LEADERBOARD_DEFAULT_LIMIT;
		return safeTag + "|" + Std.string(safeLimit);
	}

	function cloneLeaderboardEntries(entries:Array<Dynamic>):Array<Dynamic> {
		var copy:Array<Dynamic> = [];
		if (entries == null)
			return copy;
		for (entry in entries) {
			copy.push(entry);
		}
		return copy;
	}

	function cacheLeaderboardEntries(tag:String, limit:Int, entries:Array<Dynamic>, ?source:String = "fetch"):Void {
		if (entries == null)
			return;

		leaderboardFetchCache.set(leaderboardCacheKey(tag, limit), {
			fetchedAt: Date.now().getTime(),
			source: source,
			entries: cloneLeaderboardEntries(entries)
		});
	}

	function getCachedLeaderboardRecord(tag:String, limit:Int):Dynamic {
		var key = leaderboardCacheKey(tag, limit);
		var cached = leaderboardFetchCache.get(key);
		if (cached == null)
			return null;

		var fetchedAt:Float = Reflect.field(cached, "fetchedAt");
		if (Date.now().getTime() - fetchedAt > LEADERBOARD_CACHE_TTL_MS) {
			leaderboardFetchCache.remove(key);
			return null;
		}
		return cached;
	}

	function getCachedLeaderboardEntries(tag:String, limit:Int):Null<Array<Dynamic>> {
		var cached = getCachedLeaderboardRecord(tag, limit);
		if (cached == null)
			return null;

		var entries:Array<Dynamic> = cast Reflect.field(cached, "entries");
		if (entries == null)
			return null;

		return cloneLeaderboardEntries(entries);
	}

	function invalidateLeaderboardCache(?tag:String):Void {
		if (tag == null || tag == "") {
			leaderboardFetchCache = new StringMap<Dynamic>();
			return;
		}

		for (key in leaderboardFetchCache.keys()) {
			var parts = key.split("|");
			if (parts.length > 0 && parts[0] == tag) {
				leaderboardFetchCache.remove(key);
			}
		}
	}

	function seedLeaderboardCache(snapshot:BootstrapSnapshot):Void {
		if (snapshot == null || snapshot.leaderboardWarmup == null)
			return;

		var warmup:Array<Dynamic> = cast snapshot.leaderboardWarmup;
		if (warmup == null || warmup.length == 0)
			return;

		cacheLeaderboardEntries(LEADERBOARD_DEFAULT_TAG, LEADERBOARD_DEFAULT_LIMIT, warmup, "warmup");
	}

	function normalizeVariant(value:Dynamic):Null<String> {
		if (value == null)
			return null;
		if (!Std.isOfType(value, String))
			return null;
		var variant = StringTools.trim(cast value);
		return variant != "" ? variant : null;
	}

	function rememberLeaderboardVariant(tag:String, fetchResult:Dynamic):Void {
		var safeTag = normalizeLeaderboardTag(tag);
		var variant = normalizeVariant(Reflect.field(fetchResult, "variant"));
		if (variant == null) {
			var leaderboardMeta:Dynamic = Reflect.field(fetchResult, "leaderboard");
			if (leaderboardMeta != null) {
				variant = normalizeVariant(Reflect.field(leaderboardMeta, "variant"));
				if (variant == null)
					variant = normalizeVariant(Reflect.field(leaderboardMeta, "defaultVariant"));
			}
		}

		if (variant != null) {
			leaderboardVariantByTag.set(safeTag, variant);
		}
	}

	function resolveLeaderboardVariant(tag:String):String {
		var safeTag = normalizeLeaderboardTag(tag);
		var known = leaderboardVariantByTag.get(safeTag);
		if (known != null) {
			var trimmed = StringTools.trim(known);
			if (trimmed != "")
				return trimmed;
		}
		return LEADERBOARD_DEFAULT_VARIANT;
	}

	// ========== Ads API ==========

	function withBlockingAd(showAd:(Void->Void)->Void, onComplete:Dynamic, adLabel:String):Void {
		if (!GAMEPUSH_AD_API_CALLS_ENABLED) {
			if (onComplete != null)
				onComplete();
			return;
		}

		pushAdAudioMute();
		pushAdPause();

		var finished = false;
		var release = function() {
			if (finished)
				return;

			finished = true;
			popAdPause();
			popAdAudioMute();
			if (onComplete != null)
				onComplete();
		};

		try {
			showAd(release);
		} catch (e) {
			trace('[Game] Failed to show ${adLabel} ad: $e');
			release();
		}
	}

	function jsShowPreloader(onComplete:Dynamic):Void {
		withBlockingAd(function(onAdClosed:Void->Void) {
			adManager.showPreloader(onAdClosed);
		}, onComplete, "preloader");
	}

	function jsShowFullscreen(onComplete:Dynamic):Void {
		withBlockingAd(function(onAdClosed:Void->Void) {
			adManager.showFullscreen(onAdClosed);
		}, onComplete, "fullscreen");
	}

	function jsShowRewarded(onReward:Dynamic, onClose:Dynamic):Void {
		withBlockingAd(function(onAdClosed:Void->Void) {
			adManager.showRewarded(function() {
				if (onReward != null)
					onReward();
			}, onAdClosed);
		}, onClose, "rewarded");
	}

	function jsShowSticky():Void {
		if (!GAMEPUSH_AD_API_CALLS_ENABLED)
			return;
		adManager.showSticky();
	}

	function jsCloseSticky():Void {
		if (!GAMEPUSH_AD_API_CALLS_ENABLED)
			return;
		adManager.closeSticky();
	}

	function jsRefreshSticky():Void {
		if (!GAMEPUSH_AD_API_CALLS_ENABLED)
			return;
		adManager.refreshSticky();
	}

	function jsIsStickyShowing():Bool {
		return adManager.isStickyShowing();
	}

	function jsGetAdsStatus():Dynamic {
		var status = adManager.getStatus();
		if (bootstrapSnapshot != null) {
			bootstrapSnapshot.adsStatus = status;
		}
		return status;
	}

	function jsEnableOverlayAutoShift(options:Dynamic):Void {
		adManager.enableOverlayAutoShift(cast options);
	}

	function jsDisableOverlayAutoShift():Void {
		adManager.disableOverlayAutoShift();
	}

	function jsRefreshOverlayAutoShift():Void {
		adManager.refreshOverlayAutoShift();
	}

	function jsGetOverlayInsets():Dynamic {
		return adManager.getOverlayInsets();
	}

	// ========== Player API ==========

	function jsGetPlayerId():String {
		#if gamepush
		if (isPlayerAvailable())
			return untyped __js__("window.gamePushSDK.player.id") ?? "";
		#end
		if (bootstrapSnapshot != null && bootstrapSnapshot.player != null) {
			return Reflect.field(bootstrapSnapshot.player, "id") ?? "";
		}
		return "";
	}

	function jsGetPlayerName():String {
		#if gamepush
		if (isPlayerAvailable())
			return untyped __js__("window.gamePushSDK.player.name") ?? "Guest";
		#end
		if (bootstrapSnapshot != null && bootstrapSnapshot.player != null) {
			return Reflect.field(bootstrapSnapshot.player, "name") ?? "Guest";
		}
		return "Guest";
	}

	function jsGetPlayerScore():Int {
		#if gamepush
		if (GAMEPUSH_DATA_API_CALLS_ENABLED && isPlayerAvailable()) {
			var cloudScore = untyped __js__("window.gamePushSDK.player.get('score')");
			if (cloudScore != null)
				return cloudScore;
		}
		#end

		var provider = activeSaveProvider();
		if (provider != null) {
			var value = provider.get("score");
			if (value != null)
				return value;
		}

		var fallback = getSaveValueFromSnapshot("score");
		return fallback != null ? fallback : 0;
	}

	function jsSetPlayerScore(score:Int):Void {
		var provider = activeSaveProvider();
		if (provider != null) {
			provider.set("score", score);
		}
		updateSnapshotSave("score", score);
		invalidateLeaderboardCache();

		#if gamepush
		if (!GAMEPUSH_DATA_API_CALLS_ENABLED)
			return;
		if (!isPlayerAvailable())
			return;
		untyped __js__("window.gamePushSDK.player.set('score', {0})", score);
		#end
	}

	function jsGetPlayerAvatar():String {
		#if gamepush
		if (isPlayerAvailable())
			return untyped __js__("window.gamePushSDK.player.avatar") ?? "";
		#end
		if (bootstrapSnapshot != null && bootstrapSnapshot.player != null) {
			return Reflect.field(bootstrapSnapshot.player, "avatar") ?? "";
		}
		return "";
	}

	function jsIsPlayerLoggedIn():Bool {
		#if gamepush
		if (isPlayerAvailable())
			return untyped __js__("window.gamePushSDK.player.isLoggedIn") ?? false;
		#end
		if (bootstrapSnapshot != null && bootstrapSnapshot.player != null) {
			var value = Reflect.field(bootstrapSnapshot.player, "isLoggedIn");
			return value == true;
		}
		return false;
	}

	function jsPlayerLogin(onSuccess:Dynamic, onError:Dynamic):Void {
		#if gamepush
		if (!GAMEPUSH_DATA_API_CALLS_ENABLED) {
			if (onError != null)
				onError("GamePush API calls are disabled");
			return;
		}
		if (!isPlayerAvailable()) {
			if (onError != null)
				onError("GamePush SDK not ready");
			return;
		}

		untyped __js__("
			window.gamePushSDK.player.login()
				.then(function() { if ({0}) {0}(); })
				.catch(function(err) { if ({1}) {1}(err); });
		", onSuccess, onError);
		#else
		if (onError != null)
			onError("Player login unavailable in non-GamePush build");
		#end
	}

	// ========== Leaderboard API ==========

	function jsOpenLeaderboard(tag:String):Void {
		#if gamepush
		if (!GAMEPUSH_LEADERBOARD_API_CALLS_ENABLED)
			return;
		if (!isLeaderboardAvailable())
			return;
		var safeTag = normalizeLeaderboardTag(tag);
		var opened = false;
		var openOnce = function():Void {
			if (opened)
				return;
			opened = true;
			untyped __js__("window.gamePushSDK.leaderboard.open({tag: {0}})", safeTag);
		};

		if (GAMEPUSH_LANGUAGE_API_CALLS_ENABLED && isGamePushAvailable()) {
			try {
				var targetLanguage = currentLanguage;
					var syncPromise:Dynamic = untyped __js__("
						(function(targetLang) {
							var sdk = window.gamePushSDK;
							if (!sdk || typeof sdk.changeLanguage !== 'function') return Promise.resolve();
							var callChange = function(lang) {
								try {
									var result = sdk.changeLanguage(lang);
								if (result && typeof result.then === 'function') return result;
								return Promise.resolve(result);
							} catch (err) {
								return Promise.reject(err);
							}
						};
							var fallbackLang = targetLang === 'en' ? 'ru' : 'en';
							return callChange(fallbackLang)
								.catch(function() { return null; })
								.then(function() { return callChange(targetLang); });
						})({0})
					", targetLanguage);
				var syncThen:Dynamic = syncPromise != null ? Reflect.field(syncPromise, "then") : null;
				if (syncThen != null) {
					Reflect.callMethod(syncPromise, syncThen, [function(_):Dynamic {
						haxe.Timer.delay(function() {
							openOnce();
						}, 50);
						return null;
					}]);

					var syncCatch:Dynamic = Reflect.field(syncPromise, "catch");
					if (syncCatch != null) {
						Reflect.callMethod(syncPromise, syncCatch, [function(err:Dynamic):Dynamic {
							untyped __js__("console.warn('Failed to force language before leaderboard open:', {0})", err);
							openOnce();
							return null;
						}]);
					}
					return;
				}
			} catch (e) {
				trace('[Game] Failed to force language before leaderboard open: $e');
			}
		}

		openOnce();
		#end
	}

	function jsGetLeaderboardEntries(tag:String, limit:Int, onResult:Dynamic):Void {
		#if gamepush
		if (!GAMEPUSH_LEADERBOARD_API_CALLS_ENABLED) {
			if (onResult != null)
				onResult([]);
			return;
		}

		var cacheRecord = getCachedLeaderboardRecord(tag, limit);
		var cached = cacheRecord != null ? cast Reflect.field(cacheRecord, "entries") : null;

		if (!isLeaderboardAvailable()) {
			if (onResult != null)
				onResult(cached != null ? cloneLeaderboardEntries(cached) : []);
			return;
		}

		try {
			var fetchPromise:Dynamic = untyped __js__("window.gamePushSDK.leaderboard.fetch({tag: {0}, limit: {1}})", tag, limit);
			var fetchChain:Dynamic = untyped fetchPromise.then(function(result:Dynamic):Dynamic {
				rememberLeaderboardVariant(tag, result);
				var players:Array<Dynamic> = [];
				if (result != null && Reflect.hasField(result, "players")) {
					players = cast Reflect.field(result, "players");
				}
				cacheLeaderboardEntries(tag, limit, players);
				if (onResult != null)
					onResult(players);
				return null;
			});

			var fetchCatch:Dynamic = Reflect.field(fetchChain, "catch");
			if (fetchCatch != null) {
				Reflect.callMethod(fetchChain, fetchCatch, [function(err:Dynamic):Dynamic {
					untyped __js__("console.error('Leaderboard fetch error:', {0})", err);
					if (onResult != null)
						onResult(cached != null ? cloneLeaderboardEntries(cached) : []);
					return null;
				}]);
			}

		} catch (err) {
			if (onResult != null)
				onResult(cached != null ? cloneLeaderboardEntries(cached) : []);
		}
		#else
		if (onResult != null)
				onResult([]);
		#end
	}

	function publishScoreToLeaderboard(tag:String, score:Int, onComplete:Bool->Void):Void {
		#if gamepush
		if (!GAMEPUSH_LEADERBOARD_API_CALLS_ENABLED || !isLeaderboardAvailable()) {
			if (onComplete != null)
				onComplete(false);
			return;
		}

		var resolvedTag = normalizeLeaderboardTag(tag);

			var publishWithKnownVariant:Void->Void = null;
			publishWithKnownVariant = function():Void {
				var resolvedVariant = resolveLeaderboardVariant(resolvedTag);

				try {
					var payload:Dynamic = {
						tag: resolvedTag,
						variant: resolvedVariant,
						record: {score: score}
					};
					var publishPromise:Dynamic = untyped __js__("window.gamePushSDK.leaderboard.publishRecord({0})", payload);
					var publishChain:Dynamic = untyped publishPromise.then(function(_):Dynamic {
						invalidateLeaderboardCache(resolvedTag);
						if (onComplete != null)
							onComplete(true);
						return null;
					});

					var publishCatch:Dynamic = Reflect.field(publishChain, "catch");
					if (publishCatch != null) {
						Reflect.callMethod(publishChain, publishCatch, [function(err:Dynamic):Dynamic {
							untyped __js__("console.warn('Leaderboard publish unavailable for current config:', {0}, {1}, {2})", resolvedTag, resolvedVariant, err);
							if (onComplete != null)
								onComplete(false);
							return null;
						}]);
					}
				} catch (err) {
					untyped __js__("console.warn('Leaderboard publish exception:', {0}, {1}, {2})", resolvedTag, resolvedVariant, err);
					if (onComplete != null)
						onComplete(false);
				}
		};

		var knownVariant = resolveLeaderboardVariant(resolvedTag);
		if (knownVariant != LEADERBOARD_DEFAULT_VARIANT) {
			publishWithKnownVariant();
			return;
		}

		try {
			var fetchPromise:Dynamic = untyped __js__("window.gamePushSDK.leaderboard.fetch({tag: {0}, limit: 1})", resolvedTag);
			var fetchChain:Dynamic = untyped fetchPromise.then(function(result:Dynamic):Dynamic {
				rememberLeaderboardVariant(resolvedTag, result);
				publishWithKnownVariant();
				return null;
			});

			var fetchCatch:Dynamic = Reflect.field(fetchChain, "catch");
			if (fetchCatch != null) {
				Reflect.callMethod(fetchChain, fetchCatch, [function(err:Dynamic):Dynamic {
					untyped __js__("console.warn('Leaderboard variant fetch failed, publishing with fallback variant:', {0}, {1})", resolvedTag, err);
					publishWithKnownVariant();
					return null;
				}]);
			}
			return;
		} catch (err) {
			untyped __js__("console.warn('Leaderboard variant fetch exception, publishing with fallback variant:', {0}, {1})", resolvedTag, err);
		}

		publishWithKnownVariant();
		#else
		if (onComplete != null)
			onComplete(false);
		#end
	}

	function jsSubmitScore(tag:String, score:Int, onComplete:Dynamic):Void {
		#if gamepush
		if (!GAMEPUSH_LEADERBOARD_API_CALLS_ENABLED) {
			if (onComplete != null)
				onComplete(false);
			return;
		}
		if (!isLeaderboardAvailable()) {
			if (onComplete != null)
				onComplete(false);
			return;
		}

		var resolvedTag = normalizeLeaderboardTag(tag);

		var provider = activeSaveProvider();
		if (provider != null && provider.mode == "cloud" && provider.cloudAvailable) {
			provider.set("score", score);
			updateSnapshotSave("score", score);

			provider.sync(function(success:Bool) {
				if (!success) {
					untyped __js__("console.warn('Score sync failed, trying direct leaderboard publish')");
					publishScoreToLeaderboard(resolvedTag, score, function(published:Bool):Void {
						if (onComplete != null)
							onComplete(published);
					});
					return;
				}

				if (bootstrapSnapshot != null) {
					bootstrapSnapshot.saves = provider.snapshot();
					bootstrapSnapshot.saveInfo = provider.state();
					if (bootstrapSnapshot.player != null)
						Reflect.setField(bootstrapSnapshot.player, "score", score);
				}

				publishScoreToLeaderboard(resolvedTag, score, function(published:Bool):Void {
					if (!published) {
						untyped __js__("console.warn('Score synced, but leaderboard publish is unavailable (check leaderboard tag/variant in dashboard).')");
					}
					if (onComplete != null)
						onComplete(true);
				});
			});
			return;
		}

		publishScoreToLeaderboard(resolvedTag, score, function(published:Bool):Void {
			if (onComplete != null)
				onComplete(published);
		});
		#else
		if (onComplete != null)
			onComplete(false);
		#end
	}

	// ========== Language API ==========

	function jsGetLanguage():String {
		return currentLanguage;
	}

	function syncProviderLanguageOnStartup():Void {
		#if gamepush
		if (!GAMEPUSH_LANGUAGE_API_CALLS_ENABLED)
			return;
		if (!isGamePushAvailable())
			return;

		try {
			// Force provider dictionaries refresh for non-English locales.
			if (currentLanguage != "en")
				untyped __js__("window.gamePushSDK.changeLanguage('en')");
			untyped __js__("window.gamePushSDK.changeLanguage({0})", currentLanguage);
		} catch (e) {
			trace('[Game] Failed to sync provider language on startup: $e');
		}
		#end
	}

	function jsChangeLanguage(lang:String):Void {
		var normalized = bootstrapCoordinator != null
			? bootstrapCoordinator.applyManualLanguage(lang)
			: LanguageResolver.normalize(lang);
		currentLanguage = normalized;

		if (bootstrapSnapshot != null) {
			bootstrapSnapshot.language = currentLanguage;
			bootstrapSnapshot.languageSource = "manual";
		}

		#if gamepush
		if (GAMEPUSH_LANGUAGE_API_CALLS_ENABLED && isGamePushAvailable()) {
			try {
				untyped __js__("window.gamePushSDK.changeLanguage({0})", currentLanguage);
			} catch (e) {
				trace('[Game] Failed to change provider language: $e');
			}
		}
		#end

		Bridge.sendToReact("languageChanged", {language: currentLanguage});
	}

	// ========== Saves API ==========

	function jsGetSave(key:String):Dynamic {
		var resolvedKey = resolveSaveKey(key);
		var provider = activeSaveProvider();
		if (provider != null) {
			return provider.get(resolvedKey);
		}
		return getSaveValueFromSnapshot(resolvedKey);
	}

	function jsSetSave(key:String, value:Dynamic):Void {
		var resolvedKey = resolveSaveKey(key);
		var provider = activeSaveProvider();
		if (provider != null) {
			provider.set(resolvedKey, value);
		}
		updateSnapshotSave(resolvedKey, value);
		if (resolvedKey == "score")
			invalidateLeaderboardCache();
	}

	function jsSyncSaves(onComplete:Dynamic):Void {
		var provider = activeSaveProvider();
		if (provider == null) {
			if (onComplete != null)
				onComplete(false);
			return;
		}

		provider.sync(function(success:Bool) {
			if (bootstrapSnapshot != null) {
				bootstrapSnapshot.saves = provider.snapshot();
				bootstrapSnapshot.saveInfo = provider.state();
			}
			if (success)
				invalidateLeaderboardCache();

			if (onComplete != null)
				onComplete(success);
		});
	}

	function jsGetBootstrapSnapshot():Dynamic {
		return bootstrapSnapshot;
	}

	function jsGetBootstrapLeaderboardWarmup():Dynamic {
		if (bootstrapCoordinator != null) {
			return bootstrapCoordinator.getLeaderboardWarmup();
		}
		return bootstrapSnapshot != null ? bootstrapSnapshot.leaderboardWarmup : null;
	}

	// ========== Audio API ==========

	function applyGamePushSoundState(shouldMute:Bool):Void {
		#if gamepush
		if (!GAMEPUSH_SOUNDS_API_CALLS_ENABLED)
			return;
		if (!isGamePushAvailable())
			return;

		try {
			if (shouldMute) {
				untyped __js__("
					if (window.gamePushSDK && window.gamePushSDK.sounds && window.gamePushSDK.sounds.mute) {
						if (!window.gamePushSDK.sounds.isMuted) {
							window.gamePushSDK.sounds.mute();
						}
					}
				");
			} else {
				untyped __js__("
					if (window.gamePushSDK && window.gamePushSDK.sounds && window.gamePushSDK.sounds.unmute) {
						if (window.gamePushSDK.sounds.isMuted) {
							window.gamePushSDK.sounds.unmute();
						}
					}
				");
			}
		} catch (e) {
			trace('[Game] Failed to apply GamePush sound state: $e');
		}
		#end
	}

	function applyAudioMuteState():Void {
		var nextMuted = manualAudioMuted || adAudioMuteDepth > 0 || platformAudioMuted;
		if (nextMuted == audioMuted)
			return;
		audioMuted = nextMuted;
		applyGamePushSoundState(audioMuted);

		if (audioMuted)
			Bridge.sendToReact("audioMuted", {});
		else
			Bridge.sendToReact("audioUnmuted", {});
	}

	function pushAdAudioMute():Void {
		adAudioMuteDepth++;
		applyAudioMuteState();
	}

	function popAdAudioMute():Void {
		if (adAudioMuteDepth > 0)
			adAudioMuteDepth--;
		applyAudioMuteState();
	}

	function applyPauseState():Void {
		if (appBase != null) {
			appBase.setPauseToken(AD_PAUSE_TOKEN, adPauseDepth > 0);
			appBase.setPauseToken(PLATFORM_PAUSE_TOKEN, platformPaused);
		}
		applyGamePushPauseState();
	}

	function applyGamePushPauseState():Void {
		var shouldPause = adPauseDepth > 0 || platformPaused;

		#if gamepush
		if (!GAMEPUSH_LIFECYCLE_API_CALLS_ENABLED) {
			gamePushPauseApplied = shouldPause;
			return;
		}
		if (gamePushPauseApplied == shouldPause)
			return;

		if (!isGamePushAvailable())
			return;

		try {
			if (shouldPause) {
				GamePush.gameplayStop();
				GamePush.pause();
			} else {
				GamePush.resume();
				GamePush.gameplayStart();
			}
			gamePushPauseApplied = shouldPause;
		} catch (e) {
			trace('[Game] Failed to toggle GamePush pause state: $e');
		}
		#else
		gamePushPauseApplied = shouldPause;
		#end
	}

	function pushAdPause():Void {
		adPauseDepth++;
		applyPauseState();
	}

	function popAdPause():Void {
		if (adPauseDepth > 0)
			adPauseDepth--;
		applyPauseState();
	}

	function jsMuteAudio():Void {
		manualAudioMuted = true;
		applyAudioMuteState();
	}

	function jsUnmuteAudio():Void {
		manualAudioMuted = false;
		applyAudioMuteState();
	}

	function jsIsAudioMuted():Bool {
		return audioMuted;
	}

	// ========== IGame Interface ==========

	public function update(dt:Float):Void {
		if (adManager != null)
			adManager.update(dt);
	}

	public function dispose():Void {
		if (webFocusLifecycle != null) {
			webFocusLifecycle.dispose();
			webFocusLifecycle = null;
		}

		adPauseDepth = 0;
		platformPaused = false;
		gamePushPauseApplied = false;

		if (appBase != null) {
			appBase.setPauseToken(AD_PAUSE_TOKEN, false);
			appBase.setPauseToken(PLATFORM_PAUSE_TOKEN, false);
		}

		adAudioMuteDepth = 0;
		platformAudioMuted = false;
		manualAudioMuted = false;
		applyAudioMuteState();

		stopGamePushLifecycle();
		bootstrapCoordinator = null;
		saveProvider = null;
		adManager = null;
	}
}
