@tool
extends RefCounted
## Starts Client tasks and routes their reports to the caller's callback,
## including reports that arrive before the POST returns the task id.
##
## Starting a task is a POST that replies with its task id, while the task's
## reports come from the plugin's /godot/report poll. The two run
## concurrently, so a fast task (e.g. a cached search) can be reported
## finished before its POST returns. While any POST is in flight, reports of
## unknown tasks are kept and replayed when a POST returns. The ones no POST
## claims come back through [signal unclaimed], e.g. Send to Godot downloads.
##
## Each request has a key, and starting another request with the same key
## supersedes it, e.g. a new search replaces the running one.

## A request is about to POST, so poll faster.
signal started
## A kept report that no POST claimed, emitted once no POST is in flight.
signal unclaimed(task: Dictionary)

## Statuses after which a task isn't reported anymore.
const FINAL := ["finished", "error", "cancelled"]

## key -> {task_id, on_task}; task_id is "" while the POST runs.
var _requests: Dictionary = {}
## task_id -> key
var _keys: Dictionary = {}
## task_id -> latest report of a task no request has claimed yet.
var _early: Dictionary = {}
var _posts := 0


## Awaits [param post], which returns [code][task_id, error][/code], and
## calls [param on_task] with each report of the task until a final status.
## Returns what [param post] returned, with task_id "" on failure, or [] if
## the request was superseded or cancelled meanwhile. Reports that arrived
## early are replayed before this returns.
func start(key: String, post: Callable, on_task: Callable) -> Array:
	forget(key)
	var request := {"task_id": "", "on_task": on_task}
	_requests[key] = request
	_posts += 1
	started.emit()
	var response: Array = await post.call()
	_posts -= 1
	var task_id: String = response[0]
	var early = _early.get(task_id)
	_early.erase(task_id)
	var current: bool = is_same(_requests.get(key), request)
	if current and task_id.is_empty():
		_requests.erase(key)
	elif current:
		request.task_id = task_id
		_keys[task_id] = key
		if early:
			_deliver(key, early)
	if _posts == 0:
		_release()
	return response if current else []


## Stop routing reports to a request, e.g. a search nobody waits for.
func forget(key: String) -> void:
	var request = _requests.get(key)
	if request:
		_keys.erase(request.task_id)
		_requests.erase(key)


## Whether a request with [param key] runs.
func has(key: String) -> bool:
	return _requests.has(key)


## Routes a task report. Returns false for a task nobody waits for, which
## the caller handles itself.
func handle(task: Dictionary) -> bool:
	var task_id := str(task.get("task_id", ""))
	if _keys.has(task_id):
		_deliver(_keys[task_id], task)
		return true
	if _posts > 0 and not task_id.is_empty():
		_early[task_id] = task
		return true
	return false


## Whether any POST is still in flight.
func is_posting() -> bool:
	return _posts > 0


## The Client cancels the app's tasks when it unsubscribes, so drop all
## requests and kept reports. POSTs in flight return [] from start().
func cancel_all() -> void:
	_requests.clear()
	_keys.clear()
	_early.clear()


## A request is done after a final status, so forget it first. The callback
## may then start the next request with the same key.
func _deliver(key: String, task: Dictionary) -> void:
	var on_task: Callable = _requests[key].on_task
	if task.get("status") in FINAL:
		forget(key)
	on_task.call(task)


func _release() -> void:
	var early := _early
	_early = {}
	for task in early.values():
		unclaimed.emit(task)
