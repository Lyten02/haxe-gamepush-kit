package gamepushkit.bootstrap;

import gamepushkit.bootstrap.BootstrapTypes.LanguageResolution;

/**
 * Supported language resolver for bootstrap and runtime language switches.
 */
class LanguageResolver {
	static final SUPPORTED:Array<String> = ["en", "ru", "tr"];

	/**
	 * Resolve startup language: provider (GamePush SDK) -> default(en).
	 */
	public static function resolve(providerLanguage:Null<String>):LanguageResolution {
		var fromProvider = pickSupported(providerLanguage);
		if (fromProvider != null) {
			return {
				language: fromProvider,
				source: "gamepush"
			};
		}

		return {
			language: "en",
			source: "default"
		};
	}

	/**
	 * Runtime language changes are intentionally ephemeral.
	 * We normalize user request, but do not persist manual override across sessions.
	 */
	public static function normalize(requestedLanguage:String):String {
		return pickSupported(requestedLanguage, "en");
	}

	static function pickSupported(candidate:Null<String>, ?fallback:Null<String>):Null<String> {
		if (candidate == null || candidate == "") {
			return fallback;
		}

		var normalized = normalizeRaw(candidate);
		for (lang in SUPPORTED) {
			if (lang == normalized) {
				return lang;
			}
		}
		return fallback;
	}

	static function normalizeRaw(candidate:String):String {
		var normalized = candidate.toLowerCase();
		var dash = normalized.indexOf("-");
		if (dash > 0) {
			normalized = normalized.substr(0, dash);
		}
		return normalized;
	}
}
