package gamepushkit;

/**
 * Bridge for communication between Haxe and React via CustomEvents.
 *
 * Events from Haxe to React: "gdsite:eventName"
 * Events from React to Haxe: "react:eventName"
 */
class Bridge {
	/**
	 * Send event from Haxe to React.
	 * @param eventName Event name (will be prefixed with "gdsite:")
	 * @param data Optional data to send
	 */
	public static function sendToReact(eventName:String, ?data:Dynamic):Void {
		#if js
		var detail = data != null ? data : {};
		var event = new js.html.CustomEvent("gdsite:" + eventName, {detail: detail});
		js.Browser.window.dispatchEvent(event);
		#end
	}

	/**
	 * Listen for events from React.
	 * @param eventName Event name (will be prefixed with "react:")
	 * @param callback Function to call when event is received
	 */
	public static function listenFromReact(eventName:String, callback:Dynamic->Void):Void {
		#if js
		js.Browser.window.addEventListener("react:" + eventName, function(e:js.html.Event) {
			var customEvent:js.html.CustomEvent = cast e;
			callback(customEvent.detail);
		});
		#end
	}

	/**
	 * Notify React that Heaps is ready.
	 */
	public static function notifyHeapsReady():Void {
		sendToReact("heaps-ready", {timestamp: Date.now().getTime()});
	}
}
