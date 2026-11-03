extends RefCounted
## Shared presentation resources. Warm during battle setup and reuse across
## actors/effects; view nodes must not decode the same atlas repeatedly.

static var _textures: Dictionary = {}
static var _warmed: Dictionary = {}

static func load_texture(path: String) -> Texture2D:
	if path == "" or not ResourceLoader.exists(path):
		return null
	if _textures.has(path):
		return _textures[path]
	var texture := load(path) as Texture2D
	_textures[path] = texture
	return texture

static func warm(paths: Array) -> void:
	for raw_path in paths:
		var path := String(raw_path)
		if path == "" or _warmed.has(path):
			continue
		_warmed[path] = true
		load_texture(path)

static func clear() -> void:
	_textures.clear()
	_warmed.clear()
