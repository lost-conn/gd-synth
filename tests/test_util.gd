extends RefCounted

# Shared by the test files: assertions, the editor stand-ins (an UndoRedo shim, a
# Track view that finds its scene without the editor, an engine that records
# note-ons) and a small song scene. Nothing here touches res:// or the autoloads.

var checks: int = 0
var failures: PackedStringArray = PackedStringArray()
var _context: String = ""

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

## Label the checks that follow (shown with a failure).
func section(name: String) -> void:
	_context = name

func check(cond: bool, msg: String) -> bool:
	checks += 1
	if not cond:
		failures.append("[%s] %s" % [_context, msg])
	return cond

func check_eq(got: Variant, want: Variant, msg: String) -> bool:
	var ok: bool = is_equal_approx(got, want) if typeof(got) == TYPE_FLOAT and typeof(want) == TYPE_FLOAT else got == want
	return check(ok, "%s (got %s, want %s)" % [msg, str(got), str(want)])

# ---------------------------------------------------------------------------
# Editor stand-ins
# ---------------------------------------------------------------------------

## An EditorUndoRedoManager over a real UndoRedo: the calls SynthSongEdit makes.
class UndoShim:
	extends RefCounted
	signal history_changed
	var ur := UndoRedo.new()
	var labels: PackedStringArray = PackedStringArray()
	var _open_label: String = ""
	var _merged: bool = false

	func create_action(label: String, merge_mode: int = 0, _context: Object = null) -> void:
		_open_label = label
		var before := ur.get_history_count()
		ur.create_action(label, merge_mode as UndoRedo.MergeMode)
		_merged = false
		# Remember whether this action will fold into the last one.
		if merge_mode != UndoRedo.MERGE_DISABLE and before > 0 and ur.get_action_name(before - 1) == label:
			_merged = true

	func add_do_property(obj: Object, prop: StringName, value: Variant) -> void:
		ur.add_do_property(obj, prop, value)

	func add_undo_property(obj: Object, prop: StringName, value: Variant) -> void:
		ur.add_undo_property(obj, prop, value)

	func add_do_method(obj: Object, method: StringName, ...args: Array) -> void:
		ur.add_do_method(Callable(obj, method).bindv(args))

	func add_undo_method(obj: Object, method: StringName, ...args: Array) -> void:
		ur.add_undo_method(Callable(obj, method).bindv(args))

	func add_do_reference(obj: Object) -> void:
		ur.add_do_reference(obj)

	func add_undo_reference(obj: Object) -> void:
		ur.add_undo_reference(obj)

	func commit_action() -> void:
		ur.commit_action()
		if not _merged:
			labels.append(_open_label)
		history_changed.emit()

	## Number of undo steps the history holds.
	func steps() -> int:
		return labels.size()

	func undo() -> void:
		ur.undo()
		history_changed.emit()

	func redo() -> void:
		ur.redo()
		history_changed.emit()

## The Track view with the scene given to it instead of the editor's open scenes.
class TestView:
	extends SynthTrackView
	var fake_root: Node

	func _find_open_root(path: String) -> Node:
		return fake_root if path != "" else null

## An engine that is not one: records what the tracks ask of it.
class RecEngine:
	extends SynthEngine
	var clock: MusicDirector
	## [director beat, channel, note, velocity, pan] per note-on.
	var ons: Array = []
	## [director beat, channel, note] per note-off.
	var offs: Array = []

	func _ready() -> void:
		pass

	func _exit_tree() -> void:
		pass

	func note_on(channel: int, note: float, velocity: float = 1.0, pan: float = 0.0) -> void:
		ons.append([clock.get_total_beats() if clock != null else 0.0, channel, note, velocity, pan])

	func note_off(channel: int, note: int) -> void:
		offs.append([clock.get_total_beats() if clock != null else 0.0, channel, note])

	func set_patch(_channel: int, _patch: SynthPatch) -> void:
		pass

	func ensure_channel_bus(_channel: int, _effects: Array, _send: StringName = &"Master") -> StringName:
		return &"Master"

	func bend_to(_channel: int, _midi: int, _freq: float, _seconds: float) -> void:
		pass

	func all_notes_off() -> void:
		pass

	func set_enabled(_on: bool) -> void:
		pass

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

## The length of one test frame in seconds: an eighth of a beat at 120 bpm.
const DT := 0.0625
## The same frame in beats (the tests play at 120 bpm).
const FRAME_BEATS := 0.125

## Run [param frames] frames over [param nodes] in order (a director first, then the
## tracks), as the engine would: each node's _process, never a real frame.
static func step(nodes: Array, frames: int, dt: float = DT) -> void:
	for f in frames:
		for n in nodes:
			if is_instance_valid(n):
				n._process(dt)

## Stop every director and track under [param node] from being processed by the real
## main loop; step() drives them.
static func freeze(node: Node) -> void:
	if node is MusicDirector or node is MusicTrack or node is SynthPreview:
		node.set_process(false)
	for c in node.get_children():
		freeze(c)

## The editor's SynthPreview over an engine that records and no audio thread: what
## ensure_started() builds, minus the real SynthEngine. Returns the preview; its
## engine is [code]preview.synth[/code] (a RecEngine).
static func make_preview(parent: Node) -> SynthPreview:
	var p := SynthPreview.new()
	p.name = "Preview"
	parent.add_child(p)
	var engine := RecEngine.new()
	engine.name = "PreviewSynth"
	p.add_child(engine)
	p.synth = engine
	var d := MusicDirector.new()
	d.name = "PreviewDirector"
	d.editor_preview = true
	p.add_child(d)
	p.director = d
	engine.clock = d
	var tr := MusicTrack.new()
	tr.name = "PreviewTrack"
	tr.editor_preview = true
	tr.director = d
	tr.synth = engine
	tr.autoplay = false
	tr.synth_channel = SynthPreview.CHANNEL
	p.add_child(tr)
	p.track = tr
	freeze(p)
	return p

# ---------------------------------------------------------------------------
# A song
# ---------------------------------------------------------------------------

static func pattern(length: float, notes: Array, track_type: int = -1) -> MusicPattern:
	var p := MusicPattern.new()
	p.length_beats = length
	for n in notes:
		p.add(n[0], n[1], n[2], n[3] if n.size() > 3 else 0)
	p.editor_track_type = track_type as MusicPattern.EditorTrackType
	return p

static func block(chord_root: int, minor: bool, beats: int = 4) -> MusicBlock:
	return MusicBlock.create(chord_root, MusicData.CHORD_MIN if minor else MusicData.CHORD_MAJ, MusicData.C, MusicData.MAJOR, beats)

static func progression(roots: Array, beats: int = 4, bpm: float = 120.0) -> MusicData:
	var d := MusicData.new()
	d.bpm = bpm
	var arr: Array[MusicBlock] = []
	for r in roots:
		arr.append(block(r, false, beats))
	d.blocks = arr
	return d

## The pieces of a song scene.
class Scene:
	extends RefCounted
	var root: Node
	var player: MusicDataPlayer
	var lead: MusicTrack
	var pad: MusicTrack
	var drums: MusicTrack
	var song: MusicSong
	var intro: MusicSection
	var verse: MusicSection
	var chorus: MusicSection
	var lead_a: MusicPattern
	var lead_b: MusicPattern
	var pad_a: MusicPattern
	var pad_b: MusicPattern
	var drums_a: MusicPattern
	var chain: PatternChain
	var plain_data: MusicData
	var song_data: MusicData
	var chorus_data: MusicData

	func free_all() -> void:
		if root != null and is_instance_valid(root):
			root.free()
		root = null

## The nodes of a music scene, not in any tree: a MusicDataPlayer and the tracks Lead
## (melody, channel 0), Pad (chords, channel 1) and Drums (a kit on channels 2 and 3).
## [param with_song] false: a plain scene (music_data only).
static func make_scene(with_song: bool = true) -> Scene:
	var s := Scene.new()
	s.lead_a = pattern(4.0, [[0.0, 0.5, 0], [1.0, 0.5, 2], [2.0, 0.5, 4], [3.0, 0.5, 2]], MusicPattern.EditorTrackType.MELODY)
	s.lead_b = pattern(2.0, [[0.0, 0.5, 4], [1.0, 0.5, 5]], MusicPattern.EditorTrackType.MELODY)
	s.pad_a = pattern(4.0, [[0.0, 3.5, 0], [0.0, 3.5, 1], [0.0, 3.5, 2]], MusicPattern.EditorTrackType.CHORD)
	s.pad_b = pattern(8.0, [[0.0, 3.5, 0], [4.0, 3.5, 2]], MusicPattern.EditorTrackType.CHORD)
	s.drums_a = pattern(4.0, [[0.0, 0.25, 36], [1.0, 0.25, 38], [2.0, 0.25, 36], [3.0, 0.25, 38]], MusicPattern.EditorTrackType.DRUM)
	s.chain = PatternChain.new()
	s.chain.add_step(s.lead_a, 1)
	s.chain.add_step(s.lead_b, 2)
	s.plain_data = progression([MusicData.C, MusicData.F])
	s.song_data = progression([MusicData.C, MusicData.F])

	s.root = Node.new()
	s.root.name = "MusicScene"
	s.player = MusicDataPlayer.new()
	s.player.name = "Player"
	s.player.music_data = s.plain_data
	s.root.add_child(s.player)
	s.lead = _track("Lead", MusicTrack.TrackType.MELODY, s.lead_a, 0)
	s.pad = _track("Pad", MusicTrack.TrackType.CHORD, s.pad_a, 1)
	s.drums = _track("Drums", MusicTrack.TrackType.DRUM, s.drums_a, 2)
	var kit := SynthKit.new()
	var kp: Array[SynthKitPiece] = [SynthKitPiece.create("Kick", 36), SynthKitPiece.create("Snare", 38)]
	kit.pieces = kp
	s.drums.kit = kit
	for t in [s.lead, s.pad, s.drums]:
		s.root.add_child(t)

	if with_song:
		s.chorus_data = progression([MusicData.G, MusicData.C, MusicData.A, MusicData.F])
		s.intro = MusicSection.create("Intro")
		s.intro.add_slot(&"Pad", MusicSectionSlot.Mode.PLAY, s.pad_a)
		s.intro.add_slot(&"Lead", MusicSectionSlot.Mode.SILENT)
		s.verse = MusicSection.create("Verse")
		s.verse.add_slot(&"Lead", MusicSectionSlot.Mode.PLAY, s.chain)
		s.verse.add_slot(&"Drums", MusicSectionSlot.Mode.PLAY, s.drums_a)
		s.chorus = MusicSection.create("Chorus", s.chorus_data, 1)
		s.chorus.add_slot(&"Lead", MusicSectionSlot.Mode.PLAY, s.lead_b)
		s.chorus.add_slot(&"Pad", MusicSectionSlot.Mode.PLAY, s.pad_b)
		s.chorus.add_slot(&"Drums", MusicSectionSlot.Mode.KEEP)
		s.song = MusicSong.new()
		s.song.bpm = 120.0
		s.song.progression = s.song_data
		s.song.add_entry(s.intro).add_entry(s.verse, 2).add_entry(s.chorus).add_entry(s.verse)
		s.song.loop_entry = 1
		s.player.song = s.song
	return s

static func _track(track_name: String, type: int, pat: MusicPattern, channel: int) -> MusicTrack:
	var t := MusicTrack.new()
	t.name = track_name
	t.track_type = type as MusicTrack.TrackType
	t.pattern = pat
	t.synth_channel = channel
	return t

## A copy of the scene's tracks and player set up to play for real: a MusicDirector
## and an engine that records. Returns {tree_root, director, engine, player, tracks}.
## [param parent] is where it is added (it must be in the tree).
static func make_rig(parent: Node, song: MusicSong, own: Scene) -> Dictionary:
	var rig := Node.new()
	rig.name = "Rig"
	var engine := RecEngine.new()
	engine.name = "Engine"
	rig.add_child(engine)
	var director := MusicDirector.new()
	director.name = "Director"
	rig.add_child(director)
	engine.clock = director
	var tracks: Array[MusicTrack] = []
	for src in [own.lead, own.pad, own.drums]:
		var t := MusicTrack.new()
		t.name = src.name
		t.track_type = src.track_type
		t.pattern = src.pattern
		t.synth_channel = src.synth_channel
		t.base_octave = src.base_octave
		t.kit = src.kit
		t.autoplay = false
		t.swap_mode = MusicDirector.SwapMode.IMMEDIATE
		t.director = director
		t.synth = engine
		rig.add_child(t)
		tracks.append(t)
	var player := MusicDataPlayer.new()
	player.name = "Player"
	player.director = director
	player.song = song
	rig.add_child(player)
	parent.add_child(rig)
	director.set_process(false)
	for t in tracks:
		t.set_process(false)
	return {"root": rig, "director": director, "engine": engine, "player": player, "tracks": tracks}

# ---------------------------------------------------------------------------
# The Track view
# ---------------------------------------------------------------------------

## A Track view over [param sc] as if the scene were open in the editor, with an undo
## shim, in the tree and laid out. Returns {sc, shim, view}; close it with close_view().
func open_view(tree: SceneTree, sc: Scene) -> Dictionary:
	var shim := UndoShim.new()
	var view := TestView.new()
	view.fake_root = sc.root
	view.undo_redo = shim
	view.custom_minimum_size = Vector2(1500, 900)
	view.size = Vector2(1500, 900)
	tree.root.add_child(view)
	await tree.process_frame
	view.set_scene("res://fake_music.tscn")
	await tree.process_frame
	await tree.process_frame
	return {"sc": sc, "shim": shim, "view": view}

func close_view(o: Dictionary) -> void:
	var view: Node = o["view"]
	if view.get_parent() != null:
		view.get_parent().remove_child(view)
	view.free()
	(o["sc"] as Scene).free_all()
