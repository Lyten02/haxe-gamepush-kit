package gamepushkit;

import starter.IGame;
import starter.AppBase;
import gamepush.AdManager;
import gamepush.GamePush;
import gamepushkit.Bridge;
import gamepushkit.WebFocusLifecycle;

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
	static inline var AD_PAUSE_TOKEN:String = "ads-blocking";
	static inline var PLATFORM_PAUSE_TOKEN:String = "platform-visibility";

	public function new(?samples:Array<Dynamic>) {
		this.samples = samples != null ? samples : defaultSamples();
	}

	public function init(app:hxd.App):Void {
		this.app = app;
		appBase = Std.isOfType(app, AppBase) ? cast app : null;

		// Initialize managers
		adManager = new AdManager();
		// Yandex Games 1.19: lifecycle is started when game session is actually ready for interaction.
		startGamePushLifecycle();

		// Export API to window for React
		exportAPI();
		initWebFocusLifecycle();

		// Notify React that Haxe backend is ready
		Bridge.sendToReact("ready", {
			version: "1.0.0",
			samples: getSamplesList()
		});
	}

	#if gamepush
	function isGamePushAvailable():Bool {
		return untyped __js__("typeof window !== 'undefined' && !!window.gamePushSDK");
	}

	function isPlayerAvailable():Bool {
		return untyped __js__("typeof window !== 'undefined' && !!(window.gamePushSDK && window.gamePushSDK.player)");
	}

	function isLeaderboardAvailable():Bool {
		return untyped __js__("typeof window !== 'undefined' && !!(window.gamePushSDK && window.gamePushSDK.leaderboard)");
	}

	function startGamePushLifecycle():Void {
		if (!isGamePushAvailable()) {
			trace("[Game] GamePush SDK not ready at init");
			return;
		}

		try {
			// Yandex Games 1.19 (Game Ready / gameplay): session starts only when game can be interacted with.
			GamePush.gameStart();
			GamePush.gameplayStart();
		} catch (e) {
			trace('[Game] Failed to start GamePush lifecycle: $e');
		}
	}

	function stopGamePushLifecycle():Void {
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

		// Yandex Games 1.3 allows up to 2s delay, but we pause immediately on focus loss.
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
			// Ads API
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

			// Player API
			player: {
				getId: jsGetPlayerId,
				getName: jsGetPlayerName,
				getScore: jsGetPlayerScore,
				setScore: jsSetPlayerScore,
				getAvatar: jsGetPlayerAvatar,
				isLoggedIn: jsIsPlayerLoggedIn,
				login: jsPlayerLogin
			},

			// Leaderboard API
			leaderboard: {
				open: jsOpenLeaderboard,
				getEntries: jsGetLeaderboardEntries,
				submitScore: jsSubmitScore
			},

			// Language API
			language: {
				getCurrent: jsGetLanguage,
				change: jsChangeLanguage
			},

			// Saves API
			saves: {
				get: jsGetSave,
				set: jsSetSave,
				sync: jsSyncSaves
			},

			// Audio API
			audio: {
				mute: jsMuteAudio,
				unmute: jsUnmuteAudio,
				isMuted: jsIsAudioMuted
			},

			// Utility
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

	function getSamplesList():Array<Dynamic> {
		return samples;
	}

	// ========== Ads API ==========

	function withBlockingAd(showAd:(Void->Void)->Void, onComplete:Dynamic, adLabel:String):Void {
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
		adManager.showSticky();
	}

	function jsCloseSticky():Void {
		adManager.closeSticky();
	}

	function jsRefreshSticky():Void {
		adManager.refreshSticky();
	}

	function jsIsStickyShowing():Bool {
		return adManager.isStickyShowing();
	}

	function jsGetAdsStatus():Dynamic {
		return adManager.getStatus();
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
		if (!isPlayerAvailable())
			return "";
		return untyped __js__("window.gamePushSDK.player.id") ?? "";
		#else
		return "player_123";
		#end
	}

	function jsGetPlayerName():String {
		#if gamepush
		if (!isPlayerAvailable())
			return "Guest";
		return untyped __js__("window.gamePushSDK.player.name") ?? "Guest";
		#else
		return "Test Player";
		#end
	}

	function jsGetPlayerScore():Int {
		#if gamepush
		if (!isPlayerAvailable())
			return 0;
		return untyped __js__("window.gamePushSDK.player.score") ?? 0;
		#else
		return 1000;
		#end
	}

	function jsSetPlayerScore(score:Int):Void {
		#if gamepush
		if (!isPlayerAvailable())
			return;
		untyped __js__("window.gamePushSDK.player.set('score', {0})", score);
		#end
	}

	function jsGetPlayerAvatar():String {
		#if gamepush
		if (!isPlayerAvailable())
			return "";
		return untyped __js__("window.gamePushSDK.player.avatar") ?? "";
		#else
		return "";
		#end
	}

	function jsIsPlayerLoggedIn():Bool {
		#if gamepush
		if (!isPlayerAvailable())
			return false;
		return untyped __js__("window.gamePushSDK.player.isLoggedIn") ?? false;
		#else
		return true;
		#end
	}

	function jsPlayerLogin(onSuccess:Dynamic, onError:Dynamic):Void {
		#if gamepush
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
		if (onSuccess != null)
			onSuccess();
		#end
	}

	// ========== Leaderboard API ==========

	function jsOpenLeaderboard(tag:String):Void {
		#if gamepush
		if (!isLeaderboardAvailable())
			return;
		untyped __js__("window.gamePushSDK.leaderboard.open({tag: {0}})", tag);
		#end
	}

	function jsGetLeaderboardEntries(tag:String, limit:Int, onResult:Dynamic):Void {
		#if gamepush
		if (!isLeaderboardAvailable()) {
			if (onResult != null)
				onResult([]);
			return;
		}
		untyped __js__("
			window.gamePushSDK.leaderboard.fetch({tag: {0}, limit: {1}})
				.then(function(result) { if ({2}) {2}(result.players); })
				.catch(function(err) { console.error('Leaderboard fetch error:', err); });
		", tag, limit, onResult);
		#else
		if (onResult != null)
			onResult([
				{name: "Player 1", score: 5000},
				{name: "Player 2", score: 4000},
				{name: "Player 3", score: 3000}
			]);
		#end
	}

	function jsSubmitScore(tag:String, score:Int, onComplete:Dynamic):Void {
		#if gamepush
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
			onComplete(true);
		#end
	}

	// ========== Language API ==========

	function jsGetLanguage():String {
		#if gamepush
		if (!isGamePushAvailable())
			return "en";
		return untyped __js__("window.gamePushSDK.language") ?? "en";
		#else
		return "en";
		#end
	}

	function jsChangeLanguage(lang:String):Void {
		#if gamepush
		if (isGamePushAvailable())
			untyped __js__("window.gamePushSDK.changeLanguage({0})", lang);
		#end
		Bridge.sendToReact("languageChanged", {language: lang});
	}

	// ========== Saves API ==========

	function resolveSaveKey(key:String):String {
		// Keep backward compatibility for the sample button "testKey".
		// We map it to "score" because this field exists in Player sample.
		return key == "testKey" ? "score" : key;
	}

	function jsGetSave(key:String):Dynamic {
		#if gamepush
		if (!isPlayerAvailable())
			return null;
		var resolvedKey = resolveSaveKey(key);
		return untyped __js__("window.gamePushSDK.player.get({0})", resolvedKey);
		#else
		return null;
		#end
	}

	function jsSetSave(key:String, value:Dynamic):Void {
		#if gamepush
		if (!isPlayerAvailable())
			return;
		var resolvedKey = resolveSaveKey(key);
		untyped __js__("window.gamePushSDK.player.set({0}, {1})", resolvedKey, value);
		#end
	}

	function jsSyncSaves(onComplete:Dynamic):Void {
		#if gamepush
		if (!isPlayerAvailable()) {
			if (onComplete != null)
				onComplete(false);
			return;
		}
		untyped __js__("
			window.gamePushSDK.player.sync()
				.then(function() { if ({0}) {0}(true); })
				.catch(function() { if ({0}) {0}(false); });
		", onComplete);
		#else
		if (onComplete != null)
			onComplete(true);
		#end
	}

	// ========== Audio API ==========

	function applyAudioMuteState():Void {
		// Yandex Games 1.3: stop audio when focus leaves the game (tab/app hidden).
		// The final mute state is merged from all interruption reasons.
		var nextMuted = manualAudioMuted || adAudioMuteDepth > 0 || platformAudioMuted;
		if (nextMuted == audioMuted)
			return;
		audioMuted = nextMuted;

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

		// Yandex Games 1.19: gameplay markup should switch with real gameplay pause/resume.
		#if gamepush
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
		adManager = null;
	}
}
