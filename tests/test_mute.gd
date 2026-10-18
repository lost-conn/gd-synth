extends "res://addons/godot_synth/tests/test_util.gd"

# MusicTrack.set_muted and MusicDataPlayer.set_tracks_muted: a muted track plays
# nothing but stays in phase, the change lands on the beat asked for, held notes are
# released, the mute outlives song section changes, kit tracks mute every piece and
# the sample bake ignores it. The tracks are stepped by hand over an engine that
# records note-ons (test_util.gd), 120 bpm, 0.125 beat per frame.

const U := preload("res://addons/godot_synth/tests/test_util.gd")

var _tree: SceneTree

func run(tree: SceneTree) -> void:
	_tree = tree
	_test_phase()
	_test_timings()
	_test_pending_changes()
	_test_held_notes_and_bends()
	_test_kit_track()
	_test_survives_calls()
	_test_song_sections()
	_test_song_bars()
	_test_set_tracks_muted()
	_test_bake_ignores_mute()

# ---------------------------------------------------------------------------
# Rigs
# ---------------------------------------------------------------------------

# A plain (no song) music scene: Lead (eighth notes, channel 0), Pad (a held chord
# on beat 0 of 4, channel 1) and Drums (a two-piece kit, channels 2 and 3), over a
# progression of two 6-beat blocks. Started and ready to step.
func _plain(start: bool = true) -> Dictionary:
	var sc := U.make_scene(false)
	var eighths: Array = []
	for i in 8:
		eighths.append([float(i) * 0.5, 0.25, 0])
	sc.lead.pattern = U.pattern(4.0, eighths, MusicPattern.EditorTrackType.MELODY)
	var r := U.make_rig(_tree.root, null, sc)
	r["sc"] = sc
	var player: MusicDataPlayer = r["player"]
	player.music_data = U.progression([MusicData.C, MusicData.F], 6)
	for t in r["tracks"]:
		t.sync_to_director = true   # the patterns follow the director's beats from 0
	if start:
		for t in r["tracks"]:
			t.activate()
		player.play()
	return r

func _free(r: Dictionary) -> void:
	_tree.root.remove_child(r["root"])
	r["root"].free()
	(r["sc"] as U.Scene).free_all()

func _step(r: Dictionary, frames: int) -> void:
	U.step([r["director"]] + r["tracks"], frames)

func _beat(r: Dictionary) -> float:
	return (r["director"] as MusicDirector).get_total_beats()

# The rig's own copies of the scene's tracks (make_rig copies them).
func _lead(r: Dictionary) -> MusicTrack:
	return r["tracks"][0]

func _pad(r: Dictionary) -> MusicTrack:
	return r["tracks"][1]

func _drums(r: Dictionary) -> MusicTrack:
	return r["tracks"][2]

func _ons(r: Dictionary, channel: int) -> Array:
	return (r["engine"] as U.RecEngine).ons.filter(func(e): return e[1] == channel)

func _beats_of(ons: Array) -> Array:
	return ons.map(func(e): return e[0])

func _mute_all(r: Dictionary, muted: bool, at: MusicTrack.MuteTiming = MusicTrack.MuteTiming.NOW) -> void:
	for t in r["tracks"]:
		t.set_muted(muted, at)

# ---------------------------------------------------------------------------
# Phase
# ---------------------------------------------------------------------------

func _test_phase() -> void:
	section("muted tracks stay in phase")
	var ref := _plain()
	_step(ref, 128)                                            # 16 beats, never muted
	var mut := _plain()
	_mute_all(mut, true)
	_step(mut, 8)                                              # beat 1
	check_eq(_beat(mut), 1.0, "the rig is at beat 1")
	_mute_all(mut, false, MusicTrack.MuteTiming.NEXT_BLOCK)    # the block ends on beat 6
	_step(mut, 120)
	for ch in [0, 1, 2, 3]:
		var want: Array = _ons(ref, ch).filter(func(e): return e[0] >= 6.0)
		var got: Array = _ons(mut, ch)
		check(not want.is_empty(), "channel %d: the unmuted run has notes from beat 6 on" % ch)
		check_eq(got, want, "channel %d: unmuting at the next block gives exactly the unmuted run's note-ons from beat 6 on" % ch)
	var lead_ref := _ons(ref, 0)
	var lead_mut := _ons(mut, 0)
	check_eq(lead_mut[0][0], 6.0, "the note on the boundary beat itself plays")
	check(lead_ref.any(func(e): return e[0] < 6.0), "(the unmuted run did play before it)")
	_free(ref)
	_free(mut)

# ---------------------------------------------------------------------------
# NOW / NEXT_BEAT / NEXT_BAR / NEXT_BLOCK
# ---------------------------------------------------------------------------

# Lead playing, muted [param muted] first; at beat 1.25 ask for the opposite at
# [param at]. Returns the note-on beats since that call (run to beat 12).
func _timing_run(muted_first: bool, at: MusicTrack.MuteTiming) -> Array:
	var r := _plain()
	var lead := _lead(r)
	if muted_first:
		lead.set_muted(true)
	_step(r, 10)
	var n0: int = _ons(r, 0).size()
	lead.set_muted(not muted_first, at)
	_step(r, 86)
	var beats := _beats_of(_ons(r, 0).slice(n0))
	_free(r)
	return beats

func _test_timings() -> void:
	section("mute timing")
	var T := MusicTrack.MuteTiming
	# Muting at beat 1.25 (eighth notes, a bar is 4 beats, a block 6): the notes before the
	# change sound, the one on it does not.
	check_eq(_timing_run(false, T.NOW), [], "mute NOW: nothing after the call")
	check_eq(_timing_run(false, T.NEXT_BEAT), [1.5], "mute NEXT_BEAT: only the note before beat 2")
	check_eq(_timing_run(false, T.NEXT_BAR), [1.5, 2.0, 2.5, 3.0, 3.5], "mute NEXT_BAR: notes up to beat 4 (bars of 4 without a song)")
	check_eq(_timing_run(false, T.NEXT_BLOCK), [1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5], "mute NEXT_BLOCK: notes up to beat 6")
	# Unmuting: the first note is the one on the boundary.
	check_eq(_timing_run(true, T.NOW)[0], 1.5, "unmute NOW: the next note")
	check_eq(_timing_run(true, T.NEXT_BEAT)[0], 2.0, "unmute NEXT_BEAT: the note on beat 2")
	check_eq(_timing_run(true, T.NEXT_BAR)[0], 4.0, "unmute NEXT_BAR: the note on beat 4")
	check_eq(_timing_run(true, T.NEXT_BLOCK)[0], 6.0, "unmute NEXT_BLOCK: the note on beat 6")
	# The state getters follow the beat.
	var r := _plain()
	var lead := _lead(r)
	_step(r, 10)
	lead.set_muted(true, T.NEXT_BEAT)
	check(not lead.is_muted(), "a change for a later beat is not in force yet")
	check_eq(lead.get_pending_mute(), {"muted": true, "beat": 2.0}, "it is pending, with its beat")
	_step(r, 5)                                                # beat 1.875
	check(not lead.is_muted(), "still not at beat 1.875")
	_step(r, 1)                                                # beat 2.0
	check(lead.is_muted(), "muted once beat 2 is played")
	check(lead.get_pending_mute().is_empty(), "and nothing is pending")
	_free(r)

# ---------------------------------------------------------------------------
# Replacing, cancelling, no clock
# ---------------------------------------------------------------------------

func _test_pending_changes() -> void:
	section("pending changes")
	var T := MusicTrack.MuteTiming
	var r := _plain()
	var lead := _lead(r)
	_step(r, 10)
	lead.set_muted(true, T.NEXT_BAR)
	lead.set_muted(false, T.NEXT_BEAT)
	check(lead.get_pending_mute().is_empty(), "asking for the state it already has cancels a pending change")
	_step(r, 40)
	check(not lead.is_muted(), "so it stays unmuted")
	lead.set_muted(true, T.NEXT_BAR)
	lead.set_muted(true, T.NEXT_BEAT)
	check_eq(lead.get_pending_mute()["beat"], float(ceili(_beat(r))), "a later call replaces a pending one")
	lead.set_muted(true, T.NOW)
	check(lead.is_muted() and lead.get_pending_mute().is_empty(), "NOW applies at once and drops what was pending")
	_free(r)

	# No running clock: a timed change cannot wait for a beat.
	var idle := _plain(false)
	_lead(idle).set_muted(true, T.NEXT_BLOCK)
	check(_lead(idle).is_muted(), "with the director stopped the change applies at once")
	_free(idle)

# ---------------------------------------------------------------------------
# Held notes and bends
# ---------------------------------------------------------------------------

func _bent_rig() -> Dictionary:
	var sc := U.make_scene(false)
	var bent := U.pattern(4.0, [[0.0, 2.0, 0]], MusicPattern.EditorTrackType.MELODY)
	bent.notes[0].bends.append(PatternBend.create(0.5, 0.25, 3))
	sc.lead.pattern = bent
	var b := U.make_rig(_tree.root, null, sc)
	b["sc"] = sc
	(b["player"] as MusicDataPlayer).music_data = U.progression([MusicData.C], 8)
	for tr in b["tracks"]:
		tr.activate()
	b["player"].play()
	return b

func _test_held_notes_and_bends() -> void:
	section("held notes and bends")
	var T := MusicTrack.MuteTiming
	var r := _plain()
	_step(r, 33)                                               # beat 4.125, the pad chord (3 notes, 3.5 beats) holds
	var engine: U.RecEngine = r["engine"]
	var pad: MusicTrack = _pad(r)
	check_eq(engine.offs.filter(func(e): return e[1] == 1).size(), 0, "nothing of the pad has been released")
	pad.set_muted(true)
	var offs: Array = engine.offs.filter(func(e): return e[1] == 1)
	check_eq(offs.size(), 3, "muting NOW releases the three held notes")
	check(offs.all(func(e): return e[0] == 4.125), "at once")
	check(pad._active_notes.is_empty(), "and the track keeps none")
	_free(r)

	var t := _plain()
	_step(t, 33)
	var pad2: MusicTrack = _pad(t)
	pad2.set_muted(true, T.NEXT_BEAT)
	var e2: U.RecEngine = t["engine"]
	_step(t, 6)                                                # beat 4.875
	check_eq(e2.offs.filter(func(e): return e[1] == 1).size(), 0, "a timed mute holds the notes until its beat")
	_step(t, 1)                                                # beat 5.0
	var offs2: Array = e2.offs.filter(func(e): return e[1] == 1)
	check_eq(offs2.size(), 3, "and releases them on it")
	check(offs2.all(func(e): return e[0] == 5.0), "on beat 5")
	_free(t)

	# Bends belong to the notes: a muted note has none, a note muted while held loses its own.
	var b := _bent_rig()
	_lead(b).set_muted(true)
	_step(b, 2)
	check(_lead(b)._pending_bends.is_empty(), "a muted note schedules no bend")
	_free(b)

	var b2 := _bent_rig()
	_step(b2, 2)
	check_eq(_lead(b2)._pending_bends.size(), 1, "an unmuted note has its bend pending")
	_lead(b2).set_muted(true)
	check(_lead(b2)._pending_bends.is_empty(), "muting drops the bend with the note")
	_free(b2)

# ---------------------------------------------------------------------------
# Kit
# ---------------------------------------------------------------------------

func _test_kit_track() -> void:
	section("kit track")
	var r := _plain()
	var drums: MusicTrack = _drums(r)
	check(drums.uses_kit(), "(the drums are a kit)")
	drums.set_muted(true)
	_step(r, 64)
	check(_ons(r, 2).is_empty() and _ons(r, 3).is_empty(), "no piece of a muted kit plays")
	check(not _ons(r, 0).is_empty(), "the other tracks do")
	drums.set_muted(false)
	_step(r, 16)
	check(not _ons(r, 2).is_empty() and not _ons(r, 3).is_empty(), "unmuted, both pieces play again")
	_free(r)

# ---------------------------------------------------------------------------
# The other calls leave the mute alone
# ---------------------------------------------------------------------------

func _test_survives_calls() -> void:
	section("the mute survives")
	var r := _plain()
	var lead := _lead(r)
	var other := U.pattern(2.0, [[0.0, 0.25, 1], [1.0, 0.25, 2]], MusicPattern.EditorTrackType.MELODY)
	lead.set_muted(true)
	_step(r, 8)
	lead.swap_pattern(other)
	lead.deactivate()
	lead.activate()
	lead.start_pattern_at(other, _beat(r))
	lead.swap_patch(null)
	check(lead.is_muted(), "swap_pattern, deactivate, activate, start_pattern_at do not unmute")
	_step(r, 32)
	check(_ons(r, 0).is_empty(), "and the new pattern is silent")
	lead.set_muted(false)
	_step(r, 16)
	check(not _ons(r, 0).is_empty(), "unmuted it plays the pattern it was given")
	_free(r)

# ---------------------------------------------------------------------------
# A song
# ---------------------------------------------------------------------------

func _song(with_play: bool = true) -> Dictionary:
	var sc := U.make_scene(true)
	var r := U.make_rig(_tree.root, sc.song, sc)
	r["sc"] = sc
	for t in r["tracks"]:
		t.activate()
	if with_play:
		r["player"].play()
	return r

func _test_song_sections() -> void:
	section("mute and song sections")
	# Intro 0-8 (Pad PLAY, Lead SILENT), Verse 8-24 (Lead PLAY chain, Drums PLAY), Chorus
	# 24-40 (Lead PLAY, Pad PLAY, Drums KEEP), in blocks of 4.
	var ref := _song()
	_step(ref, 322)                                            # 40.25 beats
	var mut := _song()
	var lead: MusicTrack = _lead(mut)
	var drums: MusicTrack = _drums(mut)
	lead.set_muted(true)
	drums.set_muted(true)
	_step(mut, 210)                                            # beat 26.25, in the chorus
	check_eq(_beat(mut), 26.25, "the song is at beat 26.25")
	check(lead.is_muted() and drums.is_muted(), "muted through SILENT, PLAY restarts and a KEEP")
	check(_ons(mut, 0).is_empty() and _ons(mut, 2).is_empty() and _ons(mut, 3).is_empty(), "so far no note of the lead or the drums")
	var p: MusicDataPlayer = mut["player"]
	p.set_tracks_muted([&"Lead", &"Drums"], false, MusicTrack.MuteTiming.NEXT_BLOCK)
	check_eq(lead.get_pending_mute()["beat"], 28.0, "the next block of the chorus starts on beat 28")
	_step(mut, 112)                                            # beat 40.25
	for ch in [0, 2, 3]:
		var want: Array = _ons(ref, ch).filter(func(e): return e[0] >= 28.0)
		var got: Array = _ons(mut, ch)
		check(not want.is_empty(), "channel %d: the unmuted song plays after beat 28" % ch)
		check_eq(got, want, "channel %d: from beat 28 on exactly the unmuted song's note-ons" % ch)
	check_eq(_ons(mut, 1), _ons(ref, 1), "the pad, never muted, is unaffected")
	check(not lead.is_muted() and not drums.is_muted(), "unmuted")
	_free(ref)
	_free(mut)

func _test_song_bars() -> void:
	section("NEXT_BAR in a song")
	var T := MusicTrack.MuteTiming
	var r := _song(false)
	var sc: U.Scene = r["sc"]
	sc.song.beats_per_bar = 3
	r["player"].play()
	_step(r, 74)                                               # beat 9.25, in the verse that starts on 8
	check_eq(_beat(r), 9.25, "at beat 9.25")
	var pad: MusicTrack = _pad(r)
	r["player"].set_tracks_muted([&"Pad"], true, T.NEXT_BAR)
	check_eq(pad.get_pending_mute()["beat"], 11.0, "bars of 3 count from the section's start (8): the next is 11")
	_step(r, 40)                                               # beat 14.25
	r["player"].set_tracks_muted([&"Pad"], false, T.NEXT_BAR)
	check_eq(pad.get_pending_mute()["beat"], 16.0, "the bar after 14 would be 17, but the section ends on 16")
	_free(r)

# ---------------------------------------------------------------------------
# set_tracks_muted
# ---------------------------------------------------------------------------

func _test_set_tracks_muted() -> void:
	section("set_tracks_muted")
	var r := _plain()
	var player: MusicDataPlayer = r["player"]
	var child := MusicTrack.new()
	child.name = "Child"
	child.autoplay = false
	child.director = r["director"]
	child.synth = r["engine"]
	player.add_child(child)
	var found := player.set_tracks_muted([&"Lead", "Child", &"Nope"], true)
	check_eq(found, 2, "two of the three names are found (a node under the player, a track wired to the director)")
	check(_lead(r).is_muted() and child.is_muted(), "and muted")
	check(not _pad(r).is_muted(), "the others are not")
	check_eq(player.set_tracks_muted([&"Lead"], false, MusicTrack.MuteTiming.NEXT_BEAT), 1, "timed")
	check(_lead(r).is_muted() and not _lead(r).get_pending_mute().is_empty(), "it waits for its beat")
	_free(r)

# ---------------------------------------------------------------------------
# The bake
# ---------------------------------------------------------------------------

func _usage_of(sc: U.Scene) -> Dictionary:
	var collected := SynthBaker.collect_song(sc.root)
	var usages: Dictionary = {}
	SynthSampleBaker.add_song_usage_routed(collected["song"], collected["tracks"], 0.0, func(patch):
		if not usages.has(patch):
			usages[patch] = SynthSampleBaker.Usage.new()
		return usages[patch])
	var out: Dictionary = {}
	for patch in usages:
		out[patch.resource_name] = (usages[patch] as SynthSampleBaker.Usage).notes.duplicate(true)
	return out

func _test_bake_ignores_mute() -> void:
	section("bake")
	var sc := U.make_scene(true)
	var lead_patch := SynthPatch.new()
	lead_patch.resource_name = "lead"
	var pad_patch := SynthPatch.new()
	pad_patch.resource_name = "pad"
	sc.lead.patch = lead_patch
	sc.pad.patch = pad_patch
	for piece in sc.drums.kit.pieces:
		piece.patch = SynthPatch.new()
		piece.patch.resource_name = "drum_" + piece.name
	var before := _usage_of(sc)
	check(before.size() >= 4, "the song uses the lead, pad and both drum patches (%d usages)" % before.size())
	check(before.values().all(func(n): return not n.is_empty()), "each has notes")
	for t in [sc.lead, sc.pad, sc.drums]:
		t.set_muted(true)
	var after := _usage_of(sc)
	check_eq(after, before, "muting every track changes nothing the bake collects")
	sc.free_all()
