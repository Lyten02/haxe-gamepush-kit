package gamepushkit;

#if js
import js.Browser;
import js.html.Event;
#end

typedef WebFocusChangeHandler = Bool->String->Void;

/**
 * Browser foreground/background lifecycle bridge.
 *
 * Use this in platform integrations to map browser focus/visibility to game pause state.
 *
 * Yandex Games moderation notes:
 * - Rule 1.3 (sound outside game): on hidden/blurred page we should pause game audio.
 * - Rule 1.19 (gameplay markup): gameplay state should switch together with pause/resume events.
 */
class WebFocusLifecycle {
	var onChange:WebFocusChangeHandler;

	#if js
	var started:Bool = false;
	var lastForeground:Null<Bool> = null;

	var visibilityHandler:Event->Void;
	var blurHandler:Event->Void;
	var focusHandler:Event->Void;
	var pageHideHandler:Event->Void;
	var pageShowHandler:Event->Void;
	#end

	public function new(onChange:WebFocusChangeHandler) {
		this.onChange = onChange;

		#if js
		visibilityHandler = function(_) {
			notifyState("visibilitychange");
		};
		blurHandler = function(_) {
			notifyState("blur");
		};
		focusHandler = function(_) {
			notifyState("focus");
		};
		pageHideHandler = function(_) {
			notifyState("pagehide");
		};
		pageShowHandler = function(_) {
			notifyState("pageshow");
		};
		#end
	}

	public function start():Void {
		#if js
		if (started)
			return;

		started = true;
		Browser.document.addEventListener("visibilitychange", visibilityHandler);
		Browser.window.addEventListener("blur", blurHandler);
		Browser.window.addEventListener("focus", focusHandler);
		Browser.window.addEventListener("pagehide", pageHideHandler);
		Browser.window.addEventListener("pageshow", pageShowHandler);

		notifyState("init");
		#end
	}

	public function dispose():Void {
		#if js
		if (!started)
			return;

		started = false;
		Browser.document.removeEventListener("visibilitychange", visibilityHandler);
		Browser.window.removeEventListener("blur", blurHandler);
		Browser.window.removeEventListener("focus", focusHandler);
		Browser.window.removeEventListener("pagehide", pageHideHandler);
		Browser.window.removeEventListener("pageshow", pageShowHandler);
		#end
	}

	#if js
	function notifyState(reason:String):Void {
		var isForeground = !Browser.document.hidden && Browser.document.hasFocus();
		if (lastForeground != null && lastForeground == isForeground)
			return;

		lastForeground = isForeground;
		onChange(isForeground, reason);
	}
	#end
}
