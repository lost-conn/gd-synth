class_name SynthBaker
extends RefCounted

# Whole-track baking. Flattens a MusicData progression + a set of MusicTracks
# into a flat SynthEngine event timeline, then renders it offline to a single
# seamless looping AudioStreamWAV. Playing that WAV back costs ~zero CPU versus
# running the live synth voice-by-voice — the intended low-end-hardware path.
#
# Note resolution here mirrors MusicTrack/MusicDirector exactly (chord/scale
# degrees, octave stacking, swing, pitch bends, block progression) so a bake
# reproduces what the live system would have played. It does NOT capture Godot
# per-channel bus effects (e.g. a track's AudioEffectPhaser) — those are audio-
# server DSP applied downstream and aren't available offline. Route the baked
# player through the same bus at playback if you need bus-level effects.
#
# Bakes default to DEFAULT_MIX_RATE and to SynthEngine.OfflineGain.LIMIT_PEAK —
# the mix is never hard-clipped; a bake that would exceed the ceiling is scaled
# down instead, and last_stats says by how much. Pass OfflineGain.CLIP (and
# 22050.0) to reproduce a bake from before gain staging existed.
#
# Typical use (editor or headless):
#   var song := SynthBaker.collect_song(main_music_node)   # {data, song, tracks, swing}
#   var wav := SynthBaker.bake_song(song.data, song.tracks, song.swing)
#   ResourceSaver.save(wav, "res://resources/audio/baked/bgm/main.wav")
#
# A scene whose MusicDataPlayer plays a MusicSong (song != null) is rendered with
# bake_music_song() instead: intro + one pass of the loop region, looping back to
# the loop entry.

const _TICKS := 480  # subdivisions per beat for exact loop-length LCM

## Bake sample rate (Hz) unless a caller asks otherwise. Independent of the live
## engine's mix_rate: a bake costs nothing to play back, so it can afford the
## rate at which bright / FM patches stop aliasing audibly.
const DEFAULT_MIX_RATE := 44100.0

## [member SynthEngine.last_offline_stats] of the most recent bake (pre-clip
## peak, clipped-sample count, gain applied). Empty if the bake produced nothing.
static var last_stats: Dictionary = {}

## One track's contribution. `track_type` uses MusicTrack.TrackType values.
## Build these by hand or via [method collect_song].
class TrackInfo:
	var pattern: MusicPattern
	var patch: SynthPatch
	## A drum kit (DRUM tracks only; null for a track that plays [member patch]).
	## Piece i plays on channel (channel + i): each row of the pattern goes to the
	## piece that owns it, at the piece's pitch and with its gain and pan, and the
	## piece's patch takes the place of [member patch].
	var kit: SynthKit
	var track_type: int = MusicTrack.TrackType.MELODY
	var channel: int = 0
	var base_octave: int = 4
	var pan: float = 0.0
	## The MusicTrack's node name: what a [MusicSectionSlot] names it by.
	var name: StringName = &""

	## A copy of this info, playing [param p_pattern].
	func with_pattern(p_pattern: MusicPattern) -> TrackInfo:
		var c := TrackInfo.new()
		c.pattern = p_pattern
		c.patch = patch
		c.kit = kit
		c.track_type = track_type
		c.channel = channel
		c.base_octave = base_octave
		c.pan = pan
		c.name = name
		return c

# ---------------------------------------------------------------------------
# Scene collection
# ---------------------------------------------------------------------------

## Walk [param root] (e.g. an instanced main_music scene) for a
## MusicDataPlayer's MusicData (and MusicSong) and every MusicTrack child,
## returning {data: MusicData, song: MusicSong, tracks: Array[TrackInfo], swing:
## float}. song is null unless the player has one, and then it is what plays
## (data is still the player's music_data, usually null). Reads exported
## properties directly — no _ready / tree membership required.
static func collect_song(root: Node, swing: float = 0.0) -> Dictionary:
	var data: MusicData = null
	var song: MusicSong = null
	var found_player: bool = false
	var tracks: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MusicDataPlayer and not found_player and (data == null):
			found_player = (n as MusicDataPlayer).music_data != null or (n as MusicDataPlayer).song != null
			data = (n as MusicDataPlayer).music_data
			song = (n as MusicDataPlayer).song
		elif n is MusicTrack:
			var t := n as MusicTrack
			var info := TrackInfo.new()
			info.pattern = t.pattern
			info.patch = t.patch
			info.kit = t.kit if t.uses_kit() else null
			info.track_type = int(t.track_type)
			info.channel = t.synth_channel
			info.base_octave = t.base_octave
			info.pan = t.pan
			info.name = t.name
			tracks.append(info)
		for c in n.get_children():
			stack.push_back(c)
	return {"data": data, "song": song, "tracks": tracks, "swing": swing}

# ---------------------------------------------------------------------------
# Baking
# ---------------------------------------------------------------------------

## Flatten + render a whole song to a seamless looping AudioStreamWAV.
## [param gain_mode] is a [enum SynthEngine.OfflineGain].
static func bake_song(data: MusicData, tracks: Array, swing: float = 0.0,
		mix_rate: float = DEFAULT_MIX_RATE, wrap_seconds: float = 1.0,
		seed: int = 1234, gain_mode: int = SynthEngine.OfflineGain.LIMIT_PEAK) -> AudioStreamWAV:
	last_stats = {}
	if data == null or data.blocks.is_empty():
		push_warning("[SynthBaker] No MusicData / empty progression.")
		return null

	var loop_beats := _loop_beats(data, tracks)
	var bpm: float = data.bpm if data.bpm > 0.0 else 120.0
	var spb: float = 60.0 / bpm  # seconds per beat
	var loop_seconds: float = loop_beats * spb

	var events: Array = []
	var patches: Array = []
	patches.resize(16)
	for info in tracks:
		if info == null or info.pattern == null or info.pattern.get_play_length() <= 0.0:
			continue
		if info.kit != null and info.track_type == MusicTrack.TrackType.DRUM:
			for i in info.kit.pieces.size():
				var ch: int = info.channel + i
				if ch >= 0 and ch < 16 and info.kit.pieces[i] != null:
					patches[ch] = info.kit.pieces[i].patch
		elif info.channel >= 0 and info.channel < 16:
			patches[info.channel] = info.patch
		_flatten_track(events, info, data, loop_beats, swing, spb, bpm)

	var synth := SynthEngine.new()
	synth.offline_gain_mode = gain_mode
	var wav := synth.render_loop_offline(events, patches, loop_seconds, wrap_seconds, mix_rate, seed)
	last_stats = synth.last_offline_stats
	synth.free()
	return wav

## Render a [MusicSong] the way [MusicDataPlayer] plays it from the top: every
## entry once in order (each section over its own progression, at the song's
## bpm, with PLAY restarting a track's pattern on the section's first beat,
## SILENT stopping it and KEEP / unlisted tracks carrying on), as one looping
## AudioStreamWAV that plays the intro once and then loops from
## [member MusicSong.loop_entry] to the end ([member AudioStreamWAV.loop_begin]).
## The loop region is rendered as the first pass plays it, so a KEEP track whose
## pattern is at another point at the end than at the loop entry jumps there.
## [param tracks] are [TrackInfo]s with names (see [method collect_song]); a
## track's own pattern plays until a section says otherwise. A note that is
## still sounding when its track is restarted or silenced is cut there, as live.
## Queued / [member MusicSong.also_bake] sections are not rendered.
static func bake_music_song(song: MusicSong, tracks: Array, swing: float = 0.0,
		mix_rate: float = DEFAULT_MIX_RATE, wrap_seconds: float = 1.0,
		seed: int = 1234, gain_mode: int = SynthEngine.OfflineGain.LIMIT_PEAK) -> AudioStreamWAV:
	last_stats = {}
	if song == null or song.get_length_beats() <= 0.0:
		push_warning("[SynthBaker] No MusicSong / the song has no length.")
		return null
	var bpm: float = song.bpm if song.bpm > 0.0 else 120.0
	var spb: float = 60.0 / bpm
	var events: Array = song_events(song, tracks, swing, spb)
	var patches: Array = []
	patches.resize(16)
	for info in tracks:
		if info == null:
			continue
		if info.kit != null and info.track_type == MusicTrack.TrackType.DRUM:
			for i in info.kit.pieces.size():
				var ch: int = info.channel + i
				if ch >= 0 and ch < 16 and info.kit.pieces[i] != null:
					patches[ch] = info.kit.pieces[i].patch
		elif info.channel >= 0 and info.channel < 16:
			patches[info.channel] = info.patch
	var synth := SynthEngine.new()
	synth.offline_gain_mode = gain_mode
	var wav := synth.render_intro_loop_offline(events, patches, song.get_length_beats() * spb,
			song.get_loop_start_beats() * spb, wrap_seconds, mix_rate, seed)
	last_stats = synth.last_offline_stats
	synth.free()
	return wav

## The events [method bake_music_song] renders: one pass through [param song]'s
## entries, in seconds at [param spb] seconds per beat.
static func song_events(song: MusicSong, tracks: Array, swing: float, spb: float) -> Array:
	# The section instances of one pass: [section, start beat, length].
	var instances: Array = []
	for i in song.entries.size():
		var e: MusicSongEntry = song.entries[i]
		var slen: float = song.entry_length(i) / float(maxi(1, e.repeats)) if e != null else 0.0
		if slen <= 0.0:
			continue
		var start: float = song.entry_start(i)
		for r in e.repeats:
			instances.append([e.section, start + float(r) * slen, slen])
	var loop_index: int = 0
	var loop_start: float = song.get_loop_start_beats()
	for k in instances.size():
		if instances[k][1] >= loop_start - 1e-6:
			loop_index = k
			break
	var events: Array = []
	for info in tracks:
		if info == null:
			continue
		var cur: MusicPattern = info.pattern
		var origin: float = 0.0
		var on: bool = true
		for k in instances.size():
			var section: MusicSection = instances[k][0]
			var start: float = instances[k][1]
			var end: float = start + float(instances[k][2])
			var slot: MusicSectionSlot = section.get_slot(info.name)
			if slot != null and slot.mode == MusicSectionSlot.Mode.PLAY:
				cur = slot.pattern if slot.pattern != null else info.pattern
				origin = start
				on = true
			elif slot != null and slot.mode == MusicSectionSlot.Mode.SILENT:
				on = false
			if not on or cur == null or cur.get_play_length() <= 0.0:
				continue
			# Sounding notes are cut where the next section (or, at the end, the
			# loop entry) restarts or silences the track.
			var next_k: int = k + 1 if k + 1 < instances.size() else loop_index
			var next_slot: MusicSectionSlot = (instances[next_k][0] as MusicSection).get_slot(info.name)
			var cut: float = end if next_slot != null and next_slot.mode != MusicSectionSlot.Mode.KEEP else INF
			var span: Array = []
			_flatten_span(span, info.with_pattern(cur), section.get_progression(song), origin, start, end, swing, spb)
			if cut < INF:
				for ev in span:
					if int(ev[1]) == SynthEngine.CMD_NOTE_OFF and float(ev[0]) > cut * spb:
						ev[0] = cut * spb
			events.append_array(span)
	return events

# Emit one track's notes that fire in [start, end), its pattern looping from
# [param origin], resolved against [param data] whose first block starts on
# [param start] (the section's progression).
static func _flatten_span(events: Array, info: TrackInfo, data: MusicData, origin: float,
		start: float, end: float, swing: float, spb: float) -> void:
	var length: float = info.pattern.get_play_length()
	var kit: SynthKit = info.kit if info.track_type == MusicTrack.TrackType.DRUM else null
	var first_rep: int = int(floorf((start - origin) / length)) - 1
	var last_rep: int = int(ceilf((end - origin) / length))
	for rep in range(first_rep, last_rep + 1):
		var base_beat: float = origin + float(rep) * length
		for note in info.pattern.get_play_notes():
			var fire_beat: float = base_beat + fposmod(_swung(note.beat, swing), length)
			if fire_beat < start - 1e-6 or fire_beat >= end - 1e-6:
				continue
			var block := _block_at(data, fire_beat - start)
			if kit != null:
				_flatten_kit_note(events, info, kit, note, block, fire_beat, spb)
				continue
			var midi: float = _resolve(info.track_type, block, info.base_octave,
				note.index, note.octave, note.accidental)
			var handle: int = roundi(midi)
			events.append([fire_beat * spb, SynthEngine.CMD_NOTE_ON,
				info.channel, midi, note.velocity, info.pan])
			events.append([(fire_beat + note.duration) * spb, SynthEngine.CMD_NOTE_OFF,
				info.channel, handle])
			if not note.bends.is_empty():
				_flatten_bends(events, info, block, handle, note.bends, fire_beat, 0.0, spb)

## Bake a single pattern+patch to a one-shot (or looping) AudioStreamWAV — the
## SFX bake path. CHORD/MELODY pitches resolve against [param block] (pass a
## fixed block, e.g. the song's tonic, since a baked SFX can't track live
## harmony); DRUM ignores it. One-shots run until the last note-off plus an
## envelope tail; set [param loop] for sustained SFX (rendered over one pattern
## length with a seamless wrap). [param gain_mode] is a
## [enum SynthEngine.OfflineGain].
static func bake_pattern(pattern: MusicPattern, patch: SynthPatch, track_type: int,
		base_octave: int, block: MusicBlock, bpm: float, mix_rate: float = DEFAULT_MIX_RATE,
		loop: bool = false, seed: int = 1234,
		gain_mode: int = SynthEngine.OfflineGain.LIMIT_PEAK) -> AudioStreamWAV:
	last_stats = {}
	if pattern == null or pattern.get_play_notes().is_empty() or pattern.get_play_length() <= 0.0:
		return null
	var spb: float = 60.0 / maxf(bpm, 1.0)

	var info := TrackInfo.new()
	info.track_type = track_type
	info.base_octave = base_octave
	info.channel = 0

	var events: Array = []
	var last_off: float = 0.0
	for note in pattern.get_play_notes():
		var midi: float = _resolve(track_type, block, base_octave, note.index, note.octave, note.accidental)
		var handle: int = roundi(midi)
		events.append([note.beat * spb, SynthEngine.CMD_NOTE_ON, 0, midi, note.velocity, 0.0])
		events.append([(note.beat + note.duration) * spb, SynthEngine.CMD_NOTE_OFF, 0, handle])
		last_off = maxf(last_off, note.beat + note.duration)
		if not note.bends.is_empty():
			_flatten_bends(events, info, block, handle, note.bends, note.beat, 0.0, spb)

	var synth := SynthEngine.new()
	synth.offline_gain_mode = gain_mode
	var wav: AudioStreamWAV
	if loop:
		wav = synth.render_loop_offline(events, [patch], pattern.get_play_length() * spb, 1.0, mix_rate, seed)
	else:
		# Tail = envelope ring-out after the final note-off (patches are sustain=0,
		# so release dominates; noise_decay covers cymbal-like tails).
		var tail: float = clampf(patch.release + maxf(patch.decay, patch.noise_decay) + 0.15, 0.2, 3.0)
		wav = synth.render_offline(events, [patch], last_off * spb + tail, mix_rate, false, seed)
	last_stats = synth.last_offline_stats
	synth.free()
	return wav

# Emit note-on/off (+ bend) events for one track across the whole loop.
static func _flatten_track(events: Array, info: TrackInfo, data: MusicData,
		loop_beats: float, swing: float, spb: float, bpm: float) -> void:
	var length: float = info.pattern.get_play_length()
	var reps: int = int(round(loop_beats / length))
	var kit: SynthKit = info.kit if info.track_type == MusicTrack.TrackType.DRUM else null
	for rep in reps:
		var base_beat: float = rep * length
		for note in info.pattern.get_play_notes():
			var local: float = fposmod(_swung(note.beat, swing), length)
			var fire_beat: float = base_beat + local
			if fire_beat >= loop_beats - 1e-6:
				continue  # belongs to the next loop iteration
			var block := _block_at(data, fire_beat)
			if kit != null:
				_flatten_kit_note(events, info, kit, note, block, fire_beat, spb)
				continue
			var midi: float = _resolve(info.track_type, block, info.base_octave,
				note.index, note.octave, note.accidental)
			var handle: int = roundi(midi)
			events.append([fire_beat * spb, SynthEngine.CMD_NOTE_ON,
				info.channel, midi, note.velocity, info.pan])
			events.append([(fire_beat + note.duration) * spb, SynthEngine.CMD_NOTE_OFF,
				info.channel, handle])
			if not note.bends.is_empty():
				_flatten_bends(events, info, block, handle, note.bends, fire_beat, 0.0, spb)

# One DRUM note of a kit track: the row picks the piece; a row no piece owns (or
# one whose channel does not exist) is dropped, as MusicTrack drops it live.
static func _flatten_kit_note(events: Array, info: TrackInfo, kit: SynthKit, note: PatternNote,
		block: MusicBlock, fire_beat: float, spb: float) -> void:
	var i: int = kit.piece_for_note(note.index)
	if i < 0:
		return
	var ch: int = info.channel + i
	if ch < 0 or ch >= 16:
		return
	var piece: SynthKitPiece = kit.pieces[i]
	var pitch: int = piece.get_pitch()
	events.append([fire_beat * spb, SynthEngine.CMD_NOTE_ON, ch, float(pitch),
		piece.scale_velocity(note.velocity), piece.combined_pan(info.pan)])
	events.append([(fire_beat + note.duration) * spb, SynthEngine.CMD_NOTE_OFF, ch, pitch])
	if not note.bends.is_empty():
		_flatten_bends(events, info, block, pitch, note.bends, fire_beat, 0.0, spb, ch, float(pitch - piece.note))

# [param channel] -1: the track's own. [param pitch_shift] moves a bend's target
# (a kit piece played at another pitch than its row).
static func _flatten_bends(events: Array, info: TrackInfo, block: MusicBlock,
		handle: int, bends: Array, parent_start: float, parent_offset: float, spb: float,
		channel: int = -1, pitch_shift: float = 0.0) -> void:
	var ch: int = channel if channel >= 0 else info.channel
	for b in bends:
		var fire: float = parent_start + parent_offset + b.offset_beats
		var target_midi: float = _resolve(info.track_type, block, info.base_octave,
			b.index, b.octave, b.accidental) + pitch_shift
		var target_freq: float = 440.0 * pow(2.0, (target_midi - 69.0) / 12.0)
		events.append([fire * spb, SynthEngine.CMD_BEND, ch, handle,
			target_freq, b.glide_beats * spb])
		if not b.bends.is_empty():
			_flatten_bends(events, info, block, handle, b.bends, parent_start,
				parent_offset + b.offset_beats, spb, channel, pitch_shift)

# ---------------------------------------------------------------------------
# Resolution helpers (mirror MusicTrack / MusicDirector)
# ---------------------------------------------------------------------------

static func _swung(beat: float, swing: float) -> float:
	if swing <= 0.0:
		return beat
	var eighth: float = beat * 2.0
	if int(floorf(eighth)) % 2 == 1:
		return beat + swing * 0.25
	return beat

# The MusicBlock active at absolute progression beat [param b].
static func _block_at(data: MusicData, b: float) -> MusicBlock:
	var total: float = 0.0
	for blk in data.blocks:
		total += float(blk.duration_beats)
	if total <= 0.0:
		return data.blocks[0]
	var pb: float = fposmod(b, total)
	var acc: float = 0.0
	for blk in data.blocks:
		if pb < acc + float(blk.duration_beats):
			return blk
		acc += float(blk.duration_beats)
	return data.blocks[data.blocks.size() - 1]

static func _resolve(track_type: int, block: MusicBlock, base_octave: int,
		index: int, octave: int, accidental: float) -> float:
	if track_type == MusicTrack.TrackType.DRUM:
		return float(index)
	var intervals: PackedInt32Array
	var root: int
	if track_type == MusicTrack.TrackType.CHORD:
		intervals = block.chord_intervals
		root = block.chord_root
	else:  # MELODY
		intervals = block.scale_intervals
		root = block.scale_root
	var size: int = intervals.size()
	if size == 0:
		return 60.0
	var idx: int = posmod(index, size)
	var extra_oct: int = int(floorf(float(index) / float(size)))
	return float(12 * (base_octave + 1 + octave + extra_oct) + root + intervals[idx]) + accidental

# Seamless loop length = LCM of the progression length and every pattern length,
# computed in integer ticks so fractional beats (e.g. 0.5) are exact.
static func _loop_beats(data: MusicData, tracks: Array) -> float:
	var prog: float = 0.0
	for blk in data.blocks:
		prog += float(blk.duration_beats)
	var acc: int = int(round(prog * _TICKS)) if prog > 0.0 else _TICKS
	for info in tracks:
		if info == null or info.pattern == null or info.pattern.get_play_length() <= 0.0:
			continue
		var t: int = int(round(info.pattern.get_play_length() * _TICKS))
		if t > 0:
			acc = _lcm(acc, t)
	return float(acc) / float(_TICKS)

static func _gcd(a: int, b: int) -> int:
	while b != 0:
		var t: int = b
		b = a % b
		a = t
	return a

static func _lcm(a: int, b: int) -> int:
	if a == 0 or b == 0:
		return 0
	return a / _gcd(a, b) * b
