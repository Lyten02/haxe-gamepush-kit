package gamepushkit.bootstrap;

/**
 * Structured progress payload for UI loading screens.
 */
typedef BootstrapProgress = {
	var stage:String;
	var message:String;
	var percent:Int;
}

/**
 * Result of language resolution.
 */
typedef LanguageResolution = {
	var language:String;
	var source:String;
}

/**
 * Save provider metadata exposed to UI.
 */
typedef SaveProviderState = {
	var mode:String;
	var cloudAvailable:Bool;
	var localAvailable:Bool;
	var cloudHadData:Bool;
}

/**
 * Full bootstrap snapshot exposed through API and gdsite:ready payload.
 */
typedef BootstrapSnapshot = {
	var completed:Bool;
	var gamePushAvailable:Bool;
	var playerAvailable:Bool;
	var leaderboardAvailable:Bool;
	var fallbackToLocal:Bool;
	var language:String;
	var languageSource:String;
	var saveProvider:String;
	var saveInfo:SaveProviderState;
	var saves:Dynamic;
	var player:Dynamic;
	var adsStatus:Dynamic;
	var leaderboardWarmup:Null<Array<Dynamic>>;
	var warnings:Array<String>;
	var startedAt:Float;
	var finishedAt:Float;
}
