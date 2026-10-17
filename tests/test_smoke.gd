extends "res://addons/godot_synth/tests/test_util.gd"

# A quick regression smoke for the older features: chains, drum kits, songs, the Track
# view over every kind of scene, custom chord intervals and the roll's marquee.

const U := preload("res://addons/godot_synth/tests/test_util.gd")

var _tree: SceneTree

func run(tree: SceneTree) -> void:
	_tree = tree
	_test_chain_flatten()
	_test_kit_routing()
	_test_two_section_song()
	await _test_view_kinds()
	await _test_custom_chord_intervals()
	await _test_roll_marquee()

# ---------------------------------------------------------------------------
# PatternChain
# ---------------------------------------------------------------------------

func _test_chain_flatten() -> void:
	section("chain flatten")
	var a := U.pattern(4.0, [[0.0, 1.0, 0], [2.0, 1.0, 2]])
	var b := U.pattern(2.0, [[0.5, 0.5, 1]])
	var chain := PatternChain.new()
	chain.add_step(a, 1)
	chain.add_step(b, 2, 1, 0.5)
	check_eq(chain.get_play_length(), 8.0, "the length is the sum of length x repeats (4 + 2 x 2)")
	var notes := chain.get_play_notes()
	check_eq(notes.size(), 4, "every repeat's notes are copied in")
	var beats := notes.map(func(n): return n.beat)
	beats.sort()
	check_eq(beats, [0.0, 2.0, 4.5, 6.5], "each note sits at its place in the chain")
	var shifted := notes.filter(func(n): return n.beat >= 4.0)
	check(shifted.all(func(n): return n.octave == 1), "octave_shift moves the step's notes up")
	check(shifted.all(func(n): return is_equal_approx(n.velocity, 0.4)), "velocity_scale scales the step's notes (0.8 x 0.5)")
	check_eq(b.notes[0].octave, 0, "the source pattern is never changed")
	check_eq(b.notes[0].beat, 0.5, "(its beat either)")
	a.add(3.0, 0.5, 4)
	check_eq(chain.get_play_notes().size(), 5, "a note added to a step's pattern shows after the cache rebuilds")
	check_eq(chain.get_step_layout().size(), 3, "the layout has a clip per step and repeat (1 + 2)")
	var outer := PatternChain.new()
	outer.add_step(chain, 2)
	check_eq(outer.get_play_length(), 16.0, "a chain can hold a chain")
	check_eq(outer.get_play_notes().size(), 10, "and flattens both levels")

# ---------------------------------------------------------------------------
# Drum kits
# ---------------------------------------------------------------------------

func _test_kit_routing() -> void:
	section("kit routing")
	var sc := U.make_scene(false)
	sc.drums.synth_channel = 4
	var kit := SynthKit.new()
	var pieces: Array[SynthKitPiece] = [
		SynthKitPiece.create("Kick", 36),
		SynthKitPiece.create("Snare", 38, null, 50, 0.5, 0.25),
	]
	kit.pieces = pieces
	sc.drums.kit = kit
	sc.drums.pattern = U.pattern(4.0, [[0.0, 0.25, 36], [1.0, 0.25, 38], [2.0, 0.25, 40], [3.0, 0.25, 36]], MusicPattern.EditorTrackType.DRUM)
	sc.lead.pattern = null
	sc.pad.pattern = null
	var rig := U.make_rig(_tree.root, null, sc)
	for t in rig["tracks"]:
		t.activate()
	var player: MusicDataPlayer = rig["player"]
	player.music_data = sc.plain_data
	player.play()
	U.step([rig["director"]] + rig["tracks"], 8 * 4)
	var ons: Array = (rig["engine"] as U.RecEngine).ons
	check_eq(ons.size(), 3, "three of the four rows sound (row 40 belongs to no piece)")
	if ons.size() == 3:
		check(ons[0][1] == 4 and ons[0][2] == 36.0, "the kick row plays piece 0 on the track's channel at its note")
		check(ons[1][1] == 5 and ons[1][2] == 50.0, "the snare row plays piece 1 on the next channel at the piece's pitch")
		check_eq(ons[1][3], 0.4, "with the piece's gain (0.8 x 0.5)")
		check_eq(ons[1][4], 0.25, "and pan")
		check_eq(ons[0][3], 0.8, "a piece with gain 1 keeps the velocity")
		check(ons[2][1] == 4 and ons[2][2] == 36.0, "the kick row again")
	_tree.root.remove_child(rig["root"])
	rig["root"].free()
	sc.free_all()

# ---------------------------------------------------------------------------
# A two-section song
# ---------------------------------------------------------------------------

func _test_two_section_song() -> void:
	section("two-section song")
	var sc := U.make_scene(false)
	sc.lead.pattern = null
	sc.drums.pattern = null
	# One chord note on beat 0 and one just before the next downbeat.
	var x := U.pattern(4.0, [[0.0, 0.1, 0], [3.99, 0.1, 0]], MusicPattern.EditorTrackType.CHORD)
	var y := U.pattern(4.0, [[0.0, 0.1, 0]], MusicPattern.EditorTrackType.CHORD)
	var a := MusicSection.create("A", U.progression([MusicData.C], 4))
	a.add_slot(&"Pad", MusicSectionSlot.Mode.PLAY, x)
	var b := MusicSection.create("B", U.progression([MusicData.G], 4))
	b.add_slot(&"Pad", MusicSectionSlot.Mode.PLAY, y)
	var song := MusicSong.new()
	song.bpm = 120.0
	song.add_entry(a).add_entry(b)
	# A frame that does not divide the section length, so a boundary falls inside one.
	var dt := 0.07
	var rig := U.make_rig(_tree.root, song, sc)
	for t in rig["tracks"]:
		t.activate()
	rig["player"].play()
	U.step([rig["director"]] + rig["tracks"], 90, dt)     # 12.6 beats: A, B, A, B
	var ons: Array = (rig["engine"] as U.RecEngine).ons.filter(func(e): return e[1] == 1)
	check_eq(ons.map(func(e): return int(e[2])), [60, 60, 67, 60, 60, 67], "Pad plays C, C, then G at the boundary, then round again")
	if ons.size() >= 3:
		check(absf(ons[0][0] - 0.0) <= 0.15, "the first note is on beat 0 (%s)" % str(ons[0][0]))
		check(ons[1][0] >= 3.99 and ons[1][0] < 4.2, "the late note is played a frame after it was due (%s)" % str(ons[1][0]))
		check_eq(int(ons[1][2]), 60, "against the chord that was playing when it was due, not the new section's")
		check(ons[2][0] >= 4.0 and ons[2][0] < 4.2, "the next section's first note is on its first beat (%s)" % str(ons[2][0]))
	var lengths := [song.entry_start(1), song.get_length_beats(), song.section_length(b)]
	check_eq(lengths, [4.0, 8.0, 4.0], "section starts are exact sums of lengths")
	check_eq(rig["player"].get_current_entry(), 1, "the player is in the second entry at 12.6 beats")
	_tree.root.remove_child(rig["root"])
	rig["root"].free()
	sc.free_all()

# ---------------------------------------------------------------------------
# The Track view over every kind of scene
# ---------------------------------------------------------------------------

func _test_view_kinds() -> void:
	section("track view kinds")
	for kind in ["plain", "chain", "kit", "song"]:
		var sc := U.make_scene(kind == "song")
		if kind == "chain":
			sc.lead.pattern = sc.chain
		var o := await open_view(_tree, sc)
		var view: SynthTrackView = o["view"]
		var pv := U.make_preview(_tree.root)
		view.bind_preview(pv)
		pv.set_music_data(sc.plain_data)
		U.freeze(pv)
		await _tree.process_frame
		check_eq(view.tracks.size(), 3, "%s: three tracks" % kind)
		check_eq(view.get_lanes().size(), 3, "%s: three lanes" % kind)
		check(view.live, "%s: the scene is live" % kind)
		check_eq(view.song != null, kind == "song", "%s: song or not" % kind)
		check(view.get_progression_lane().chips().size() > 0, "%s: the progression is drawn" % kind)
		var summary := view.get_lane_summary()
		check_eq(summary.map(func(s): return s["name"]), ["Lead", "Pad", "Drums"], "%s: lanes in tree order" % kind)
		if kind == "chain":
			check_eq(view.get_lane(0).clips.pattern, sc.chain, "chain: the lane holds the chain")
			check(view.get_lane(0).clips._segs.size() > 0, "chain: a clip per step")
		if kind == "kit":
			view.select_track_index(2) if view.has_method("select_track_index") else view._select_path(view._track_path(sc.drums))
			check_eq(view.get_selected_track(), sc.drums, "kit: the drum track is selected")
			check(view.get_inspector() != null, "kit: the inspector is built")
		for t in view.tracks:
			view._select_path(view._track_path(t))
		# Play, a few frames, stop.
		view.start_song()
		U.freeze(pv)
		check(view.is_song_playing(), "%s: Play starts" % kind)
		U.step([pv.director] + pv.song_tracks, 8 * 6)
		check(not (pv.synth as U.RecEngine).ons.is_empty(), "%s: the lanes make notes" % kind)
		view.stop_song()
		check(not view.is_song_playing(), "%s: Stop stops" % kind)
		view.bind_preview(null)
		_tree.root.remove_child(pv)
		pv.free()
		close_view(o)

# ---------------------------------------------------------------------------
# Custom chord intervals
# ---------------------------------------------------------------------------

func _test_custom_chord_intervals() -> void:
	section("custom chord intervals")
	var sc := U.make_scene(false)
	var o := await open_view(_tree, sc)
	var view: SynthTrackView = o["view"]
	var shim: U.UndoShim = o["shim"]
	var pv := U.make_preview(_tree.root)
	view.bind_preview(pv)
	pv.set_music_data(sc.plain_data)
	await _tree.process_frame
	var iv := PackedInt32Array([0, 3, 6, 9, 14])
	check(view.set_block_property(0, &"chord_intervals", iv), "set_block_property accepts custom chord intervals")
	check_eq(sc.plain_data.blocks[0].chord_intervals, iv, "the block holds them (a ninth above the octave included)")
	check_eq(sc.plain_data.blocks[1].chord_intervals, MusicData.CHORD_MAJ, "the other block is untouched")
	check_eq(shim.steps(), 1, "one undo step")
	shim.undo()
	view.refresh(true)
	check_eq(sc.plain_data.blocks[0].chord_intervals, MusicData.CHORD_MAJ, "undo restores the triad")
	shim.redo()
	view.refresh(true)
	check_eq(sc.plain_data.blocks[0].chord_intervals, iv, "redo sets them again")
	# Through the drawer: pick a block, choose Custom, edit the chips.
	view._select_block(1)
	var ctl := view.get_drawer_controls()
	view._on_quality_selected(SynthHarmony.chord_table().size())
	check(ctl["chord_editor"].visible, "choosing Custom opens the chord tone editor")
	ctl["chord_editor"].intervals_changed.emit(PackedInt32Array([0, 4, 7, 10, 14]))
	check_eq(sc.plain_data.blocks[1].chord_intervals, PackedInt32Array([0, 4, 7, 10, 14]), "an edit in the editor lands in the block")
	check_eq(shim.steps(), 2, "as an undo step of its own")
	check(ctl["chord_editor"].visible, "and the editor stays open")
	# The pad resolves a fifth chord tone from the new intervals.
	var rig := U.make_rig(_tree.root, null, sc)
	for t in rig["tracks"]:
		t.activate()
	var chord_pat := U.pattern(4.0, [[0.0, 1.0, 4]], MusicPattern.EditorTrackType.CHORD)
	rig["tracks"][1].pattern = chord_pat
	rig["player"].music_data = sc.plain_data
	rig["player"].play()
	U.step([rig["director"]] + rig["tracks"], 8)
	var ons: Array = (rig["engine"] as U.RecEngine).ons.filter(func(e): return e[1] == 1)
	check(ons.size() == 1 and int(ons[0][2]) == 60 + 14, "chord tone 4 of C + [0, 3, 6, 9, 14] is the 14th semitone above the root: %s" % str(ons))
	_tree.root.remove_child(rig["root"])
	rig["root"].free()
	view.bind_preview(null)
	_tree.root.remove_child(pv)
	pv.free()
	close_view(o)

# ---------------------------------------------------------------------------
# The roll's marquee
# ---------------------------------------------------------------------------

func _test_roll_marquee() -> void:
	section("roll marquee")
	var roll := SynthRoll.new()
	roll.size = Vector2(900, 500)
	_tree.root.add_child(roll)
	await _tree.process_frame
	var pat := U.pattern(4.0, [[0.0, 0.5, 0], [1.0, 0.5, 2], [2.0, 0.5, 4], [3.0, 0.5, 2]], MusicPattern.EditorTrackType.MELODY)
	roll.track_type = MusicTrack.TrackType.MELODY
	roll.pattern = pat
	await _tree.process_frame
	await _tree.process_frame
	var area := roll.get_area()
	check(area.size.x > 100.0, "the roll has an area (%s)" % str(area))
	for n in pat.notes:
		check(area.encloses(roll.note_rect(n)) or area.intersects(roll.note_rect(n)), "note at beat %s is on screen" % n.beat)
	# Empty space left of the first note, above every row.
	var top := area.position.y + 2.0
	var from := Vector2(roll.beat_to_x(0.0) + 1.0, top)
	check(roll._note_at(from) == null, "the marquee starts on empty space")
	var to := Vector2(roll.beat_to_x(1.6), area.end.y - 2.0)
	_mouse(roll, from, true, true)
	_motion(roll, from + Vector2(30, 30), true)
	_motion(roll, to, true)
	_mouse(roll, to, false, true)
	var picked := roll.get_selected()
	check_eq(picked.size(), 2, "Ctrl-drag selects the notes the box touches")
	check(pat.notes[0] in picked and pat.notes[1] in picked, "the first two notes (beats 0 and 1)")
	check(not (pat.notes[2] in picked), "not the ones past the box")
	check_eq(pat.notes.size(), 4, "and draws no note")
	# Shift-drag adds a second box to the selection.
	var from2 := Vector2(roll.beat_to_x(2.6), top)
	var to2 := Vector2(roll.beat_to_x(3.9), area.end.y - 2.0)
	_mouse(roll, from2, true, false, true)
	_motion(roll, from2 + Vector2(30, 30), false, true)
	_motion(roll, to2, false, true)
	_mouse(roll, to2, false, false, true)
	check_eq(roll.get_selected().size(), 3, "Shift-drag adds the notes of a second box")
	check(pat.notes[3] in roll.get_selected() and pat.notes[0] in roll.get_selected(), "to the earlier selection")
	# A Ctrl-drag without Shift replaces the selection.
	_mouse(roll, from, true, true)
	_motion(roll, from + Vector2(30, 30), true)
	_motion(roll, Vector2(roll.beat_to_x(0.7), area.end.y - 2.0), true)
	_mouse(roll, Vector2(roll.beat_to_x(0.7), area.end.y - 2.0), false, true)
	check_eq(roll.get_selected(), [pat.notes[0]], "a new Ctrl-drag replaces it")
	_tree.root.remove_child(roll)
	roll.free()

func _mouse(roll: SynthRoll, pos: Vector2, pressed: bool, ctrl: bool = false, shift: bool = false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	roll._gui_input(ev)

func _motion(roll: SynthRoll, pos: Vector2, ctrl: bool = false, shift: bool = false) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	roll._gui_input(ev)
