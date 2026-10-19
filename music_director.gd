@tool
class_name MusicDirector
extends Node

# Beat clock and block progression manager. Drives MusicTrack nodes by
# advancing a monotonic beat counter and cycling through MusicBlocks in the
# active MusicData. Exposes helpers so any game code (SFX, etc.) can query
# the current harmonic context.
#
# IMPORTANT: This node must appear BEFORE any MusicTrack siblings in the
# scene tree so that _process updates beat state before tracks read it.

signal beat_tick(beat_number: int)
signal block_changed(block: MusicBlock, index: int)
signal seeked
## The beat set with [method set_boundary] was reached (emitted from
## [method _process], before this frame's beat tick and block change, and before
## any MusicTrack reads the clock this frame). [MusicDataPlayer] switches song
## sections here; a handler may call [method set_data_at] and set the next
## boundary.
signal boundary_reached(beat: float)

## When a transition takes effect — used by [method swap_data], by
## MusicDataPlayer.swap_mode, and by MusicTrack.swap_mode.
##   IMMEDIATE   — apply right now
##   NEXT_BEAT   — defer to the next integer beat boundary
##   NEXT_BLOCK  — defer to the next block boundary in the progression
enum SwapMode { IMMEDIATE, NEXT_BEAT, NEXT_BLOCK }

## The progression to play. Holds BPM and the list of MusicBlocks that
## cycle in order. May be null until [method swap_data] or [method play]
## is called with data assigned.
@export var data: MusicData

## Shuffle/swing feel. 0 = straight 8ths. Higher values delay every
## offbeat 8th note (0.5, 1.5, 2.5, ...) — 0.33 ≈ triplet swing.
@export_range(0.0, 1.0) var swing_amount: float = 0.0

## Start playback when the node enters the tree (deferred one frame so
## MusicTrack siblings can connect to signals first).
@export var autoplay: bool = false

## When > 0, the beat clock runs at this tempo instead of [member data]'s bpm.
## [MusicDataPlayer] sets it to [member MusicSong.bpm] while it plays a song (so
## a section's own MusicData bpm is ignored) and clears it when it stops. Read
## the tempo through [method get_bpm].
var bpm_override: float = 0.0

var playing: bool = false
var current_block_index: int = 0

var _beat_in_block: float = 0.0
var _total_beats: float = 0.0
var _last_beat_int: int = -1
var _pending_data: MusicData = null
var _pending_mode: int = -1
# The beat [member data]'s first block starts on: block positions are derived
# from (total beats - origin). 0 except while a song plays (each section's
# progression starts on the section's first beat).
var _data_origin: float = 0.0
# See set_boundary(). INF: none.
var _boundary_beat: float = INF
# MusicTracks wired to this director (see register_track()).
var _tracks: Array = []

## Longest frame the beat clock advances by, in seconds. A longer frame is the
## main thread having stalled (a level loading, a shader compiling) or the page
## having been hidden: the clock waits it out instead of jumping ahead, which
## would fire every note of the gap at once when it is over. SynthSampler's own
## clock is capped at the same length.
const MAX_FRAME := 0.25

# ---------------------------------------------------------------------------
# Playback control
# ---------------------------------------------------------------------------

## Editor-only opt-in. This script is @tool so the Synth editor tab can run a
## preview director inside the editor; a MusicDirector sitting in a scene that
## is merely open in the editor must stay inert (no autoplay, no _process).
## Only a node with this set to true BEFORE it enters the tree (the tab's
## preview director) ticks while Engine.is_editor_hint(). Ignored in a running
## game. Not exported, so it is never saved into a scene.
var editor_preview: bool = false

func _ready() -> void:
	if Engine.is_editor_hint() and not editor_preview:
		set_process(false)
		return
	if autoplay and data != null and not data.blocks.is_empty():
		call_deferred("play")

func play() -> void:
	play_at(0.0)

## Start playback with the beat clock at [param start_beat]. [member data]'s
## first block starts on [param origin_beat] (default: [param start_beat]), so
## the block playing is the one at (start_beat - origin_beat) into the
## progression. Clears any boundary ([method set_boundary]). [method play] is
## play_at(0).
func play_at(start_beat: float, origin_beat: float = NAN) -> void:
	if data == null or data.blocks.is_empty():
		push_warning("[MusicDirector] No data or empty blocks.")
		return
	_total_beats = start_beat
	_last_beat_int = int(floorf(start_beat)) - 1
	_data_origin = start_beat if is_nan(origin_beat) else origin_beat
	_boundary_beat = INF
	_beat_in_block = 0.0
	current_block_index = 0
	_derive_block_position()
	playing = true
	block_changed.emit(data.blocks[current_block_index], current_block_index)

func stop() -> void:
	playing = false

## Replace the progression without touching the beat clock: [param new_data]'s
## first block starts on [param origin_beat], and the block playing is worked
## out from there (a progression that starts now plays its first block). Drops a
## pending [method swap_data]. Emits [signal block_changed] when the new data
## has blocks. [MusicDataPlayer] uses it at song section boundaries; sounding
## notes of tracks that follow the harmony are released, as on any block change.
func set_data_at(new_data: MusicData, origin_beat: float) -> void:
	data = new_data
	_data_origin = origin_beat
	_pending_data = null
	_pending_mode = -1
	current_block_index = 0
	_beat_in_block = 0.0
	if data == null or data.blocks.is_empty():
		return
	_derive_block_position()
	block_changed.emit(data.blocks[current_block_index], current_block_index)

## Emit [signal boundary_reached] once, on the first frame the beat clock is at
## or past [param beat] (exactly: no tolerance, so the beats that frame are
## always >= [param beat]). One boundary at a time; setting another replaces it.
func set_boundary(beat: float) -> void:
	_boundary_beat = beat

func clear_boundary() -> void:
	_boundary_beat = INF

## The pending boundary beat, or INF.
func get_boundary() -> float:
	return _boundary_beat

## The beat [member data]'s first block started on (0 unless a song is playing).
func get_data_origin() -> float:
	return _data_origin

## The tempo the clock runs at: [member bpm_override] when set, else
## [member data]'s bpm (0 with no data).
func get_bpm() -> float:
	if bpm_override > 0.0:
		return bpm_override
	return data.bpm if data != null else 0.0

## MusicTracks wire themselves here (see [method MusicTrack.bind]), so a
## [MusicDataPlayer] can find tracks that are not its children by name.
func register_track(track: Node) -> void:
	if track != null and not _tracks.has(track):
		_tracks.append(track)

func unregister_track(track: Node) -> void:
	_tracks.erase(track)

## The MusicTracks wired to this director that still exist.
func get_tracks() -> Array:
	_tracks = _tracks.filter(func(t): return is_instance_valid(t))
	return _tracks.duplicate()

func swap_data(new_data: MusicData, mode: SwapMode = SwapMode.IMMEDIATE) -> void:
	if mode == SwapMode.IMMEDIATE:
		_apply_swap(new_data)
	else:
		_pending_data = new_data
		_pending_mode = mode

## Jump the beat clock to [param new_total_beats]. Re-derives the block
## index + beat-in-block from the progression. Emits [signal seeked] so
## tracks can release their sustaining notes, then [signal block_changed]
## if the block actually changed.
func seek(new_total_beats: float) -> void:
	_total_beats = new_total_beats
	_last_beat_int = int(floorf(new_total_beats)) - 1
	if data == null or data.blocks.is_empty():
		seeked.emit()
		return
	var old_index: int = current_block_index
	if not _derive_block_position():
		seeked.emit()
		return
	seeked.emit()
	if current_block_index != old_index:
		block_changed.emit(data.blocks[current_block_index], current_block_index)

# Set current_block_index + _beat_in_block from (_total_beats - _data_origin)
# into the progression. False (nothing changed) when it has no length.
func _derive_block_position() -> bool:
	var total_len: float = 0.0
	for block in data.blocks:
		total_len += float(block.duration_beats)
	if total_len <= 0.0:
		return false
	var prog_beat: float = fposmod(_total_beats - _data_origin, total_len)
	var acc: float = 0.0
	var new_index: int = 0
	var new_in_block: float = prog_beat
	for i in data.blocks.size():
		var blen: float = float(data.blocks[i].duration_beats)
		if prog_beat < acc + blen:
			new_index = i
			new_in_block = prog_beat - acc
			break
		acc += blen
	_beat_in_block = new_in_block
	current_block_index = new_index
	return true

# ---------------------------------------------------------------------------
# Query API — usable by SFX, game code, anything that needs current harmony
# ---------------------------------------------------------------------------

func get_current_block() -> MusicBlock:
	if data == null or data.blocks.is_empty():
		return null
	return data.blocks[current_block_index]

func get_beat_in_block() -> float:
	return _beat_in_block

func get_total_beats() -> float:
	return _total_beats

func get_chord_tone(index: int, octave: int) -> int:
	var block := get_current_block()
	if block == null:
		return 60
	var intervals := block.chord_intervals
	var size: int = intervals.size()
	if size == 0:
		return 60
	var idx: int = posmod(index, size)
	var extra_oct: int = int(floorf(float(index) / float(size)))
	return 12 * (octave + 1 + extra_oct) + block.chord_root + intervals[idx]

func get_scale_note(degree: int, octave: int, accidental: float = 0.0) -> float:
	var block := get_current_block()
	if block == null:
		return 60.0
	var intervals := block.scale_intervals
	var size: int = intervals.size()
	if size == 0:
		return 60.0
	var idx: int = posmod(degree, size)
	var extra_oct: int = int(floorf(float(degree) / float(size)))
	return float(12 * (octave + 1 + extra_oct) + block.scale_root + intervals[idx]) + accidental

## Apply swing to a beat position. Offbeat 8th notes (0.5, 1.5, 2.5, ...)
## are shifted forward by up to half an 8th note's duration.
func get_swung_beat(beat: float) -> float:
	if swing_amount <= 0.0:
		return beat
	var eighth: float = beat * 2.0
	var eighth_int: int = int(floorf(eighth))
	if eighth_int % 2 == 1:
		return beat + swing_amount * 0.25
	return beat

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not playing or data == null or data.blocks.is_empty():
		return
	var beats_per_sec: float = get_bpm() / 60.0
	var delta_beats: float = minf(delta, MAX_FRAME) * beats_per_sec
	_beat_in_block += delta_beats
	_total_beats += delta_beats

	# Song section boundary (a handler swaps data and sets the next boundary;
	# a long frame may cross several).
	var crossed: int = 0
	while playing and _total_beats >= _boundary_beat and crossed < 256:
		var b: float = _boundary_beat
		_boundary_beat = INF
		crossed += 1
		boundary_reached.emit(b)
	if not playing or data == null or data.blocks.is_empty():
		return

	# Beat tick
	var current_beat_int: int = int(floorf(_total_beats))
	if current_beat_int > _last_beat_int:
		_last_beat_int = current_beat_int
		beat_tick.emit(current_beat_int)
		if _pending_data != null and _pending_mode == SwapMode.NEXT_BEAT:
			_apply_swap(_pending_data)
			return

	# Block boundary
	var block: MusicBlock = data.blocks[current_block_index]
	var dur: float = float(block.duration_beats)
	if _beat_in_block >= dur:
		_beat_in_block -= dur
		current_block_index = (current_block_index + 1) % data.blocks.size()
		var new_block: MusicBlock = data.blocks[current_block_index]
		block_changed.emit(new_block, current_block_index)
		if _pending_data != null and _pending_mode == SwapMode.NEXT_BLOCK:
			_apply_swap(_pending_data)

func _apply_swap(new_data: MusicData) -> void:
	data = new_data
	_data_origin = 0.0
	current_block_index = 0
	_beat_in_block = 0.0
	_pending_data = null
	_pending_mode = -1
	if data != null and not data.blocks.is_empty():
		block_changed.emit(data.blocks[0], 0)
