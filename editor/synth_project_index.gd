@tool
class_name SynthProjectIndex
extends RefCounted

# What the Sound view needs to know about the project around the patch it is
# editing, found without any knowledge of the host project's layout:
#
#   patches     every SynthPatch resource file (the browser's list)
#   sets        every SynthSampleSet file, by file name (a patch's baked set is
#               named after the patch file)
#   ref_counts  patch path -> how many scenes / resources mention it
#   bake_tools  scripts outside the addon that use the sample baker: where to
#               look when a set is stale
#
# In the editor it walks the EditorFileSystem; anywhere else it walks res:// with DirAccess. The
# reference scan reads text files, so it runs a few at a time over several frames.

signal refs_ready

const TEXT_EXT := ["tscn", "tres"]
const MAX_TEXT_BYTES := 2_000_000

var patches: Array = []              # [{path, name, dir}], sorted by path
var sets: Dictionary = {}            # file basename -> PackedStringArray of paths
var bake_tools: PackedStringArray = PackedStringArray()
var ref_counts: Dictionary = {}      # patch path -> int
var refs_done: bool = false

var _addon_dir: String = ""
var _text_files: PackedStringArray = PackedStringArray()
var _gd_files: PackedStringArray = PackedStringArray()
var _generation: int = 0

static func _editor_fs() -> Object:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var ei: Object = Engine.get_singleton(&"EditorInterface")
		return ei.call("get_resource_filesystem")
	return null

## Re-read the project's file list. [param addon_dir] is the addon's own folder
## ("res://addons/godot_synth"), whose scripts are not "the host's bake tool".
func rescan(addon_dir: String) -> void:
	_generation += 1
	_addon_dir = addon_dir
	patches.clear()
	sets.clear()
	bake_tools = PackedStringArray()
	ref_counts.clear()
	refs_done = false
	_text_files = PackedStringArray()
	_gd_files = PackedStringArray()
	var fs: Object = _editor_fs()
	if fs != null:
		var root: Object = fs.call("get_filesystem")
		if root != null:
			_walk_editor(root)
	else:
		_walk_disk("res://")
	patches.sort_custom(func(a, b): return a["path"] < b["path"])

# The editor's file list knows each file's type ("Resource" for a scripted one)
# but not its script, so a .tres is asked for its script_class in its header.
func _note_file(path: String, type: String) -> void:
	var ext := path.get_extension()
	if ext == "tres":
		var cls := _peek_script_class(path) if type == "Resource" else ""
		if cls == "SynthPatch":
			patches.append({"path": path, "name": path.get_file().get_basename(), "dir": path.get_base_dir()})
			return
		if cls == "SynthSampleSet":
			_add_set(path)
			return
		_text_files.append(path)
	elif ext == "res":
		# A binary resource has no cheap header: every one is a candidate set,
		# and SynthBakeInfo checks what it loads.
		if type == "Resource":
			_add_set(path)
	elif ext == "tscn":
		_text_files.append(path)
	elif ext == "gd" and not path.begins_with(_addon_dir + "/"):
		_gd_files.append(path)

func _add_set(path: String) -> void:
	var key := path.get_file().get_basename()
	var list: PackedStringArray = sets.get(key, PackedStringArray())
	list.append(path)
	sets[key] = list

func _walk_editor(dir: Object) -> void:
	for i in dir.call("get_file_count"):
		_note_file(dir.call("get_file_path", i), dir.call("get_file_type", i))
	for i in dir.call("get_subdir_count"):
		_walk_editor(dir.call("get_subdir", i))

func _walk_disk(path: String) -> void:
	for d in DirAccess.get_directories_at(path):
		if d.begins_with("."):
			continue
		_walk_disk(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		_note_file(path.path_join(f), "Resource" if f.get_extension() in ["tres", "res"] else "")

# The script_class="..." in a .tres header, without parsing the file.
static func _peek_script_class(path: String) -> String:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return ""
	var head := fa.get_buffer(200).get_string_from_utf8()
	var at := head.find('script_class="')
	if at < 0:
		return ""
	var start := at + 14
	return head.substr(start, head.find('"', start) - start)

## Count the scenes and resources that mention each patch, and find the bake
## tools. Reads files a few at a time, a frame apart; emits [signal refs_ready].
## A rescan() meanwhile abandons it.
func compute_refs(tree: SceneTree) -> void:
	var gen := _generation
	var needles: Dictionary = {}  # patch path -> [path, uid text]
	for p in patches:
		var path: String = p["path"]
		var uid := ResourceLoader.get_resource_uid(path)
		needles[path] = [path, ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else ""]
		ref_counts[path] = 0
	var batch := 0
	for file in _text_files:
		if tree == null or gen != _generation:
			return
		var fa := FileAccess.open(file, FileAccess.READ)
		if fa != null and fa.get_length() <= MAX_TEXT_BYTES:
			var text := fa.get_as_text()
			for path in needles:
				if file == path:
					continue
				var n: Array = needles[path]
				if text.contains(n[0]) or (n[1] != "" and text.contains(n[1])):
					ref_counts[path] += 1
		batch += 1
		if batch % 24 == 0:
			await tree.process_frame
	for file in _gd_files:
		if tree == null or gen != _generation:
			return
		var fa := FileAccess.open(file, FileAccess.READ)
		if fa != null and fa.get_length() <= MAX_TEXT_BYTES:
			var text := fa.get_as_text()
			if text.contains("SynthSampleBaker") or text.contains("sample_baker.gd"):
				bake_tools.append(file)
		batch += 1
		if batch % 24 == 0:
			await tree.process_frame
	if gen != _generation:
		return
	refs_done = true
	refs_ready.emit()

## Where a patch is used, for the browser: "3 scenes", "baked", "unused".
func usage_hint(path: String) -> String:
	var n: int = ref_counts.get(path, 0)
	if n > 0:
		return "%d scene%s" % [n, "" if n == 1 else "s"] if n < 100 else "many"
	if has_set_for(path):
		return "baked"
	return "unused" if refs_done else ""

func has_set_for(patch_path: String) -> bool:
	return sets.has(patch_path.get_file().get_basename())

## Candidate set files for [param patch_path] (named after the patch file).
func set_candidates(patch_path: String) -> PackedStringArray:
	return sets.get(patch_path.get_file().get_basename(), PackedStringArray())
