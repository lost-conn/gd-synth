class_name MusicDataPlayer
extends Node

# Thin wrapper that pushes a MusicData resource into the global
# MusicDirector (at /root/Music). Useful as a scene-authored source of
# music data per level / area.
#
# This node does NOT manage MusicTracks — tracks are independent and
# wire themselves to the global synth + director directly. Drop a
# MusicDataPlayer in a level scene to set that level's progression /
# bpm, and drop MusicTracks anywhere (they can live as children of this
# node for organization, or elsewhere in the scene tree).
#
# SONGS. With [member song] set, the player plays a [MusicSong] instead of
# [member music_data]: its sections in order, each with its own progression and
# its own instructions for the tracks. Then it does drive MusicTracks, by name:
# its own descendants first, then any other track wired to the director
# ([method MusicDirector.get_tracks]). The tracks stay the instruments; the song
# says what they play when.
#
#   - The director keeps one beat clock. While a song plays from the top, the
#     director's beat is the song's timeline beat; after the song loops it keeps
#     counting up. At each section boundary (exact: section starts are sums of
#     section lengths, never accumulated frame time) the player swaps the
#     director's progression to the new section's ([method MusicDirector.set_data_at]),
#     so a note on the section's first beat already resolves against its first
#     block. Notes due before the boundary inside the same frame are played first,
#     against the old harmony ([method MusicTrack.flush_to]).
#   - Tempo is the song's [member MusicSong.bpm] ([member MusicDirector.bpm_override]).
#   - Slots ([MusicSectionSlot]): PLAY restarts the track on the pattern at the
#     section's first beat (a chain starts at step 1, even if the same pattern
#     played before), SILENT deactivates it (sounding notes are released), KEEP —
#     and any track the section does not list — carries on untouched.
#   - Each repeat of a song entry is a fresh start of its section; a section's own
#     repeats are not (they are just a longer section).
#   - After the last entry the song continues at [member MusicSong.loop_entry].
#   - Starting or jumping (play, [method play_from_section], [method seek])
#     works out what every track would be playing there on a first pass through
#     the song (its last PLAY / SILENT before that point, else its own pattern
#     from the song's beat 0 if it was active when the song first started), and
#     starts it in phase. Tracks driven this way start on the beat exactly,
#     whatever their swap_mode / sync_to_director.
#   - Game control: [method set_loop_section] repeats one section until released;
#     [method queue_section] plays any section (also one only listed in
#     [member MusicSong.also_bake]) once at the next section / bar / block / beat,
#     then the song continues with the entry after the one it interrupted.
#
# A scene with only [member music_data] behaves exactly as it always did.

## Emitted when a song section starts: on every boundary (also for each repeat of
## an entry and each pass of a looped section) and on play / play_from_section /
## seek. [param entry_index] is the song entry, or -1 for a section played
## through [method queue_section] or [method set_loop_section] that no entry plays.
signal section_changed(section: MusicSection, entry_index: int)

## Emitted when the song passes its last entry and continues at
## [member MusicSong.loop_entry] (just before that section's
## [signal section_changed]).
signal song_looped

## When a [method queue_section] takes over.
##   NEXT_SECTION — when the current section ends
##   NEXT_BAR     — at the next bar line ([member MusicSong.beats_per_bar], counted
##                  from the current section's start)
##   NEXT_BLOCK   — at the next chord change of the current progression
##   NEXT_BEAT    — on the next whole beat
## A point at or past the current section's end is its end.
enum QueueMode { NEXT_SECTION, NEXT_BAR, NEXT_BLOCK, NEXT_BEAT }

## The MusicData to push into the director (progression + bpm).
@export var music_data: MusicData

## A song to play instead of [member music_data] (see the comment at the top of
## this script). Null: [member music_data] plays, exactly as before songs existed.
@export var song: MusicSong

## Push and start playback when this node enters the tree.
@export var autoplay: bool = false

## Hot-swap mode used when [method play] is called while the director
## is already playing. IMMEDIATE snaps to the new progression;
## NEXT_BEAT / NEXT_BLOCK defer the swap to a musical boundary.
## Not used by a song, which always starts at once.
@export var swap_mode: MusicDirector.SwapMode = MusicDirector.SwapMode.NEXT_BLOCK

## Runtime reference to the global director. Auto-wired from /root/Music
## in [method _ready]; override via [method bind] if your project uses a
## different autoload name.
var director: MusicDirector

# --- Song state --------------------------------------------------------------

var _song_active: bool = false
var _section: MusicSection = null
var _entry: int = -1          # the song entry playing, -1: a section no entry plays
var _repeat: int = 0          # which repeat of that entry
var _resume_entry: int = 0    # where the song goes on after a non-entry section
var _section_start: float = 0.0
var _section_len: float = 0.0
var _loop_section: MusicSection = null
var _loop_entry_index: int = -1
var _queued: MusicSection = null
var _queue_at: float = INF
var _seeking: bool = false
# MusicTrack -> {pattern, active}: what each track was before the song first
# touched it (its "own" pattern, for PLAY slots without one and unlisted tracks).
var _own: Dictionary = {}

func _ready() -> void:
	if director == null:
		director = get_node_or_null("/root/Music") as MusicDirector
	if autoplay:
		play()

func _exit_tree() -> void:
	if _song_active:
		_end_song()

## Explicit director assignment for projects that don't use the default
## `/root/Music` autoload name.
func bind(p_director: MusicDirector) -> void:
	if _song_active:
		_end_song()
	director = p_director

## Push [member music_data] to the director. Hot-swaps if already playing;
## starts fresh playback if not. With a [member song], starts the song from its
## first entry (at once, whatever the director was playing).
func play() -> void:
	if song != null:
		var first: int = 0
		while first < song.entries.size() - 1 and song.entry_length(first) <= 0.0:
			first += 1
		play_from_section(first)
		return
	if director == null or music_data == null:
		push_warning("[MusicDataPlayer] director or music_data missing.")
		return
	if director.playing:
		director.swap_data(music_data, swap_mode)
	else:
		director.data = music_data
		director.play()

## Stop the global director (affects all MusicTracks). A song's tracks get back
## the pattern and the active state they had before the song first played.
func stop() -> void:
	if _song_active:
		_end_song(true)
	if director:
		director.stop()

## Swap to a new MusicData using this node's [member swap_mode]. Plain
## [member music_data] mode only: while a song plays this ends the song's control
## of the director and plays [param new_data] as plain music.
func swap(new_data: MusicData) -> void:
	if director == null:
		return
	if _song_active:
		_end_song(true)
	music_data = new_data
	if director.playing:
		director.swap_data(new_data, swap_mode)
	else:
		director.data = new_data

func is_playing() -> bool:
	return director != null and director.playing

# ---------------------------------------------------------------------------
# Song control
# ---------------------------------------------------------------------------

## Start the song at an entry: an index into [member MusicSong.entries], or a
## section name (the first entry that plays it; a section only in
## [member MusicSong.also_bake] plays as a non-entry section, followed by the
## first entry). The director's beat is set to where the entry starts on the
## song's timeline, and every track is started as a first pass through the song
## would have it there.
func play_from_section(which: Variant) -> void:
	if not _can_play_song():
		return
	var target := _resolve(which)
	if target.is_empty():
		push_warning("[MusicDataPlayer] No song section %s." % str(which))
		return
	var entry: int = target["entry"]
	var start: float = song.entry_start(entry) if entry >= 0 else 0.0
	_resume_entry = 0
	_jump(target["section"], entry, 0, start, start)

## Jump to beat [param beat] of the song's timeline (a beat past one pass folds
## into the loop region) and keep playing from there: the section, progression
## block and every track are set as a first pass through the song has them. Also
## what happens when someone calls [method MusicDirector.seek] while a song plays.
## Without a song, seeks the director.
func seek(beat: float) -> void:
	if song == null or not _song_active:
		if director != null:
			director.seek(beat)
		return
	var at := song.entry_at_beat(beat)
	if at.is_empty():
		return
	_jump(at["section"], at["entry"], at["repeat"], at["section_start"], beat)

## Loop one section: an entry index, a section name or a MusicSection. From the
## next section boundary the section plays again and again (each pass restarts
## its PLAY slots). -1 (or null) releases it: the song goes on in order from the
## next boundary, with the entry after the looped one (or, for a section no
## entry plays, the entry after the last one that played). Meant for writing a
## section in the editor (play_from_section(i) then set_loop_section(i)) and for
## game states that hold the music somewhere.
func set_loop_section(which: Variant) -> void:
	if which == null or (typeof(which) == TYPE_INT and int(which) < 0):
		_loop_section = null
		_loop_entry_index = -1
		return
	var target := _resolve(which)
	if target.is_empty():
		push_warning("[MusicDataPlayer] No song section %s." % str(which))
		return
	_loop_section = target["section"]
	_loop_entry_index = target["entry"]

## The section [method set_loop_section] holds, or null.
func get_loop_section() -> MusicSection:
	return _loop_section

## Play [param which] (a MusicSection, a section name — the entries' first,
## then [member MusicSong.also_bake] — or an entry index's section) once, taking over at [param mode]. It
## starts like any section (progression swapped, PLAY slots restarted), plays its
## full length, and then the song continues with the entry after the one that
## was playing when it took over (that entry's remaining repeats are dropped). A
## set loop section ([method set_loop_section]) still wins after it. A second
## call before it takes over replaces it. While the song is not playing it takes
## over at the first boundary.
func queue_section(which: Variant, mode: QueueMode = QueueMode.NEXT_SECTION) -> void:
	if song == null:
		push_warning("[MusicDataPlayer] queue_section needs a song.")
		return
	var target := _resolve(which)
	if target.is_empty():
		push_warning("[MusicDataPlayer] No song section %s to queue." % str(which))
		return
	_queued = target["section"]
	_queue_at = INF
	if _song_active and director != null and director.playing:
		_queue_at = _queue_time(mode, director.get_total_beats())
		_set_next_boundary()

## The queued section that has not started yet, or null.
func get_queued_section() -> MusicSection:
	return _queued

## The song section playing, or null.
func get_current_section() -> MusicSection:
	return _section if _song_active else null

## The song entry playing, or -1 (none, or a queued / looped section no entry plays).
func get_current_entry() -> int:
	return _entry if _song_active else -1

## Which repeat of the current entry is playing (from 0).
func get_current_repeat() -> int:
	return _repeat

## The director beat the current section started on.
func get_section_start_beat() -> float:
	return _section_start

## The current section's length in beats.
func get_section_length() -> float:
	return _section_len

## True while this player's song drives the director.
func is_song_playing() -> bool:
	return _song_active and director != null and director.playing

# ---------------------------------------------------------------------------
# Song internals
# ---------------------------------------------------------------------------

func _can_play_song() -> bool:
	if director == null or song == null:
		push_warning("[MusicDataPlayer] director or song missing.")
		return false
	if song.get_length_beats() <= 0.0:
		push_warning("[MusicDataPlayer] The song has no sections with a progression.")
		return false
	return true

# which -> {section, entry} (entry -1: no entry plays it), or {}.
func _resolve(which: Variant) -> Dictionary:
	if song == null:
		return {}
	var section: MusicSection = null
	var entry: int = -1
	if typeof(which) == TYPE_INT:
		var i: int = which
		if i < 0 or i >= song.entries.size() or song.entries[i] == null:
			return {}
		entry = i
		section = song.entries[i].section
	elif which is MusicSection:
		section = which
		entry = song.entry_of(section)
	else:
		section = song.section_by_name(str(which))
		entry = song.entry_of(section)
	if section == null or song.section_length(section) <= 0.0:
		return {}
	return {"section": section, "entry": entry}

func _begin_song() -> void:
	if not director.boundary_reached.is_connected(_on_boundary):
		director.boundary_reached.connect(_on_boundary)
	if not director.seeked.is_connected(_on_director_seeked):
		director.seeked.connect(_on_director_seeked)
	_song_active = true
	for t in _all_tracks():
		_remember(t)

func _end_song(restore: bool = false) -> void:
	_song_active = false
	_queued = null
	_queue_at = INF
	if restore:
		for t in _own_tracks():
			var own: Dictionary = _own[t]
			t.deactivate()
			t.pattern = own["pattern"]
			if own["active"]:
				t.activate()
		_own.clear()
	if director == null or not is_instance_valid(director):
		return
	director.clear_boundary()
	director.bpm_override = 0.0
	if director.boundary_reached.is_connected(_on_boundary):
		director.boundary_reached.disconnect(_on_boundary)
	if director.seeked.is_connected(_on_director_seeked):
		director.seeked.disconnect(_on_director_seeked)

# Start [param section] (entry / repeat) whose first beat is [param section_start],
# with the clock at [param now], every track set as a first pass has it.
func _jump(section: MusicSection, entry: int, repeat: int, section_start: float, now: float) -> void:
	_begin_song()
	_queued = null
	_queue_at = INF
	_set_current(section, entry, repeat, section_start)
	var prog := section.get_progression(song)
	director.bpm_override = song.bpm
	if director.playing:
		# Seek first (tracks release and resync at the new beat), then the
		# section's progression from its start.
		_seeking = true
		director.seek(now)
		_seeking = false
		director.set_data_at(prog, section_start)
	else:
		director.data = prog
		director.play_at(now, section_start)
	_apply_track_states(_states_at(entry, repeat, section, section_start), now)
	_set_next_boundary()
	section_changed.emit(section, entry)

func _set_current(section: MusicSection, entry: int, repeat: int, section_start: float) -> void:
	_section = section
	_entry = entry
	_repeat = repeat
	_section_start = section_start
	_section_len = song.section_length(section)

func _set_next_boundary() -> void:
	if not _song_active or director == null:
		return
	director.set_boundary(minf(_section_start + _section_len, _queue_at))

func _on_boundary(b: float) -> void:
	if not _song_active or song == null:
		return
	# The last notes of the old section, against the old harmony.
	for t in _flush_tracks():
		t.flush_to(b)
	var looped: bool = false
	var section: MusicSection = null
	var entry: int = -1
	var repeat: int = 0
	if _queued != null:
		_resume_entry = (_entry + 1) if _entry >= 0 else _resume_entry
		section = _queued
		_queued = null
		_queue_at = INF
	elif _loop_section != null:
		section = _loop_section
		entry = _loop_entry_index
		if entry < 0 and _entry >= 0:
			_resume_entry = _entry + 1
	else:
		if _entry >= 0 and _repeat + 1 < song.entries[_entry].repeats:
			entry = _entry
			repeat = _repeat + 1
		else:
			entry = (_entry + 1) if _entry >= 0 else _resume_entry
		# Skip entries without length; wrap to the loop entry past the end.
		var tries: int = 0
		while true:
			if entry >= song.entries.size():
				entry = song.get_loop_entry()
				repeat = 0
				looped = true
			if song.entry_length(entry) > 0.0:
				break
			entry += 1
			repeat = 0
			tries += 1
			if tries > song.entries.size() + 1:
				push_warning("[MusicDataPlayer] The song has no section with a length; stopping.")
				stop()
				return
		section = song.entries[entry].section
	_enter(section, entry, repeat, b)
	if looped:
		song_looped.emit()
	section_changed.emit(section, entry)

# A section boundary: the new section's progression and its slots; tracks it
# does not list keep going.
func _enter(section: MusicSection, entry: int, repeat: int, b: float) -> void:
	_set_current(section, entry, repeat, b)
	director.set_data_at(section.get_progression(song), b)
	for slot in section.slots:
		if slot == null or slot.mode == MusicSectionSlot.Mode.KEEP:
			continue
		var t: MusicTrack = _find_track(slot.track)
		if t == null:
			continue
		if slot.mode == MusicSectionSlot.Mode.PLAY:
			t.start_pattern_at(slot.pattern if slot.pattern != null else _own_pattern(t), b, b)
		else:
			t.deactivate()
	_set_next_boundary()

func _queue_time(mode: QueueMode, now: float) -> float:
	var end: float = _section_start + _section_len
	var at: float = INF
	match mode:
		QueueMode.NEXT_BEAT:
			at = floorf(now) + 1.0
		QueueMode.NEXT_BAR:
			var bpb: float = float(maxi(1, song.beats_per_bar))
			at = _section_start + (floorf((now - _section_start) / bpb) + 1.0) * bpb
		QueueMode.NEXT_BLOCK:
			var prog := _section.get_progression(song) if _section != null else null
			var plen: float = MusicSection.progression_beats(prog)
			if plen > 0.0:
				var cycle: float = _section_start + floorf((now - _section_start) / plen) * plen
				at = cycle + plen
				var t: float = cycle
				for blk in prog.blocks:
					t += float(blk.duration_beats)
					if t > now:
						at = t
						break
		_:
			at = INF
	return INF if at >= end else at

# What each track does at (entry, repeat) on a first pass through the song,
# or at a non-entry [param section] started on [param section_start]:
# track name -> {play: bool, pattern, origin}. Tracks it does not mention are
# in their own state (see _apply_track_states).
func _states_at(entry: int, repeat: int, section: MusicSection, section_start: float) -> Dictionary:
	var states: Dictionary = {}
	if entry >= 0:
		var shift: float = section_start - (song.entry_start(entry) + float(repeat) * song.section_length(section))
		for i in entry + 1:
			var e: MusicSongEntry = song.entries[i]
			if e == null or e.section == null or song.entry_length(i) <= 0.0:
				continue
			var reps: int = e.repeats if i < entry else repeat + 1
			var origin: float = song.entry_start(i) + float(reps - 1) * song.section_length(e.section) + shift
			_apply_slots_to_states(states, e.section, origin)
	else:
		_apply_slots_to_states(states, section, section_start)
	return states

func _apply_slots_to_states(states: Dictionary, section: MusicSection, origin: float) -> void:
	for slot in section.slots:
		if slot == null:
			continue
		match slot.mode:
			MusicSectionSlot.Mode.PLAY:
				states[slot.track] = {"play": true, "pattern": slot.pattern, "origin": origin}
			MusicSectionSlot.Mode.SILENT:
				states[slot.track] = {"play": false}

func _apply_track_states(states: Dictionary, now: float) -> void:
	var done: Dictionary = {}
	for track_name in states:
		var t: MusicTrack = _find_track(track_name)
		if t == null:
			continue
		done[t] = true
		var st: Dictionary = states[track_name]
		if st["play"]:
			var p: MusicPattern = st["pattern"]
			t.start_pattern_at(p if p != null else _own_pattern(t), st["origin"], now)
		else:
			t.deactivate()
	# Tracks no section so far mentions: their own pattern, playing since the
	# director's beat 0, if they were active when the song took them. (A track on
	# its own clock, an SFX, is left alone.)
	for t in _own_tracks():
		if done.has(t) or t.bpm_override > 0.0:
			continue
		if bool(_own[t]["active"]):
			t.start_pattern_at(_own[t]["pattern"], 0.0, now)
		else:
			t.deactivate()

func _on_director_seeked() -> void:
	if _seeking or not _song_active or director == null or not director.playing:
		return
	seek(director.get_total_beats())

# --- Tracks ------------------------------------------------------------------

func _remember(t: MusicTrack) -> void:
	if not _own.has(t):
		_own[t] = {"pattern": t.pattern, "active": t.is_active()}

func _own_pattern(t: MusicTrack) -> MusicPattern:
	_remember(t)
	return _own[t]["pattern"]

# The player's descendant tracks plus the director's tracks any section names.
func _all_tracks() -> Array:
	var out: Array = []
	_collect_tracks(self, out)
	if director != null and song != null:
		var named: Dictionary = {}
		for s in song.get_reachable_sections():
			for slot in s.slots:
				if slot != null:
					named[slot.track] = true
		for t in director.get_tracks():
			if t is MusicTrack and named.has(t.name) and not out.has(t):
				out.append(t)
	return out

# Tracks whose own state the song manages (everything _remember()ed that exists).
func _own_tracks() -> Array:
	var out: Array = []
	for t in _own.keys():
		if is_instance_valid(t):
			out.append(t)
		else:
			_own.erase(t)
	return out

func _collect_tracks(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c is MusicTrack:
			out.append(c)
		_collect_tracks(c, out)

func _find_track(track_name: StringName) -> MusicTrack:
	var own: Array = []
	_collect_tracks(self, own)
	for t in own:
		if t.name == track_name:
			_remember(t)
			return t
	if director != null:
		for t in director.get_tracks():
			if t is MusicTrack and t.name == track_name:
				_remember(t)
				return t
	return null

# Every track that follows the director's clock and harmony.
func _flush_tracks() -> Array:
	var out: Array = _own_tracks()
	if director != null:
		for t in director.get_tracks():
			if t is MusicTrack and not out.has(t):
				out.append(t)
	return out
