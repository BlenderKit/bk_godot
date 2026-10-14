@tool
extends RefCounted
## File operations of downloads that mustn't lose the files they replace.


## Replace [param target], if there's one, with [param source], keeping
## [param target] if that fails. Returns whether it was replaced.
static func replace_file(source: String, target: String) -> bool:
	var moves := Moves.new()
	if not moves.move(source, target):
		return false
	moves.commit()
	return true


## Delete the folder at [param path] with everything in it, hidden files
## like the asset manifest too. Returns whether it's gone.
static func remove_dir(path: String) -> bool:
	var folder := DirAccess.open(path)
	if folder == null:
		return not DirAccess.dir_exists_absolute(path)
	folder.include_hidden = true
	for dir in folder.get_directories():
		remove_dir(path.path_join(dir))
	for file in folder.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	return DirAccess.remove_absolute(path) == OK


## Moves of files undone together if one of them fails: each file replaced
## is kept as <file>.bk_old until commit(), rollback() moves the files back
## and restores those.
class Moves:
	const BACKUP_SUFFIX := ".bk_old"

	## [source, target, backup or ""] of each move, in order.
	var _moved: Array = []
	## Folders made for the moves, deleted on rollback() if empty.
	var _made: Array = []

	## Make the folder at [param path] and those above it for files to move in.
	func make_dir(path: String) -> bool:
		var missing := []
		var dir := path
		while not dir.is_empty() and not DirAccess.dir_exists_absolute(dir):
			missing.append(dir)
			var parent := dir.get_base_dir()
			if parent == dir:
				break
			dir = parent
		if DirAccess.make_dir_recursive_absolute(path) != OK:
			return false
		_made = missing + _made # deepest first
		return true

	## Move the file at [param source] to [param target], replacing the file
	## there. Returns whether it moved; if not, nothing changed.
	func move(source: String, target: String) -> bool:
		var backup := ""
		if FileAccess.file_exists(target):
			backup = target + BACKUP_SUFFIX
			DirAccess.remove_absolute(backup) # left by an interrupted move
			if DirAccess.rename_absolute(target, backup) != OK:
				return false
		if DirAccess.rename_absolute(source, target) != OK:
			if backup:
				DirAccess.rename_absolute(backup, target)
			return false
		_moved.append([source, target, backup])
		return true

	## Keep the moves: delete the files they replaced.
	func commit() -> void:
		for moved in _moved:
			if moved[2]:
				DirAccess.remove_absolute(moved[2])
		_moved.clear()
		_made.clear()

	## Undo the moves, latest first.
	func rollback() -> void:
		_moved.reverse()
		for moved in _moved:
			DirAccess.rename_absolute(moved[1], moved[0])
			if moved[2]:
				DirAccess.rename_absolute(moved[2], moved[1])
		_moved.clear()
		for dir in _made:
			DirAccess.remove_absolute(dir) # only if empty
		_made.clear()
