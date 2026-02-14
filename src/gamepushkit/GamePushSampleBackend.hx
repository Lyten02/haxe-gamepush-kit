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

	static inline var AD_PAUSE_TOKEN:String = "ads-blocking";
	static inline var PLATFORM_PAUSE_TOKEN:String = "platform-visibility";
	static final SAVE_FIELDS:Array<String> = ["score"];
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
		untyped __js__("window.gamePushSDK.leaderboard.open({tag: {0}})", tag);
		#end
	}

	function jsGetLeaderboardEntries(tag:String, limit:Int, onResult:Dynamic):Void {
		#if gamepush
		if (!GAMEPUSH_LEADERBOARD_API_CALLS_ENABLED) {
			if (onResult != null)
				onResult([]);
			return;
		}
		if (!isLeaderboardAvailable()) {
			if (onResult != null)
				onResult([]);
			return;
		}
		untyped __js__("
			window.gamePushSDK.leaderboard.fetch({tag: {0}, limit: {1}})
				.then(function(result) { if ({2}) {2}(result.players); })
				.catch(function(err) { console.error('Leaderboard fetch error:', err); if ({2}) {2}([]); });
		", tag, limit, onResult);
		#else
		if (onResult != null)
			onResult([]);
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
		untyped __js__("
			window.gamePushSDK.leaderboard.publishRecord({tag: {0}, record: {1}})
				.then(function() { if ({2}) {2}(true); })
				.catch(function() { if ({2}) {2}(false); });
		", tag, score, onComplete);
		#else
		if (onComplete != null)
			onComplete(false);
		#end
	}

	// ========== Language API ==========

	function jsGetLanguage():String {
		return currentLanguage;
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
