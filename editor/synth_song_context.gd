@tool
class_name SynthSongContext
extends RefCounted

# The tracks of one music scene, read once and kept as plain data: what the
# Pattern view needs to know about the song around the pattern it edits
# (which MusicTrack uses it and with what patch, and what the other tracks
# play, to draw them faintly behind it).
#
# The scene is only read: instantiated with edit state disabled, its tracks'
# exported properties copied out, the whole thing freed. No node enters a tree,
# so no _ready runs and nothing plays.

## The scene's path ("" for a hand-made context).
var scene_path: String = ""
## True when the Pattern view worked this scene out from the pattern, rather
## than the Track view's user picking it.
var inferred: bool = false
## True when the tracks were read from the scene open in the editor, so they can
## be edited (with undo) and hold its unsaved changes.
var live: bool = false
## The scene's MusicDataPlayer progression, if it has one.
var music_data: MusicData
## One Dictionary per MusicTrack: name, type, pattern, pattern_path, patch,
## patch_path, base_octave, channel.
var tracks: Array = []

## Read [param path]: the scene open in the editor if it is, else its file. Null
## when it is not a scene.
static func read(path: String) -> SynthSongContext:
	var open := find_open_root(path)
	if open != null:
		return from_root(path, open, true)
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	if root == null:
		return null
	var ctx := from_root(path, root)
	root.free()
	return ctx

## The tracks of the scene whose root is [param root], which may be the live
## scene open in the editor (unsaved edits included) or a detached instance.
## [param root] is only read. [param live]: it is the scene open in the editor.
static func from_root(path: String, root: Node, live: bool = false) -> SynthSongContext:
	var ctx := SynthSongContext.new()
	ctx.scene_path = path
	ctx.live = live
	ctx._collect(root, root)
	ctx.music_data = _find_music_data(root)
	return ctx

func _collect(node: Node, root: Node) -> void:
	if node is MusicTrack:
		var t := node as MusicTrack
		tracks.append({
			"name": str(root.get_path_to(node)) if node != root else str(node.name),
			"type": int(t.track_type),
			"pattern": t.pattern,
			"pattern_path": path_of(t.pattern),
			"patch": t.patch,
			"patch_path": path_of(t.patch),
			"base_octave": t.base_octave,
			"channel": t.synth_channel,
		})
	for c in node.get_children():
		_collect(c, root)

## The scene's MusicDataPlayer progression (any node with a music_data property
## holding a MusicData; it may be a placeholder instance, which still answers get()).
static func find_music_data(node: Node) -> MusicData:
	return _find_music_data(node)

static func _find_music_data(node: Node) -> MusicData:
	var d: Variant = node.get("music_data")
	if d is MusicData:
		return d
	for c in node.get_children():
		var found := _find_music_data(c)
		if found != null:
			return found
	return null

## "" for a resource without a file (inline in the scene).
static func path_of(res: Resource) -> String:
	if res == null or res.resource_path == "" or "::" in res.resource_path:
		return ""
	return res.resource_path

## The track (a Dictionary) that plays [param pattern], or {}. Matches by object,
## then by file.
func track_for(pattern: MusicPattern) -> Dictionary:
	if pattern == null:
		return {}
	var path := path_of(pattern)
	for t in tracks:
		if t["pattern"] == pattern or (path != "" and t["pattern_path"] == path):
			return t
	return {}

## Every track that plays [param pattern].
func tracks_for(pattern: MusicPattern) -> Array:
	var out: Array = []
	var path := path_of(pattern)
	for t in tracks:
		if t["pattern"] == pattern or (path != "" and t["pattern_path"] == path):
			out.append(t)
	return out

## The root of the scene at [param path] if it is open in the editor, else null.
static func find_open_root(path: String) -> Node:
	if path == "" or not Engine.is_editor_hint() or not Engine.has_singleton(&"EditorInterface"):
		return null
	for r in Engine.get_singleton(&"EditorInterface").call("get_open_scene_roots"):
		if is_instance_valid(r) and (r as Node).scene_file_path == path:
			return r
	return null

## The track a [code]"name"[/code] of [member tracks] stands for, in the scene
## whose root is [param root]. Null if there is none.
static func node_for(root: Node, track_name: String) -> Node:
	var n := root.get_node_or_null(NodePath(track_name))
	if n == null and str(root.name) == track_name:
		return root
	return n

## True when [param p] is marked with a type of its own and a track of
## [param track_type] plays it as another (the game goes by the track).
static func clash(p: MusicPattern, track_type: int) -> bool:
	return p != null and int(p.editor_track_type) != MusicPattern.EditorTrackType.AUTO \
			and int(p.editor_track_type) != track_type

## The warning for a [method clash], or "".
static func clash_text(p: MusicPattern, track_type: int) -> String:
	if not clash(p, track_type):
		return ""
	var as_track := SynthPitchMap.type_name(track_type)
	return "The pattern is marked %s but this track plays it as %s: the game plays it as %s." % [
			SynthPitchMap.type_name(int(p.editor_track_type)), as_track, as_track]
