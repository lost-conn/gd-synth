extends "res://addons/godot_synth/tests/test_util.gd"

# The Track view over a MusicSong: the section strip, the per-section progressions
# and lanes, every section / entry / song edit with its undo, the preview against the
# real MusicDataPlayer, Convert to song and Save song as. In-memory resources; the
# save test writes under user:// and removes what it wrote.

const U := preload("res://addons/godot_synth/tests/test_util.gd")
const SAVE_SCENE := "user://synth_test_song_scene.tscn"
const SAVE_SONG := "user://synth_test_song_saved.tres"

var _tree: SceneTree

func run(tree: SceneTree) -> void:
	_tree = tree
	await _test_strip()
	await _test_progression_lane()
	await _test_lane_regions()
	await _test_selection_and_panel()
	await _test_edits()
	await _test_panel_controls()
	await _test_own_progression()
	await _test_read_only()
	await _test_preview_matches_player()
	await _test_view_preview()
	await _test_convert()
	await _test_save_song()
	await _test_plain_scene()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A view over a song scene (or a plain one), the scene as the editor's open scene.
func _open(with_song: bool = true) -> Dictionary:
	return await open_view(_tree, U.make_scene(with_song))

func _close(o: Dictionary) -> void:
	close_view(o)

func _click(c: Control, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	c._gui_input(ev)

func _blocks_desc(d: MusicData) -> String:
	if d == null:
		return "-"
	var s := "%d:%.1f[" % [d.get_instance_id(), d.bpm]
	for b in d.blocks:
		s += "%d/%s/%d," % [b.chord_root, str(b.chord_intervals), b.duration_beats]
	return s + "]"

# Everything the song says, as text: it differs after any edit and returns after its undo.
func _describe(song: MusicSong) -> String:
	if song == null:
		return "no song"
	var s := "id=%d bpm=%.2f bpb=%d loop=%d prog=%s|" % [song.get_instance_id(), song.bpm, song.beats_per_bar, song.loop_entry, _blocks_desc(song.progression)]
	for e in song.entries:
		s += "E(%d,%d)" % [e.section.get_instance_id() if e.section != null else 0, e.repeats]
	for sec in song.get_reachable_sections():
		s += "|S(%d,%s,%d,%s:" % [sec.get_instance_id(), sec.name, sec.repeats, _blocks_desc(sec.progression)]
		for slot in sec.slots:
			s += "%d/%s/%d/%d;" % [slot.get_instance_id(), slot.track, int(slot.mode), slot.pattern.get_instance_id() if slot.pattern != null else 0]
		s += ")"
	s += "|B"
	for b in song.also_bake:
		s += "%d," % b.get_instance_id()
	return s

# Run [param edit], then undo it, redo it, checking after each that the song says what
# it should and that the edit was exactly one undo step. Leaves the edit applied.
func _cycle(label: String, o: Dictionary, edit: Callable, steps: int = 1) -> void:
	var view: SynthTrackView = o["view"]
	var shim: U.UndoShim = o["shim"]
	var before := _describe(view.song)
	var n0 := shim.steps()
	var ok = edit.call()
	var after := _describe(view.song)
	check(ok != false, "%s: the edit was accepted" % label)
	check(after != before, "%s: it changed the song" % label)
	check_eq(shim.steps() - n0, steps, "%s: undo steps" % label)
	shim.undo()
	view.refresh(true)
	check_eq(_describe(view.song), before, "%s: undo restores the song" % label)
	shim.redo()
	view.refresh(true)
	check_eq(_describe(view.song), after, "%s: redo repeats it" % label)

# ---------------------------------------------------------------------------
# The strip
# ---------------------------------------------------------------------------

func _test_strip() -> void:
	section("section strip")
	var o := await _open()
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var strip := view.get_strip()
	check(view.song == sc.song, "the view found the song")
	check(strip.get_parent().visible, "the strip row is shown for a song")
	var chips := strip.chips()
	check_eq(chips.size(), 5, "one chip per entry repeat (1 + 2 + 1 + 1)")
	if chips.size() == 5:
		var want_entry := [0, 1, 1, 2, 3]
		var want_repeat := [0, 0, 1, 0, 0]
		var want_len := [8.0, 8.0, 8.0, 16.0, 8.0]
		var unit: float = (chips[0]["rect"] as Rect2).size.x + 2.0
		for i in 5:
			var c: Dictionary = chips[i]
			check_eq(c["entry"], want_entry[i], "chip %d entry" % i)
			check_eq(c["repeat"], want_repeat[i], "chip %d repeat" % i)
			var r: Rect2 = c["rect"]
			check(absf((r.size.x + 2.0) / unit - want_len[i] / 8.0) < 0.01, "chip %d is sized by its length (%s)" % [i, r])
			if i > 0:
				check(r.position.x > (chips[i - 1]["rect"] as Rect2).position.x, "chip %d is right of chip %d" % [i, i - 1])
		check_eq((chips[0]["rect"] as Rect2).position.x, 1.0, "the first chip starts at the strip's left edge")
		check_eq(chips[0]["label"], "Intro", "a chip is named after its section")
		check(String(chips[1]["label"]).begins_with("Verse") and String(chips[1]["label"]).contains("1/2"), "a repeated entry numbers its chips: " + chips[1]["label"])
		check(chips[1]["color"] == chips[2]["color"] and chips[1]["color"] == chips[4]["color"], "a reused section keeps its colour")
		check(chips[0]["color"] != chips[1]["color"] and chips[1]["color"] != chips[3]["color"] and chips[0]["color"] != chips[3]["color"], "different sections have different colours")
		var loops := chips.filter(func(c): return c["loop"])
		check_eq(loops.size(), 1, "exactly one chip carries the loop marker")
		check_eq(loops[0]["entry"] if loops.size() == 1 else -1, 1, "the loop marker is on the loop entry")
		# Selecting by clicking a chip.
		check_eq(view.selected_entry, 0, "the first entry starts selected")
		var got: Array = []
		strip.entry_selected.connect(func(i: int): got.append(i))
		_click(strip, (chips[3]["rect"] as Rect2).get_center())
		check_eq(view.selected_entry, 3 - 1, "clicking the chorus chip selects its entry")
		check_eq(strip.selected_entry, 2, "the strip shows the selection")
		check_eq(got, [2], "entry_selected fired once")
		check(view.selected_section() == sc.chorus, "the selection is the chorus")
		_click(strip, (chips[2]["rect"] as Rect2).get_center())
		check_eq(view.selected_entry, 1, "a later repeat's chip selects the entry")
		check_eq(strip.chip_rect(1, 1), chips[2]["rect"], "chip_rect finds a repeat")
		_click(strip, Vector2(-5, 2))
		check_eq(view.selected_entry, 1, "a click off every chip changes nothing")
	_close(o)

# ---------------------------------------------------------------------------
# The progression lane
# ---------------------------------------------------------------------------

func _test_progression_lane() -> void:
	section("progression lane")
	var o := await _open()
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var lane := view.get_progression_lane()
	var chips := lane.chips()
	check_eq(chips.size(), 12, "blocks of every section end to end (2 + 2 + 2 + 4 + 2)")
	var per_entry := {}
	for c in chips:
		per_entry[c["entry"]] = per_entry.get(c["entry"], 0) + 1
	check_eq(per_entry.get(0, 0), 2, "the intro shows the song's two blocks")
	check_eq(per_entry.get(1, 0), 4, "the verse shows its blocks once per repeat")
	check_eq(per_entry.get(2, 0), 4, "the chorus shows its own four blocks")
	check_eq(per_entry.get(3, 0), 2, "the reused verse shows its blocks again")
	var starts := view.timeline.block_starts()
	check_eq(starts.size(), 12, "the timeline lists the same blocks")
	if starts.size() == 12:
		var chorus_roots: Array = []
		for e in starts:
			if e[3] == sc.chorus_data:
				chorus_roots.append(e[2].chord_root)
		check_eq(chorus_roots, [MusicData.G, MusicData.C, MusicData.A, MusicData.F], "the chorus lane holds the chorus's own chords")
		check_eq(starts[0][0], 0.0, "the first block starts at beat 0")
		check_eq(starts[2][0], 8.0, "the verse's first block starts at beat 8")
		check_eq(starts[6][0], 24.0, "the chorus starts at beat 24")
		check_eq(starts[10][0], 40.0, "the last verse starts at beat 40")
		check(starts[0][3] == sc.song_data and starts[2][3] == sc.song_data, "sections without a progression show the song's")
	var dim := chips.filter(func(c): return c["repeat"])
	check_eq(dim.size(), 2, "only the second pass of a repeated entry is dimmed")
	# The rects follow the lengths: the chorus blocks end to end.
	var chorus_rects := chips.filter(func(c): return c["entry"] == 2).map(func(c): return c["rect"])
	check_eq(chorus_rects.size(), 4, "four chorus chips")
	if chorus_rects.size() == 4:
		check(absf((chorus_rects[1].position.x - chorus_rects[0].position.x) - (chorus_rects[2].position.x - chorus_rects[1].position.x)) < 0.01, "equal blocks are equally wide")
	# Clicking a chorus block selects the chorus and the block.
	_click(lane, (chips.filter(func(c): return c["entry"] == 2)[2]["rect"] as Rect2).get_center())
	check_eq(view.selected_entry, 2, "clicking a block selects its section")
	check_eq(view.get_selected_block(), 2, "and the block")
	check(view.get_data() == sc.chorus_data, "the drawer edits the chorus's progression")
	_click(lane, (chips.filter(func(c): return c["entry"] == 0)[1]["rect"] as Rect2).get_center())
	check_eq(view.selected_entry, 0, "a block of the song's progression selects its section")
	check(view.get_data() == sc.song_data, "and the drawer edits the song's progression")
	_close(o)

# ---------------------------------------------------------------------------
# The lanes
# ---------------------------------------------------------------------------

func _test_lane_regions() -> void:
	section("lane regions")
	var o := await _open()
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var K := SynthSongLayout.Kind
	var C := SynthSongLayout.Carry
	check_eq(view.get_lanes().size(), 3, "a lane per track")
	var lead := view.get_lane(0).clips.regions
	var pad := view.get_lane(1).clips.regions
	var drums := view.get_lane(2).clips.regions
	check_eq(lead.size(), 5, "a region per chip")
	check_eq(pad.size(), 5, "a region per chip (pad)")
	check_eq(drums.size(), 5, "a region per chip (drums)")
	if lead.size() == 5 and pad.size() == 5 and drums.size() == 5:
		# Lead: silent intro, then the chain, the chorus riff, the chain.
		check_eq(lead.map(func(r): return r["kind"]), [K.SILENT, K.PLAY, K.PLAY, K.PLAY, K.PLAY], "Lead kinds")
		check(lead[1]["pattern"] == sc.chain and lead[3]["pattern"] == sc.lead_b and lead[4]["pattern"] == sc.chain, "Lead plays the chain, then the chorus riff")
		check(lead[0]["pattern"] == null, "a silent region has no pattern")
		check_eq(lead[2]["origin"], 16.0, "a repeated PLAY restarts at its own chip")
		# Pad: plays the intro, keeps through the verse, plays the chorus, keeps.
		check_eq(pad.map(func(r): return r["kind"]), [K.PLAY, K.KEEP, K.KEEP, K.PLAY, K.KEEP], "Pad kinds (an unlisted track keeps)")
		check_eq(pad.map(func(r): return r["carry"]), [C.PLAY, C.PLAY, C.PLAY, C.PLAY, C.PLAY], "Pad carries its pattern")
		check(pad[1]["pattern"] == sc.pad_a and pad[2]["pattern"] == sc.pad_a and pad[4]["pattern"] == sc.pad_b, "a KEEP region continues the pattern of the last PLAY")
		check_eq(pad[1]["origin"], 0.0, "and its origin is where that PLAY started")
		check_eq(pad[4]["origin"], 24.0, "the later keep continues the chorus's pattern from the chorus start")
		# Drums: its own pattern until the verse plays it, keep in the chorus.
		check_eq(drums.map(func(r): return r["kind"]), [K.KEEP, K.PLAY, K.PLAY, K.KEEP, K.PLAY], "Drums kinds (an explicit Keep slot keeps)")
		check_eq(drums[0]["carry"], C.OWN, "an active track carries its own pattern from the start")
		check(drums[0]["pattern"] == sc.drums_a and drums[3]["pattern"] == sc.drums_a, "the drums keep drums_a")
		# Selection tint and boundaries are data on the lane.
		check_eq(view.get_lane(0).clips.selected_entry, 0, "the lane marks the selected entry")
	# A track that is not active at the start and never played says "off".
	var late := SynthSongLayout.lane_regions(sc.song, &"Nobody", null, false)
	check_eq(late.map(func(r): return r["carry"]), [C.NONE, C.NONE, C.NONE, C.NONE, C.NONE], "an inactive unlisted track stays off")
	check_eq(late.map(func(r): return r["kind"]), [K.KEEP, K.KEEP, K.KEEP, K.KEEP, K.KEEP], "and keeps")
	# Region hit-testing.
	var clips := view.get_lane(0).clips
	var r3 := clips.region_rect(3)
	check_eq(clips.region_at(r3.get_center()), 3, "region_at finds the chorus region")
	var pressed: Array = []
	clips.region_pressed.connect(func(e: int): pressed.append(e))
	_click(clips, r3.get_center())
	check_eq(pressed, [2], "pressing a region reports its entry")
	check_eq(view.selected_entry, 2, "and selects it")
	# The warning on a lane covers the patterns the song plays on it.
	var wrong := U.pattern(2.0, [[0.0, 1.0, 0]], MusicPattern.EditorTrackType.DRUM)
	sc.chorus.slots[0].pattern = wrong     # Lead is a Melody track
	view.refresh(true)
	check(view.get_lane(0).get_warning_text().contains("Chorus"), "a lane warns about a mismatched pattern in a section: " + view.get_lane(0).get_warning_text())
	_close(o)

# ---------------------------------------------------------------------------
# Selection, the panel and the ruler
# ---------------------------------------------------------------------------

func _test_selection_and_panel() -> void:
	section("selection and panel")
	var o := await _open()
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var panel := view.get_song_panel()
	var ctl := panel.get_controls()
	check(panel.visible, "the song panel is shown")
	check(not panel.is_read_only(), "the panel is editable in a live scene")
	check(ctl["section_box"].visible, "the section editor shows for the selected entry")
	check_eq(ctl["name"].text, "Intro", "the section's name")
	check_eq(int(ctl["repeats"].value), 1, "the section's repeats")
	check(not ctl["own"].button_pressed, "Own progression is off for a section on the song's")
	check_eq(panel.get_slot_count(), 3, "one slot row per MusicTrack")
	var modes := []
	for i in 3:
		modes.append(panel.get_slot_row(i)["mode"].get_selected_id())
	check_eq(modes, [MusicSectionSlot.Mode.SILENT, MusicSectionSlot.Mode.PLAY, MusicSectionSlot.Mode.KEEP], "Lead is silent, Pad plays, Drums (no slot) keeps")
	check(panel.get_slot_row(1)["field"].visible and not panel.get_slot_row(0)["field"].visible, "the pattern field shows for Play only")
	view.select_entry(2)
	check_eq(ctl["name"].text, "Chorus", "selecting an entry shows its section")
	check(ctl["own"].button_pressed, "the chorus has its own progression")
	check(ctl["entry_info"].text.begins_with("entry 3 of 4"), "the entry readout")
	check(ctl["loop_here"].disabled == false, "Loop from here is offered on a non-loop entry")
	view.select_entry(1)
	check(ctl["loop_here"].disabled, "Loop from here is disabled on the loop entry")
	check(ctl["entry_info"].text.contains("loops"), "the readout marks the loop entry")
	check(ctl["left"].disabled == false and ctl["right"].disabled == false, "move buttons are on for a middle entry")
	view.select_entry(0)
	check(ctl["left"].disabled, "the first entry cannot move left")
	# Ruler and span are in song time.
	check_eq(view.timeline.span, 48.0, "the timeline spans one pass of the song")
	check_eq(view.timeline.cursor_of(50.0), 10.0, "a beat after the end folds into the loop region")
	check_eq(view.timeline.cursor_of(20.0), 20.0, "a beat inside the song is itself")
	check_eq(SynthSongLayout.fold(sc.song, 48.0), 8.0, "the end folds back to the loop entry")
	check_eq(SynthSongLayout.fold(sc.song, 89.0), 8.0 + fposmod(89.0 - 48.0, 40.0), "two loops later")
	# The playhead maps the director's beat onto the song.
	check_eq(view.get_playhead().beat_of(30.0), 30.0, "the playhead is at the song beat while stopped")
	_close(o)

# ---------------------------------------------------------------------------
# Edits: each one undo step
# ---------------------------------------------------------------------------

func _test_edits() -> void:
	section("edits")
	var o := await _open()
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var shim: U.UndoShim = o["shim"]
	var song := sc.song

	# Song settings.
	_cycle("bpm", o, func(): view.set_bpm(100.0); return true)
	check_eq(song.bpm, 100.0, "the BPM field edits the song's bpm")
	check_eq(sc.song_data.bpm, 120.0, "and not the progression's")
	_cycle("beats per bar", o, func(): return view.set_beats_per_bar(3))
	check_eq(song.beats_per_bar, 3, "beats_per_bar is set")
	_cycle("loop point", o, func(): return view.set_loop_entry(3))
	check_eq(song.loop_entry, 3, "loop_entry is set")
	check_eq(view.set_loop_entry(3), false, "setting the loop point where it is does nothing")
	song.loop_entry = 1
	view.refresh(true)

	# also_bake.
	view.select_entry(0)
	_cycle("also_bake new section", o, func(): return view.add_also_bake(null))
	check_eq(song.also_bake.size(), 1, "a new empty section is listed in also_bake")
	check_eq(song.also_bake[0].name, "Section 1", "named after the first free number")
	_cycle("also_bake existing", o, func(): return view.add_also_bake(sc.intro))
	check_eq(song.also_bake.size(), 2, "an existing section is listed too")
	check_eq(view.add_also_bake(sc.intro), false, "a section already listed is not added twice")
	_cycle("remove also_bake", o, func(): return view.remove_also_bake(0))
	check_eq(song.also_bake.size(), 1, "one left after a remove")
	check(song.also_bake[0] == sc.intro, "the right one")
	_cycle("remove last also_bake", o, func(): return view.remove_also_bake(0))
	check(song.also_bake.is_empty(), "none left")

	# Sections.
	view.select_entry(1)
	_cycle("section name", o, func(): return view.set_section_name(sc.verse, "Refrain"))
	check_eq(sc.verse.name, "Refrain", "the section is renamed")
	check(String(view.get_strip().chips()[1]["label"]).begins_with("Refrain"), "and the strip shows it")
	_cycle("section repeats", o, func(): return view.set_section_repeats(sc.verse, 2))
	check_eq(sc.verse.repeats, 2, "section repeats")
	check_eq(song.section_length(sc.verse), 16.0, "a section's repeats lengthen it")
	check_eq(view.timeline.span, 8.0 + 32.0 + 16.0 + 16.0, "and the timeline")
	check_eq(view.get_progression_lane().chips().size(), 18, "the progression lane shows each repeat (2 + 8 + 4 + 4)")
	sc.verse.repeats = 1
	view.refresh(true)

	# Slots.
	view.select_entry(2)
	_cycle("slot mode silent", o, func(): return view.set_slot_mode(sc.chorus, &"Lead", MusicSectionSlot.Mode.SILENT))
	check_eq(sc.chorus.get_slot(&"Lead").mode, MusicSectionSlot.Mode.SILENT, "the slot is silent")
	check_eq(view.get_lane(0).clips.regions[3]["kind"], SynthSongLayout.Kind.SILENT, "and the lane draws it silent")
	_cycle("slot pattern", o, func(): return view.set_slot_pattern(sc.chorus, &"Pad", sc.pad_a))
	check(sc.chorus.get_slot(&"Pad").pattern == sc.pad_a, "the slot plays another pattern")
	_cycle("slot new play", o, func(): return view.set_slot_mode(sc.verse, &"Pad", MusicSectionSlot.Mode.PLAY))
	check(sc.verse.get_slot(&"Pad") != null and sc.verse.get_slot(&"Pad").mode == MusicSectionSlot.Mode.PLAY, "a track with no slot gets one")
	check(sc.verse.get_slot(&"Pad").pattern == null, "playing the track's own pattern")
	_cycle("slot new play drums", o, func(): return view.set_slot_mode(sc.chorus, &"Drums", MusicSectionSlot.Mode.PLAY))
	var before_keep := _describe(song)
	var n_before := shim.steps()
	check(view.set_slot_mode(sc.verse, &"Lead", MusicSectionSlot.Mode.PLAY), "a no-op mode is accepted")
	check_eq(view.set_slot_mode(sc.intro, &"Drums", MusicSectionSlot.Mode.KEEP), true, "Keep on an unlisted track is accepted")
	check_eq(_describe(song), before_keep, "and changes nothing")
	check_eq(shim.steps(), n_before, "and records no undo step")

	# Entries.
	var entries0 := song.entries.size()
	view.select_entry(2)
	_cycle("add section", o, func(): return view.add_section_entry())
	check_eq(song.entries.size(), entries0 + 1, "an entry is added")
	check_eq(view.selected_entry, 3, "after the selected one, which it selects")
	var fresh := song.entries[3].section
	check(fresh != null and fresh.name == "Section 1" and fresh.slots.is_empty() and fresh.progression == null, "with a new, empty section")
	check(fresh not in [sc.intro, sc.verse, sc.chorus], "that nothing else shares")
	check_eq(song.section_length(fresh), 8.0, "playing the song's progression")
	check_eq(song.loop_entry, 1, "an entry after the loop point leaves it")
	_cycle("remove entry", o, func(): return view.remove_entry(3))
	check_eq(song.entries.size(), entries0, "the entry is gone")
	view.select_entry(2)
	_cycle("add existing", o, func(): return view.add_existing_entry(sc.intro))
	check(song.entries[3].section == sc.intro, "the entry shares the section, not a copy")
	check_eq(song.get_reachable_sections().size(), 3, "so the song has no new section")
	var chips := view.get_strip().chips()
	check(chips[0]["color"] == chips[chips.size() - 2]["color"] or chips[0]["color"] == chips[4]["color"], "and the same colour")
	_cycle("remove added", o, func(): return view.remove_entry(3))
	view.select_entry(2)
	_cycle("duplicate section", o, func(): return view.duplicate_entry(2))
	var copy := song.entries[3].section
	check(copy != sc.chorus, "the duplicate is a new section")
	check_eq(copy.name, "Chorus copy", "named after the original")
	check(copy.progression != null and copy.progression != sc.chorus_data, "with its own copy of the progression")
	check_eq(_blocks_desc(copy.progression).substr(_blocks_desc(copy.progression).find(":")), _blocks_desc(sc.chorus_data).substr(_blocks_desc(sc.chorus_data).find(":")), "whose blocks equal the original's")
	check(copy.progression.blocks[0] != sc.chorus_data.blocks[0], "but are not shared")
	check_eq(copy.slots.size(), sc.chorus.slots.size(), "slots are copied")
	var shared := false
	for s in copy.slots:
		shared = shared or sc.chorus.slots.has(s)
	check(not shared, "as new slot objects")
	check(copy.get_slot(&"Pad").pattern == sc.chorus.get_slot(&"Pad").pattern, "that share the patterns")
	# Editing the copy leaves the original alone.
	copy.slots[0].mode = MusicSectionSlot.Mode.KEEP
	check(sc.chorus.slots[0].mode != MusicSectionSlot.Mode.KEEP, "editing the copy leaves the chorus alone")
	copy.slots[0].mode = sc.chorus.slots[0].mode
	_cycle("remove duplicate", o, func(): return view.remove_entry(3))
	# Inserting before the loop entry keeps the loop on the same entry.
	view.select_entry(0)
	var loop_section := song.entries[song.loop_entry].section
	_cycle("add before loop", o, func(): return view.add_section_entry())
	check_eq(song.loop_entry, 2, "inserting before the loop entry moves the loop point with it")
	check(song.entries[song.loop_entry].section == loop_section, "which is still the same section")
	_cycle("remove before loop", o, func(): return view.remove_entry(1))
	check(song.entries[song.loop_entry].section == loop_section, "removing an earlier entry keeps the loop on its section")
	# Reorder.
	view.select_entry(1)
	var order0 := song.entries.map(func(e): return e.section)
	_cycle("move right", o, func(): return view.move_entry(1, 1))
	check(song.entries[2].section == order0[1] and song.entries[1].section == order0[2], "entries swap")
	check_eq(view.selected_entry, 2, "the selection follows the entry")
	check(song.entries[song.loop_entry].section == loop_section, "the loop point stays on its section")
	_cycle("move left", o, func(): return view.move_entry(2, -1))
	check_eq(view.move_entry(0, -1), false, "the first entry cannot move left")
	check_eq(view.move_entry(song.entries.size() - 1, 1), false, "the last cannot move right")
	# Repeats, with spin merging.
	view.select_entry(1)
	_cycle("entry repeats", o, func(): return view.set_entry_repeats(1, 3))
	check_eq(song.entries[1].repeats, 3, "the entry plays three times")
	check_eq(view.get_strip().chips().size(), 6, "and the strip shows each")
	var steps0 := shim.steps()
	view.set_entry_repeats(1, 4, true)
	view.set_entry_repeats(1, 5, true)
	view.set_entry_repeats(1, 6, true)
	check_eq(shim.steps() - steps0, 1, "spin clicks merge into one undo step")
	shim.undo()
	view.refresh(true)
	check_eq(song.entries[1].repeats, 3, "and one undo undoes them all")
	shim.redo()
	view.refresh(true)
	check_eq(song.entries[1].repeats, 6, "and one redo repeats them")
	song.entries[1].repeats = 1
	# The last entry stays.
	while song.entries.size() > 1:
		song.entries.remove_at(song.entries.size() - 1)
	view.refresh(true)
	check_eq(view.remove_entry(0), false, "the last entry cannot be removed")
	_close(o)

# ---------------------------------------------------------------------------
# The panel's own controls
# ---------------------------------------------------------------------------

func _test_panel_controls() -> void:
	section("panel controls")
	var o := await _open()
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var shim: U.UndoShim = o["shim"]
	var panel := view.get_song_panel()
	var ctl := panel.get_controls()
	view.select_entry(1)
	# Name.
	ctl["name"].text = "Refrain"
	ctl["name"].text_submitted.emit("Refrain")
	check_eq(sc.verse.name, "Refrain", "typing a name renames the section")
	check_eq(shim.steps(), 1, "in one undo step")
	shim.undo()
	view.refresh(true)
	check_eq(sc.verse.name, "Verse", "undo gives the name back")
	check_eq(ctl["name"].text, "Verse", "and the field")
	# Repeats and entry repeats.
	ctl["repeats"].value = 2
	check_eq(sc.verse.repeats, 2, "the section repeats spin edits the section")
	ctl["entry_repeats"].value = 4
	check_eq(song_of(view).entries[1].repeats, 4, "the entry repeats spin edits the entry")
	# Mode drop-down: Lead in the verse is a Play slot; make it Silent.
	var row := panel.get_slot_row(0)
	var mode: OptionButton = row["mode"]
	mode.select(mode.get_item_index(MusicSectionSlot.Mode.SILENT))
	mode.item_selected.emit(mode.get_selected())
	check_eq(sc.verse.get_slot(&"Lead").mode, MusicSectionSlot.Mode.SILENT, "the mode drop-down sets the slot")
	check(not panel.get_slot_row(0)["field"].visible, "and the pattern field hides")
	# The pattern field.
	row = panel.get_slot_row(1)
	row["field"].resource_changed.emit(sc.pad_b)
	check(sc.verse.get_slot(&"Pad").pattern == sc.pad_b, "the pattern field sets (and creates) the slot's pattern")
	check_eq(sc.verse.get_slot(&"Pad").mode, MusicSectionSlot.Mode.PLAY, "as a Play slot")
	# Open in Pattern.
	var opened: Array = []
	view.pattern_requested.connect(func(p, _patch): opened.append(p))
	row["open"].pressed.emit()
	check(opened.size() == 1 and opened[0] == sc.pad_b, "Open in Pattern asks for the slot's pattern")
	panel.get_slot_row(2)["open"].pressed.emit()
	check(opened.size() == 2 and opened[1] == sc.drums_a, "a slot without a pattern opens the track's own")
	# Buttons.
	var n := song_of(view).entries.size()
	ctl["add_new"].pressed.emit()
	check_eq(song_of(view).entries.size(), n + 1, "Add section adds an entry")
	ctl["duplicate"].pressed.emit()
	check_eq(song_of(view).entries.size(), n + 2, "Duplicate adds another")
	ctl["left"].pressed.emit()
	ctl["right"].pressed.emit()
	ctl["loop_here"].pressed.emit()
	check_eq(song_of(view).loop_entry, view.selected_entry, "Loop from here sets the loop point")
	ctl["remove"].pressed.emit()
	check_eq(song_of(view).entries.size(), n + 1, "Remove removes the selected entry")
	# Beats per bar, bpm and also_bake.
	ctl["beats_per_bar"].value = 6
	check_eq(song_of(view).beats_per_bar, 6, "the beats per bar spin")
	var hdr := view.get_header_controls()
	hdr["bpm"].value = 90
	check_eq(song_of(view).bpm, 90.0, "the header BPM edits the song")
	panel.get_controls()["bake_add"].get_popup().id_pressed.emit(0)
	check_eq(song_of(view).also_bake.size(), 1, "also_bake: Add > New section")
	check_eq(panel.get_also_bake_chips().size(), 1, "shown as a chip")
	panel.get_also_bake_chips()[0].get_child(1).pressed.emit()
	check_eq(song_of(view).also_bake.size(), 0, "and its x removes it")
	# Add existing from the menu.
	var count := song_of(view).entries.size()
	ctl["add_existing"].get_popup().id_pressed.emit(0)
	check_eq(song_of(view).entries.size(), count + 1, "Add existing adds an entry")
	_close(o)

func song_of(view: SynthTrackView) -> MusicSong:
	return view.song

# ---------------------------------------------------------------------------
# Own progression and block edits
# ---------------------------------------------------------------------------

func _test_own_progression() -> void:
	section("own progression")
	var o := await _open()
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var shim: U.UndoShim = o["shim"]
	var song := sc.song
	var panel := view.get_song_panel()
	var ctl := panel.get_controls()
	view.select_entry(0)
	check(view.get_data() == sc.song_data, "the intro edits the song's progression")
	_cycle("own on", o, func(): return view.set_own_progression(sc.intro, true))
	var own := sc.intro.progression
	check(own != null and own != sc.song_data, "turning Own progression on creates a copy")
	check_eq(own.blocks.size(), 2, "of the progression the section played")
	check(own.blocks[0] != sc.song_data.blocks[0], "whose blocks are copies")
	check_eq(own.blocks[1].chord_root, MusicData.F, "with the same chords")
	check_eq(own.bpm, song.bpm, "and the song's tempo")
	check(view.get_data() == own, "the drawer now edits the copy")
	check(ctl["own"].button_pressed, "the toggle shows it")
	# A block edit lands in the section's copy only.
	view.select_entry(0)
	var steps := shim.steps()
	check(view.set_block_property(0, &"chord_root", MusicData.D), "a block edit is accepted")
	check_eq(shim.steps() - steps, 1, "as one undo step")
	check_eq(own.blocks[0].chord_root, MusicData.D, "the section's copy changed")
	check_eq(sc.song_data.blocks[0].chord_root, MusicData.C, "the song's progression did not")
	shim.undo()
	view.refresh(true)
	check_eq(own.blocks[0].chord_root, MusicData.C, "undo restores the block")
	shim.redo()
	view.refresh(true)
	check_eq(own.blocks[0].chord_root, MusicData.D, "redo repeats it")
	# Add and remove a block in the copy.
	view.select_entry(0)
	view._select_block(0)
	var len0 := own.blocks.size()
	view.add_block()
	check_eq(own.blocks.size(), len0 + 1, "a block is added to the copy")
	check_eq(sc.song_data.blocks.size(), 2, "and not to the song's")
	check_eq(song.section_length(sc.intro), 12.0, "the section is longer")
	shim.undo()
	view.refresh(true)
	check_eq(own.blocks.size(), len0, "undo takes it away")
	# Another section on the song's progression shares edits to it.
	view.select_entry(1)
	check(view.get_data() == sc.song_data, "the verse edits the song's progression")
	view.set_block_property(1, &"chord_root", MusicData.G)
	check_eq(sc.song_data.blocks[1].chord_root, MusicData.G, "a block edit lands in the song's progression")
	check(sc.verse.get_progression(song) == sc.song_data and sc.intro.get_progression(song) == own, "which the sections on it share, the intro's own copy apart")
	view.set_block_property(1, &"chord_root", MusicData.F)
	# Own off.
	view.select_entry(0)
	var own_before := sc.intro.progression
	_cycle("own off", o, func(): return view.set_own_progression(sc.intro, false))
	check(sc.intro.progression == null, "turning it off goes back to the song's")
	check(view.get_data() == sc.song_data, "the drawer edits the song's again")
	shim.undo()
	view.refresh(true)
	check(sc.intro.progression == own_before, "and undo brings back the very copy (with its edit)")
	check_eq(own_before.blocks[0].chord_root, MusicData.D, "edits included")
	shim.redo()
	view.refresh(true)
	# A section that already has its own, edited through a song-less drawer path.
	view.select_entry(2)
	check(view.get_data() == sc.chorus_data, "the chorus edits its own progression")
	view.set_block_property(2, &"chord_intervals", PackedInt32Array([0, 3, 7, 10]))
	check_eq(sc.chorus_data.blocks[2].chord_intervals, PackedInt32Array([0, 3, 7, 10]), "a chord quality edit lands in it")
	check_eq(sc.song_data.blocks[0].chord_intervals, MusicData.CHORD_MAJ, "not in the song's")
	_close(o)

# ---------------------------------------------------------------------------
# Read-only
# ---------------------------------------------------------------------------

func _test_read_only() -> void:
	section("read-only")
	var sc := U.make_scene(true)
	for c in sc.root.get_children():
		c.owner = sc.root
	var packed := PackedScene.new()
	check_eq(packed.pack(sc.root), OK, "the test scene packs")
	check_eq(ResourceSaver.save(packed, SAVE_SCENE), OK, "and saves under user://")
	var shim := U.UndoShim.new()
	var view := U.TestView.new()
	view.fake_root = null     # the scene is not open in the editor
	view.undo_redo = shim
	view.size = Vector2(1500, 900)
	_tree.root.add_child(view)
	await _tree.process_frame
	view.set_scene(SAVE_SCENE)
	await _tree.process_frame
	await _tree.process_frame
	check(not view.live, "the scene is not live")
	check(view.song != null, "the closed scene's song is still read and drawn")
	check_eq(view.get_strip().chips().size(), 5, "the strip is drawn")
	var panel := view.get_song_panel()
	var ctl := panel.get_controls()
	check(panel.is_read_only(), "the panel is read-only")
	check(ctl["banner"].visible and String(ctl["banner"].text).contains("Read-only"), "and says so")
	for k in ["save", "add_new", "add_existing", "duplicate", "remove", "right", "loop_here", "bake_add"]:
		check(ctl[k].disabled, "%s is disabled" % k)
	check(not ctl["name"].editable, "the name field is read-only")
	check(panel.get_slot_row(0)["mode"].disabled, "slot modes are disabled")
	var n := _describe(view.song)
	check_eq(view.set_entry_repeats(0, 3), false, "an edit is refused")
	view.set_bpm(77.0)
	view.set_beats_per_bar(5)
	check_eq(view.set_loop_entry(2), false, "a loop-point edit is refused")
	check_eq(view.add_section_entry(), false, "adding is refused")
	check_eq(_describe(view.song), n, "the song is unchanged")
	check_eq(shim.steps(), 0, "and there is no undo step")
	view.get_parent().remove_child(view)
	view.free()
	sc.free_all()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_SCENE))

# ---------------------------------------------------------------------------
# Preview against the real player
# ---------------------------------------------------------------------------

func _lane_specs(sc: U.Scene) -> Array:
	var out: Array = []
	for t in [sc.lead, sc.pad, sc.drums]:
		out.append({"name": String(t.name), "type": int(t.track_type), "pattern": t.pattern, "patch": null,
				"channel": t.synth_channel, "base_octave": t.base_octave, "pan": t.pan, "audible": true,
				"active": t.autoplay, "kit": t.kit})
	return out

# The note-ons the real MusicDataPlayer makes over its own rig, for [param frames] frames.
func _real_run(sc: U.Scene, start: Callable, frames: int) -> Array:
	var rig := U.make_rig(_tree.root, sc.song, sc)
	var engine: U.RecEngine = rig["engine"]
	var director: MusicDirector = rig["director"]
	var player: MusicDataPlayer = rig["player"]
	for t in rig["tracks"]:
		t.activate()
	start.call(player)
	U.step([director] + rig["tracks"], frames)
	var ons: Array = engine.ons.duplicate()
	_tree.root.remove_child(rig["root"])
	rig["root"].free()
	return ons

# The same through the editor's SynthPreview.
func _preview_run(sc: U.Scene, entry: int, loop_entry: int, frames: int, start_beat: float = -1.0) -> Array:
	var p := U.make_preview(_tree.root)
	p.play_music_song(sc.song, _lane_specs(sc), entry, start_beat)
	U.freeze(p)
	if loop_entry >= 0:
		p.set_loop_section(loop_entry)
	U.step([p.director] + p.song_tracks, frames)
	var ons: Array = (p.synth as U.RecEngine).ons.duplicate()
	_tree.root.remove_child(p)
	p.free()
	return ons

func _start_loop_chorus(pl: MusicDataPlayer) -> void:
	pl.play_from_section(2)
	pl.set_loop_section(2)

func _start_mid_verse(pl: MusicDataPlayer) -> void:
	pl.play_from_section(1)
	pl.seek(13.0)

func _test_preview_matches_player() -> void:
	section("preview vs player")
	var sc := U.make_scene(true)
	# Play from the chorus through into the verse after it (24 beats).
	var real := _real_run(sc, func(pl: MusicDataPlayer): pl.play_from_section(2), 24 * 8)
	var prev := _preview_run(sc, 2, -1, 24 * 8)
	check(real.size() > 20, "the real player made notes (%d)" % real.size())
	check_eq(prev, real, "play from section: the preview plays the same note-ons (beat, channel, pitch, velocity) as the real player")
	if not real.is_empty():
		check(absf(real[0][0] - 24.0) <= U.FRAME_BEATS + 0.001, "the first note is on the chorus's first beat (a frame later at most): %s" % str(real[0][0]))
		var first_pad := real.filter(func(e): return e[1] == 1)
		check_eq(int(first_pad[0][2]) % 12, MusicData.G, "the chorus's chord is G (its own progression)")
		var later := real.filter(func(e): return e[1] == 1 and e[0] >= 40.0)
		check(not later.is_empty() and int(later[0][2]) % 12 == MusicData.C, "the verse after it resolves against the song's progression (C)")
		var lead := real.filter(func(e): return e[1] == 0)
		check(absf(lead[0][0] - 24.0) <= U.FRAME_BEATS * 2.0 + 0.001, "Lead plays the chorus riff from the section start: %s" % str(lead[0][0]))
		check_eq(lead.slice(0, 2).map(func(e): return e[2]), [67.0, 69.0], "and it is the chorus riff (degrees 4 and 5), not the track's own pattern")
		check(real.filter(func(e): return e[1] == 2 or e[1] == 3).size() > 0, "the drums keep playing through the chorus")
	# Loop section: the chorus again and again.
	var real_loop := _real_run(sc, _start_loop_chorus, 40 * 8)
	var prev_loop := _preview_run(sc, 2, 2, 40 * 8)
	check_eq(prev_loop, real_loop, "loop section: the preview matches the real player")
	var restarts := real_loop.filter(func(e): return e[1] == 0 and e[0] >= 40.0 and e[0] < 41.0)
	check(not restarts.is_empty(), "the loop restarts the Lead's riff at the second pass (beat 40)")
	check(real_loop.filter(func(e): return e[0] >= 64.0).size() > 0, "and keeps looping past the song's own order")
	var in_verse := real_loop.filter(func(e): return e[1] == 0 and e[0] >= 40.0 and absf(fposmod(e[0] - 24.0, 16.0)) < 0.01)
	check(not in_verse.is_empty(), "each pass restarts on the section grid (24 + 16 n)")
	# Start in the middle of a section by timeline beat.
	var real_mid := _real_run(sc, _start_mid_verse, 16 * 8)
	var prev_mid := _preview_run(sc, 1, -1, 16 * 8, 13.0)
	check_eq(prev_mid, real_mid, "play from a timeline beat: the preview matches the real player")
	# From the first entry through a loop of the whole song.
	var real_all := _real_run(sc, func(pl: MusicDataPlayer): pl.play(), 70 * 8)
	var prev_all := _preview_run(sc, 0, -1, 70 * 8)
	check_eq(prev_all, real_all, "play from the top, past the loop point: the preview matches the real player")
	check(real_all.filter(func(e): return e[1] == 0 and e[0] < 8.0).is_empty(), "the intro silences Lead")
	check(not real_all.filter(func(e): return e[1] == 0 and e[0] >= 8.0 and e[0] < 8.5).is_empty(), "and the verse starts it with the chain")
	check(real_all.filter(func(e): return e[1] == 2 or e[1] == 3).filter(func(e): return e[0] < 8.0).size() > 0, "the drums, with no slot in the intro, play their own pattern")
	sc.free_all()

# The view drives the same preview: Play from section, Loop section, the playhead.
func _test_view_preview() -> void:
	section("view preview")
	var o := await _open()
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var p := U.make_preview(_tree.root)
	view.bind_preview(p)
	U.freeze(p)
	view.select_entry(2)
	check(view.play_from_section(), "Play from section starts the song")
	U.freeze(p)
	check(p.is_music_song_on(), "through the real song player")
	check(p.get_music_song() == sc.song, "playing the scene's song")
	check_eq(p.song_player.get_current_entry(), 2, "from the selected entry")
	check_eq(view.get_cursor_beat(), 24.0, "the cursor is at the section start")
	check_eq(p.director.get_total_beats(), 24.0, "and the beat clock")
	check(view.get_song_panel().get_controls()["play"].disabled == false, "the button is available")
	U.step([p.director] + p.song_tracks, 8 * 6)
	check_eq(p.song_player.get_current_entry(), 2, "still in the chorus after six beats")
	var beat := view.get_playhead().beat_of(p.director.get_total_beats())
	check(absf(beat - 30.0) < 0.2, "the playhead is at 30 on the song's timeline (%s)" % str(beat))
	# Loop section on: the chorus loops, the playhead stays inside it.
	view.set_loop_section(true)
	check(view.is_loop_section_on(), "Loop section is on")
	check(p.song_player.get_loop_section() == sc.chorus, "the player loops the chorus")
	U.step([p.director] + p.song_tracks, 8 * 24)     # 6 + 24 = 30 beats: into the second pass
	check_eq(p.song_player.get_current_entry(), 2, "still in the chorus after it would have ended")
	beat = view.get_playhead().beat_of(p.director.get_total_beats())
	check(beat >= 24.0 and beat <= 40.0, "the playhead stays inside the section (%s)" % str(beat))
	view.set_loop_section(false)
	check(p.song_player.get_loop_section() == null, "off, the song goes on in order")
	check(view.get_song_panel().get_controls()["loop"].button_pressed == false, "the toggle shows it")
	# Selecting another entry while looping loops that one.
	view.set_loop_section(true)
	view.select_entry(1)
	check(p.song_player.get_loop_section() == sc.verse, "picking another entry loops that section instead")
	view.set_loop_section(false)
	# Stop puts the cursor back and stops the song.
	view.stop_song()
	check(not p.is_playing(), "Stop stops")
	check(not p.is_music_song_on(), "and the song")
	# Play from the cursor starts the entry the cursor is in.
	view.seek(45.0)
	view.start_song()
	U.freeze(p)
	check_eq(p.song_player.get_current_entry(), 3, "Play starts the entry under the playhead")
	view.stop_song()
	# An edit while playing restarts the song where it was.
	view.select_entry(2)
	view.play_from_section()
	U.freeze(p)
	U.step([p.director] + p.song_tracks, 8 * 4)
	var songplayer := p.song_player
	view.set_slot_mode(sc.chorus, &"Lead", MusicSectionSlot.Mode.SILENT)
	U.freeze(p)
	view._sync_song_playback()
	U.freeze(p)
	check(p.is_music_song_on(), "an edit keeps the song playing")
	view.stop_song()
	# Muting a lane keeps it silent whatever the song says.
	view.select_entry(2)
	view.play_from_section()
	view._set_mute(view._track_path(sc.pad), true)
	U.freeze(p)
	(p.synth as U.RecEngine).ons.clear()
	U.step([p.director] + p.song_tracks, 8 * 12)
	check(not (p.synth as U.RecEngine).ons.is_empty(), "other lanes still play")
	check((p.synth as U.RecEngine).ons.filter(func(e): return e[1] == 1).is_empty(), "a muted lane makes no sound")
	view.stop_song()
	view.bind_preview(null)
	_tree.root.remove_child(p)
	p.free()
	_close(o)

# ---------------------------------------------------------------------------
# Convert to song, Save song as
# ---------------------------------------------------------------------------

func _test_convert() -> void:
	section("convert to song")
	var o := await _open(false)
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var shim: U.UndoShim = o["shim"]
	var btn := view.get_convert_button()
	check(btn.visible, "a plain scene offers Convert to song")
	check(not btn.disabled, "enabled when the player has a MusicData")
	check(view.song == null, "no song yet")
	check(not view.get_strip().get_parent().visible and not view.get_song_panel().visible, "no strip or song panel for a plain scene")
	var bpm := sc.plain_data.bpm
	_cycle("convert", o, func(): btn.pressed.emit(); return true)
	var song := sc.player.song
	check(song != null and view.song == song, "the player has a song")
	check(song.progression == sc.plain_data, "whose progression is the scene's MusicData")
	check_eq(song.bpm, bpm, "and tempo")
	check_eq(song.entries.size(), 1, "with one entry")
	check_eq(song.loop_entry, 0, "looping from it")
	var sec := song.entries[0].section
	check_eq(sec.name, "A", "of a section called A")
	check(sec.progression == null, "that plays the song's progression")
	check_eq(sec.slots.size(), 3, "with a slot per track")
	var want := [[&"Lead", sc.lead_a], [&"Pad", sc.pad_a], [&"Drums", sc.drums_a]]
	for i in sec.slots.size():
		check(sec.slots[i].track == want[i][0] and sec.slots[i].mode == MusicSectionSlot.Mode.PLAY and sec.slots[i].pattern == want[i][1], "slot %d plays %s's pattern" % [i, want[i][0]])
	check(sc.player.music_data == sc.plain_data, "the player keeps its music_data")
	check(not btn.visible, "Convert is gone once it is a song")
	check(view.get_strip().get_parent().visible and view.get_song_panel().visible, "and the song view shows")
	check_eq(view.get_strip().chips().size(), 1, "one chip")
	check_eq(view.timeline.span, 8.0, "spanning the song")
	shim.undo()
	view.refresh(true)
	check(sc.player.song == null and view.song == null, "undo takes the song away")
	check(btn.visible and not view.get_song_panel().visible, "and the plain view returns")
	shim.redo()
	view.refresh(true)
	check(sc.player.song == song, "redo brings the same song back")
	# The converted song plays the same notes as the plain scene's tracks do.
	var conv := U.make_scene(false)
	conv.player.song = song
	var real := _real_run_song(conv, song, func(pl: MusicDataPlayer): pl.play(), 16 * 8)
	var expected := _plain_run(conv, 16 * 8)
	check(real.size() > 0, "the converted song makes notes")
	# The last frame's notes differ by the frame the plain player starts on.
	real = real.filter(func(e): return e[0] < 15.5)
	expected = expected.filter(func(e): return e[0] < 15.5)
	check_eq(real.map(func(e): return [e[1], e[2], e[3]]), expected.map(func(e): return [e[1], e[2], e[3]]), "and they are the notes the plain scene plays (channel, pitch, velocity)")
	var worst := 0.0
	for i in mini(real.size(), expected.size()):
		worst = maxf(worst, absf(real[i][0] - expected[i][0]))
	check(worst <= U.FRAME_BEATS * 2.0 + 0.001, "at the same beats, give or take the frame the plain player starts on (%s)" % str(worst))
	conv.free_all()
	_close(o)

# The notes of a song over [param sc]'s tracks.
func _real_run_song(sc: U.Scene, song: MusicSong, start: Callable, frames: int) -> Array:
	var rig := U.make_rig(_tree.root, song, sc)
	for t in rig["tracks"]:
		t.activate()
	start.call(rig["player"])
	U.step([rig["director"]] + rig["tracks"], frames)
	var ons: Array = (rig["engine"] as U.RecEngine).ons.duplicate()
	_tree.root.remove_child(rig["root"])
	rig["root"].free()
	return ons

# The notes of the scene played the plain way: its music_data, every track active.
func _plain_run(sc: U.Scene, frames: int) -> Array:
	var rig := U.make_rig(_tree.root, null, sc)
	for t in rig["tracks"]:
		t.activate()
	var player: MusicDataPlayer = rig["player"]
	player.music_data = sc.plain_data
	player.play()
	U.step([rig["director"]] + rig["tracks"], frames)
	var ons: Array = (rig["engine"] as U.RecEngine).ons.duplicate()
	_tree.root.remove_child(rig["root"])
	rig["root"].free()
	return ons

func _test_save_song() -> void:
	section("save song as")
	var o := await _open()
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var shim: U.UndoShim = o["shim"]
	var inline := sc.player.song
	var before := _describe(inline)
	check(view.get_song_panel().get_controls()["save"].disabled == false, "Save song as is offered")
	check(String(view.get_song_panel().get_controls()["where"].text).contains("inline"), "an inline song says so")
	var n0 := shim.steps()
	check(view.save_song_to(SAVE_SONG), "the song is saved")
	check_eq(shim.steps() - n0, 1, "as one undo step")
	check(FileAccess.file_exists(SAVE_SONG), "the file exists")
	var saved := sc.player.song
	check(saved != inline, "the player now plays the saved resource")
	check_eq(saved.resource_path, SAVE_SONG, "which is the file")
	check_eq(saved.entries.size(), inline.entries.size(), "with the same entries")
	check_eq(saved.bpm, inline.bpm, "tempo")
	check_eq(saved.loop_entry, 1, "and loop point")
	check_eq(saved.entries.map(func(e): return e.section.name), ["Intro", "Verse", "Chorus", "Verse"], "section names")
	check(saved.entries[1].section == saved.entries[3].section, "a reused section is still one section in the file")
	check_eq(saved.get_length_beats(), inline.get_length_beats(), "and the length")
	check_eq(saved.entries[2].section.slots.size(), 3, "slots survive")
	check(view.song == saved, "the view follows")
	check(String(view.get_song_panel().get_controls()["where"].text).contains("synth_test_song_saved"), "and names the file")
	shim.undo()
	view.refresh(true)
	check(sc.player.song == inline, "undo plays the inline song again")
	check_eq(_describe(inline), before, "which was left as it was")
	shim.redo()
	view.refresh(true)
	check(sc.player.song == saved, "redo plays the file again")
	# The .tres loads on its own and plays.
	var again := ResourceLoader.load(SAVE_SONG, "", ResourceLoader.CACHE_MODE_REPLACE) as MusicSong
	check(again != null and again.get_length_beats() == 48.0, "the file loads as a MusicSong of 48 beats")
	_close(o)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_SONG))
	check(not FileAccess.file_exists(SAVE_SONG), "the test removed its file")

# ---------------------------------------------------------------------------
# A plain scene is as it was
# ---------------------------------------------------------------------------

func _test_plain_scene() -> void:
	section("plain scene")
	var o := await _open(false)
	var view: SynthTrackView = o["view"]
	var sc: U.Scene = o["sc"]
	var pv := U.make_preview(_tree.root)
	view.bind_preview(pv)
	pv.set_music_data(sc.plain_data)
	await _tree.process_frame
	check(view.song == null and view.timeline.song == null, "no song")
	check(view.timeline.segments.is_empty(), "no segments")
	check(not view.get_strip().get_parent().visible, "no strip")
	check(not view.get_song_panel().visible, "no song panel")
	check_eq(view.timeline.span, 16.0, "the span is two trips through the progression")
	check(view.get_data() == sc.plain_data, "the lanes sit over the scene's MusicData")
	check_eq(view.get_progression_lane().chips().size(), 4, "the progression repeats to fill the span")
	check_eq(view.get_progression_lane().chips().filter(func(c): return c["repeat"]).size(), 2, "the second trip is dimmed")
	check_eq(view.get_lanes().size(), 3, "a lane per track")
	for lane in view.get_lanes():
		check(lane.clips.regions.is_empty(), "a lane has no song regions")
	check_eq(view.get_header_controls()["bpm"].value, 120.0, "the BPM field is the MusicData's")
	view.set_bpm(100.0)
	check_eq(sc.plain_data.bpm, 100.0, "and edits it")
	check_eq(o["shim"].steps(), 1, "in one undo step")
	check(view.get_convert_button().visible, "Convert to song is offered")
	check_eq(view.selected_entry, -1, "no entry")
	check(view.selected_section() == null, "no section")
	view.set_scene("")
	await _tree.process_frame
	check(not view.get_convert_button().visible, "no scene, no Convert button")
	view.bind_preview(null)
	_tree.root.remove_child(pv)
	pv.free()
	_close(o)
