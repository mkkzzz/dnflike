extends RefCounted
## Complete archived data, queried lazily. No original client/PVF is needed.
## Presence here means migrated source; execution is separately classified.
const BASE := "res://assets_local/native_data_v1/"
static var _index: Dictionary = {}
static var _shards: Dictionary = {}
static var _order: Array[String] = []
static var _runtime: Dictionary = {}

static func read_compressed(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():return {}
	var decoded = JSON.parse_string(bytes.decompress_dynamic(128 * 1024 * 1024, FileAccess.COMPRESSION_GZIP).get_string_from_utf8())
	return decoded if decoded is Dictionary else {}

static func index() -> Dictionary:
	if _index.is_empty():_index = read_compressed(BASE + "index.json.gz")
	return _index

static func runtime() -> Dictionary:
	if _runtime.is_empty():
		var value = JSON.parse_string(FileAccess.get_file_as_string("res://data/native_runtime.json"))
		if value is Dictionary and value.get("schema") == "dnf_native_runtime/1":_runtime = value
	return _runtime

static func record(path: String) -> Dictionary:
	path = path.to_lower().replace("\\", "/")
	var shard: String = index().get("locations", {}).get(path, "")
	if shard.is_empty():return {}
	if not _shards.has(shard):
		if _order.size() >= 4:_shards.erase(_order.pop_front())
		_shards[shard] = read_compressed(BASE + shard).get("records", {})
		_order.append(shard)
	return _shards[shard].get(path, {})

static func original(kind: String, number: int) -> Dictionary:
	return record(index().get("indexes", {}).get(kind, {}).get(str(number), ""))

static func search(text: String, kind := "", limit := 50) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var paths: Dictionary = index().get("names", {})
	var allowed: Dictionary = {}
	if kind != "":
		for path: String in index().get("indexes", {}).get(kind, {}).values():allowed[path] = true
	for path: String in paths:
		if kind != "" and not allowed.has(path):continue
		if not text.is_empty() and text not in String(paths[path]) and text not in path:continue
		result.append({"path":path,"name":paths[path]})
		if result.size() >= clampi(limit, 1, 1000):break
	return result
