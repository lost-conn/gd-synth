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
## patch_path, base_octave, channel, kit (the SynthKit of a DRUM track, else null).
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
			"kit": t.kit if t.track_type == MusicTrack.TrackType.DRUM else null,
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

## The track (a Dictionary) that plays [param pattern], or {}. A track that plays
## it directly comes before one that plays a chain with it as a step.
func track_for(pattern: MusicPattern) -> Dictionary:
	var all := tracks_for(pattern)
	return all[0] if not all.is_empty() else {}

## Every track that plays [param pattern], directly (by object, then by file) or
## as a step of the chain it plays, direct ones first.
func tracks_for(pattern: MusicPattern) -> Array:
	var out: Array = []
	if pattern == null:
		return out
	var path := path_of(pattern)
	for t in tracks:
		if t["pattern"] == pattern or (path != "" and t["pattern_path"] == path):
			out.append(t)
	for t in tracks:
		if not out.has(t) and contains(t["pattern"], pattern):
			out.append(t)
	return out

## True when [param whole] is a chain that has [param part] (or the pattern in
## the same file) among its steps, at any depth.
static func contains(whole: MusicPattern, part: MusicPattern, _stack: Array = []) -> bool:
	var chain := whole as PatternChain
	if chain == null or part == null or _stack.has(chain):
		return false
	_stack.append(chain)
	var path := path_of(part)
	for step in chain.steps:
		var p: MusicPattern = step.pattern if step != null else null
		if p == null:
			continue
		if p == part or (path != "" and path_of(p) == path) or contains(p, part, _stack):
			_stack.pop_back()
			return true
	_stack.pop_back()
	return false

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

## The explicit types [param p] is marked with: its own, then (for a chain) those
## of its steps' patterns, depth first. Empty when everything is Auto.
static func hints(p: MusicPattern, _stack: Array = []) -> Array[int]:
	var out: Array[int] = []
	if p == null or _stack.has(p):
		return out
	if int(p.editor_track_type) != MusicPattern.EditorTrackType.AUTO:
		out.append(int(p.editor_track_type))
	var chain := p as PatternChain
	if chain != null:
		_stack.append(chain)
		for step in chain.steps:
			if step != null:
				out.append_array(hints(step.pattern, _stack))
		_stack.pop_back()
	return out

## The type Match pattern sets a track to: the pattern's own mark, or for a chain
## that is Auto the first mark among its steps. Auto (-1) when nothing is marked.
static func match_type(p: MusicPattern) -> int:
	var h := hints(p)
	return h[0] if not h.is_empty() else int(MusicPattern.EditorTrackType.AUTO)

## True when [param p] is marked with a type of its own and a track of
## [param track_type] plays it as another (the game goes by the track). A chain
## clashes when ANY mark in it, its own or a step's, differs from the track's.
static func clash(p: MusicPattern, track_type: int) -> bool:
	for h in hints(p):
		if h != track_type:
			return true
	return false

## The warning for a [method clash], or "". For a chain it names the first step
## whose mark differs, unless the chain's own does.
static func clash_text(p: MusicPattern, track_type: int) -> String:
	if not clash(p, track_type):
		return ""
	var as_track := SynthPitchMap.type_name(track_type)
	var own := int(p.editor_track_type)
	var chain := p as PatternChain
	if chain != null and (own == MusicPattern.EditorTrackType.AUTO or own == track_type):
		for i in chain.steps.size():
			var step := chain.steps[i]
			if step != null and clash(step.pattern, track_type):
				return "Step %d (%s) is marked %s but this track plays it as %s: the game plays it as %s." % [
						i + 1, pattern_name(step.pattern), SynthPitchMap.type_name(match_type(step.pattern)), as_track, as_track]
	return "The pattern is marked %s but this track plays it as %s: the game plays it as %s." % [
			SynthPitchMap.type_name(own), as_track, as_track]

## The channels a track occupies as [first, last]: its own channel, or a kit's
## range (which may run past channel 15).
static func channel_range(t: MusicTrack) -> Vector2i:
	if t.uses_kit():
		return Vector2i(t.synth_channel, t.synth_channel + t.kit.pieces.size() - 1)
	return Vector2i(t.synth_channel, t.synth_channel)

static func _range_text(r: Vector2i) -> String:
	return "channel %d" % r.x if r.x == r.y else "channels %d to %d" % [r.x, r.y]

## The warning for [param t]'s channels, or "": its kit runs past the synth's last
## channel, or its channels overlap those of another of [param all] (the scene's
## tracks) when either of the two plays a kit. Two plain tracks may share a channel.
static func kit_warning(t: MusicTrack, all: Array) -> String:
	var lines := PackedStringArray()
	var own := t.get_kit_warning()
	if own != "":
		lines.append(own)
	var r := channel_range(t)
	for o in all:
		var other := o as MusicTrack
		if other == null or other == t or not (t.uses_kit() or other.uses_kit()):
			continue
		var q := channel_range(other)
		if r.x <= q.y and q.x <= r.y:
			lines.append("%s uses %s, which overlaps %s\"%s\" (%s): they take over each other's patches." % [
					"This track's kit" if t.uses_kit() else "This track", _range_text(r),
					"the kit of " if other.uses_kit() else "", other.name, _range_text(q)])
	return "\n".join(lines)

## A pattern's name for labels: its resource_name, else its file, else "(inline)".
static func pattern_name(p: Resource) -> String:
	if p == null:
		return "(none)"
	if p.resource_name != "":
		return p.resource_name
	var path := path_of(p)
	return path.get_file() if path != "" else "(inline)"
