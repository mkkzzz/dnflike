extends RefCounted
## Module-scoped event bus. Events are facts that already happened; subscribers must
## not write back into the sender's state through an event.
## Subscription keys: exact type ("combat.hit"), module prefix ("combat."), or "*".

const HISTORY_LIMIT := 4096

var tick := 0
var time_ms := 0.0
var history: Array = []
var _next_id := 1
var _subscribers: Dictionary = {}

func subscribe(key: String, handler: Callable) -> void:
	if not _subscribers.has(key):
		_subscribers[key] = []
	_subscribers[key].append(handler)

func unsubscribe(key: String, handler: Callable) -> void:
	if _subscribers.has(key):
		_subscribers[key].erase(handler)

func emit(type: String, payload: Dictionary = {}) -> Dictionary:
	var event := payload.duplicate()
	event["type"] = type
	event["tick"] = tick
	event["time_ms"] = time_ms
	event["event_id"] = _next_id
	_next_id += 1
	history.append(event)
	if history.size() > HISTORY_LIMIT:
		history.pop_front()
	var prefix := type.get_slice(".", 0) + "."
	for key: String in [type, prefix, "*"]:
		for handler: Callable in _subscribers.get(key, []).duplicate():
			if handler.is_valid():
				handler.call(event)
	return event

func events_of(type: String) -> Array:
	return history.filter(func(e: Dictionary) -> bool: return e["type"] == type)

func clear_history() -> void:
	history.clear()
