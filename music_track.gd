@tool
class_name MusicTrack
extends Node

# Independent instrument track. Self-wires to the global SynthEngine
# (/root/Synth) and MusicDirector (/root/Music) on entering the tree;
# owns its own activation lifecycle via activate() / deactivate().
#
# A track has up to two things it contributes to its synth channel:
#   - patch  (timbre — applies to the channel on activate / swap_patch)
#   - pattern (melody — plays note events through the channel)
# Either or both may be null. A patch-only track swaps the channel's
# timbre without playing anything; a pattern-only track uses whatever
# patch is already on the channel. Both together = a traditional track.
#
# Track types (how each PatternNote's `index` field is interpreted):
#   CHORD  — chord tone index (0 = root, 1 = third, ...)
#   MELODY — 0-based scale degree (accidental adds ± semitones)
#   DRUM   — absolute MIDI note number (no transposition)
#
# A DRUM track may play a [SynthKit] ([member kit]) instead of one patch: each
# row of the pattern is routed to the kit piece that owns that row, and piece i
# plays on channel synth_channel + i with its own patch, pitch, gain and pan.
#
# Mute: set_muted() silences a track at runtime while it keeps its place (see there).
#
# SFX overrides:
#   bpm_override > 0         — use own local clock at that BPM (ignore director)
#   key_override != null     — resolve pitches against this block (ignore director)

enum TrackType { CHORD, MELODY, DRUM }

## When a [method set_muted] change takes effect, on the director's beat clock
## (the track's own clock with [member bpm_override]).
##   NOW        — at once
##   NEXT_BEAT  — on the next whole beat
##   NEXT_BAR   — at the next bar line: [member MusicSong.beats_per_bar] counted
##                from the song section's start while a [MusicDataPlayer] song
##                drives this track, else every 4 beats from beat 0
##   NEXT_BLOCK — at the next chord change of the director's progression (with
##                [member bpm_override] there is no progression: at once)
## A beat that is already the current one counts as the next.
enum MuteTiming { NOW, NEXT_BEAT, NEXT_BAR, NEXT_BLOCK }

@export var track_type: TrackType = TrackType.CHORD

## The looping pattern this track plays. May be null (patch-only track).
@export var pattern: MusicPattern

## Synth patch (timbre) applied to the target channel on [method activate]
## and [method swap_patch]. May be null — track then uses whatever patch
## already occupies the channel.
@export var patch: SynthPatch

## A drum kit: one patch per drum, played from this track's single DRUM
## pattern. Used only when [member track_type] is DRUM and the kit has pieces;
## then [member patch] is ignored and piece i of the kit plays on channel
## [member synth_channel] + i, so the kit occupies synth_channel ..
## synth_channel + pieces - 1 (a warning says so if that runs past channel 15;
## the pieces beyond it are silent). A pattern row that no piece owns is
## silent. Every piece channel gets this track's [member output_bus] and
## [member effects]; a note's pan is [member pan] plus the piece's.
@export var kit: SynthKit

## SynthEngine channel (0..15) this track targets. Multiple tracks may
## share a channel — they cooperate on patch/pattern but the last one to
## activate wins the effect chain. A track with a [member kit] starts its
## channels here.
@export_range(0, 15) var synth_channel: int = 0

## Octave offset for CHORD/MELODY tracks. Ignored for DRUM.
@export var base_octave: int = 4

@export_group("Playback")

## Activate the track automatically when it enters the tree. Disable for
## tracks you want to trigger via [method activate] in code.
@export var autoplay: bool = true

## When activations and pattern swaps take effect. See
## [enum MusicDirector.SwapMode]. Used by [method activate] and (by
## default) [method swap_pattern].
@export var swap_mode: MusicDirector.SwapMode = MusicDirector.SwapMode.NEXT_BEAT

## Where in the pattern to start playing.
## [br]• [code]false[/code] (default) — start from pattern beat 0
## [br]• [code]true[/code]  — align pattern beat 0 to director beat 0
##   (mid-song activation picks up at the director's current cursor
##   position; a track always plays "in sync" with director's clock)
@export var sync_to_director: bool = false

## Stereo pan applied to every note this track fires (-1 = full left,
## 0 = center, +1 = full right).
@export_range(-1.0, 1.0) var pan: float = 0.0

## Multiplier applied to every note's velocity when triggered. Useful
## for transient SFX attenuation (e.g. distance-based volume) without
## rewriting the pattern. Caller sets before play_once / activate.
var velocity_scale: float = 1.0

@export_group("Bus Routing")

## Send target for this channel's auto-bus (see [SynthEngine.ensure_channel_bus]).
## Default [&"Master"] sends direct to master. Use a shared bus to group
## multiple channels through a submix (e.g. compressor on "Drums").
@export var output_bus: StringName = &"Master"

## Effects installed on this channel's auto-bus, in order. Installed by
## reference — editing an AudioEffect resource at runtime affects live
## audio. Last activated track on a channel owns the effect chain.
@export var effects: Array[AudioEffect] = []

@export_group("Overrides (SFX)")

## When > 0, track uses its own local clock at this BPM instead of the
## director's beat counter. The track plays independent of director
## play/stop and of [method MusicDirector.seek]. Safe to change at
## runtime — the setter rescales the local clock so the pattern cursor
## stays continuous (no note stampede on tempo changes).
@export var bpm_override: float = 0.0:
	set(value):
		var prev_effective: float = _effective_beats()
		bpm_override = maxf(0.0, value)
		if bpm_override > 0.0 and prev_effective > 0.0:
			_local_time = prev_effective * 60.0 / bpm_override
		elif bpm_override <= 0.0:
			_local_time = 0.0

## When set, pitches resolve against this block instead of the director's
## current block. Track is unaffected by [signal MusicDirector.block_changed].
@export var key_override: MusicBlock

# --- Runtime refs (auto-wired in _ready) ------------------------------------

var director: MusicDirector
var synth: SynthEngine

# --- Internal state ---------------------------------------------------------

var _active: bool = false
# True once we've actually started rendering frames. Distinct from _active:
# a non-override track stays inactive (but _active=true) while the director
# is stopped; _was_playing flips when playback actually begins.
var _was_playing: bool = false
# Effective-beat at which playback should start. Determined by swap_mode
# (IMMEDIATE = current effective, NEXT_BEAT = ceil, NEXT_BLOCK = next block
# boundary). While effective < _start_at_beat, the track is "pending" and
# doesn't trigger notes (note-offs still process).
var _start_at_beat: float = 0.0
# Offset in "effective beats" subtracted from current effective beat to
# yield the pattern's cursor. With sync_to_director=false this equals
# _start_at_beat (cursor begins at 0 when playback starts). With
# sync_to_director=true this equals 0.0 (cursor follows director's
# absolute beats — the pattern stays aligned to director beat 0).
var _activated_at_beat: float = 0.0
# Wall-clock seconds since the current activation, only used when
# bpm_override > 0.
var _local_time: float = 0.0
var _prev_cursor: float = -0.001
# The effective beat the pattern was last scanned up to (see flush_to()).
var _scanned_to: float = -INF
# Each entry: {"midi": int, "channel": int, "off_time": float} (off_time in
# effective beats)
var _active_notes: Array = []
# Each entry: {"midi": int, "channel": int, "fire_beat": float, "target_freq":
# float, "glide_beats": float}. Bends pulled from triggered notes' bend chains;
# fire when effective >= fire_beat, then dispatched to SynthEngine.bend_to.
# Cancelled on note-off, _release_all, and block changes.
var _pending_bends: Array = []
# Counter for play_once() to invalidate stale deferred deactivates when
# the same track is re-triggered rapidly.
var _play_once_token: int = 0
# See set_muted(). A muted track advances like any other (cursor, chain steps,
# song restarts) and just plays no notes; nothing else in this script resets it.
var _muted: bool = false
# A change that takes effect on _mute_pending_beat (effective beats): notes due at
# or after that beat get _mute_pending_value, earlier ones still the current state.
var _mute_pending: bool = false
var _mute_pending_value: bool = false
var _mute_pending_beat: float = INF
# The MusicDataPlayer whose song drives this track (set by it), for NEXT_BAR.
var _song_player: Node = null
# Tolerance, in beats, when comparing a note's beat with a mute change's: block
# and section starts are sums of floats and can differ in the last digits.
const MUTE_EPS := 0.0005

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

## Editor-only opt-in. This script is @tool so the Synth editor tab can run a
## preview track inside the editor; a MusicTrack sitting in a scene that is
## merely open in the editor must stay inert (no autoload lookup, no autoplay,
## no _process). Only a node with this set to true BEFORE it enters the tree
## (the tab's preview track) wires itself while Engine.is_editor_hint(). Ignored
## in a running game. Not exported, so it is never saved into a scene.
var editor_preview: bool = false

func _ready() -> void:
	if Engine.is_editor_hint() and not editor_preview:
		set_process(false)
		return
	if director == null:
		director = get_node_or_null("/root/Music") as MusicDirector
	if synth == null:
		synth = get_node_or_null("/root/Synth") as SynthEngine
	_wire_signals()
	if autoplay:
		activate()

## Explicit ref assignment for projects that don't use the default
## `/root/Music` + `/root/Synth` autoload names.
func bind(p_director: MusicDirector, p_synth: SynthEngine) -> void:
	director = p_director
	synth = p_synth
	_wire_signals()

func _wire_signals() -> void:
	if director == null:
		return
	if not director.block_changed.is_connected(_on_block_changed):
		director.block_changed.connect(_on_block_changed)
	if not director.seeked.is_connected(_on_seeked):
		director.seeked.connect(_on_seeked)
	if director.has_method("register_track"):
		director.register_track(self)

func _exit_tree() -> void:
	if director != null and is_instance_valid(director) and director.has_method("unregister_track"):
		director.unregister_track(self)

## Apply this track's patch (if any), install its bus + effects, and
## begin pattern playback (if any). Activation timing follows
## [member swap_mode]; cursor starting position follows
## [member sync_to_director].
func activate() -> void:
	if synth == null:
		return
	apply_patches()
	_configure_bus()
	_active = true
	# Force _process to re-initialize cursor + activation offset on the
	# next frame where playback can actually run.
	_was_playing = false

## Stop pattern playback, release sustaining notes. Leaves the patch in
## place on the channel (another track can take over without silence).
func deactivate() -> void:
	if not _active:
		return
	_release_all()
	_active = false
	_was_playing = false

## Whether this track is currently activated (playing or pending start).
func is_active() -> bool:
	return _active

## Mute or unmute the track at runtime, [param at] the director's beat clock says
## (see [enum MuteTiming]). A muted track keeps advancing exactly as if it were
## playing — its pattern cursor, chain steps and the restarts a song section
## gives it — but plays no notes and no bends, so unmuting resumes in phase with
## nothing restarted. Muting releases the notes held at that moment, as
## [method deactivate] does. A change at a future beat applies per note: notes due
## on or after that beat get the new state (the note on the beat itself too),
## earlier ones the old; a later call replaces a pending one, and a call that
## asks for the state the track already has cancels it. The mute is independent of
## [method activate] / [method deactivate], [method swap_pattern],
## [method start_pattern_at] and the song player's slots, and the sample bake
## ignores it. Kit tracks mute every piece. With no running director clock
## ([member MusicDirector.playing] false) the change applies at once.
func set_muted(muted: bool, at: MuteTiming = MuteTiming.NOW) -> void:
	var beat: float = _mute_change_beat(at)
	if is_nan(beat):
		_mute_pending = false
		_apply_mute(muted)
		return
	if muted == _muted:
		_mute_pending = false  # already so: drop a change that would undo it
		return
	_mute_pending = true
	_mute_pending_value = muted
	_mute_pending_beat = beat

## Whether the track is muted now (a change set for a later beat is not counted
## until that beat has been played).
func is_muted() -> bool:
	return _muted

## The change waiting for its beat: {"muted": bool, "beat": float} (the beat on
## the clock the track runs on), or an empty dictionary.
func get_pending_mute() -> Dictionary:
	if not _mute_pending:
		return {}
	return {"muted": _mute_pending_value, "beat": _mute_pending_beat}

## SFX-style one-shot: activate, await one full pattern length, then
## deactivate. Idempotent under rapid re-trigger — only the most recent
## call's deferred deactivate fires (older awaits no-op via token check).
func play_once() -> void:
	activate()
	if pattern == null or pattern.get_play_length() <= 0.0:
		return
	_play_once_token += 1
	var token: int = _play_once_token
	var bpm: float = bpm_override
	if bpm <= 0.0:
		if director != null:
			bpm = director.get_bpm()
	if bpm <= 0.0:
		bpm = 120.0
	var seconds: float = pattern.get_play_length() * 60.0 / bpm
	await get_tree().create_timer(seconds).timeout
	if token == _play_once_token:
		deactivate()

## Swap the patch on this track's channel. No effect on pattern state. A track
## that plays a kit keeps its pieces' patches (see [method swap_kit]).
func swap_patch(new_patch: SynthPatch) -> void:
	patch = new_patch
	if synth == null:
		return
	if uses_kit():
		apply_patches()
	elif new_patch != null:
		synth.set_patch(synth_channel, new_patch)

## Swap the kit: its pieces' patches go on their channels and the bus and effects
## on each of them. Ongoing notes are released. No effect on pattern state.
func swap_kit(new_kit: SynthKit) -> void:
	_release_all()
	kit = new_kit
	if synth != null:
		apply_patches()
		if _active:
			_configure_bus()

## True when this track plays [member kit]: a DRUM track whose kit has pieces.
func uses_kit() -> bool:
	return track_type == TrackType.DRUM and kit != null and not kit.pieces.is_empty()

## The channels the kit occupies, as [first, last] (last may be above 15), or an
## empty array when the track plays no kit.
func get_kit_channels() -> Array[int]:
	var out: Array[int] = []
	if uses_kit():
		out.append(synth_channel)
		out.append(synth_channel + kit.pieces.size() - 1)
	return out

## What is wrong with the kit's channel range, or "": it must fit in channels
## 0..[constant SynthEngine.CHANNEL_COUNT] - 1.
func get_kit_warning() -> String:
	if not uses_kit():
		return ""
	var last: int = synth_channel + kit.pieces.size() - 1
	if last < SynthEngine.CHANNEL_COUNT:
		return ""
	return "The kit has %d pieces, so it needs channels %d to %d, but the synth only has channels 0 to %d. Only the first %d pieces play." % [
			kit.pieces.size(), synth_channel, last, SynthEngine.CHANNEL_COUNT - 1, SynthEngine.CHANNEL_COUNT - synth_channel]

# The channel a kit piece plays on, or -1 when it does not fit.
func _piece_channel(i: int) -> int:
	var ch: int = synth_channel + i
	return ch if ch < SynthEngine.CHANNEL_COUNT else -1

## Put the patch (or each kit piece's patch) on its channel(s). [method activate]
## does this; call it yourself to pre-bind a track that is not active yet.
func apply_patches() -> void:
	if synth == null:
		return
	if not uses_kit():
		if patch != null:
			synth.set_patch(synth_channel, patch)
		return
	var warning := get_kit_warning()
	if warning != "":
		push_warning("[MusicTrack] %s: %s" % [name, warning])
	for i in kit.pieces.size():
		var ch := _piece_channel(i)
		var piece: SynthKitPiece = kit.pieces[i]
		if ch >= 0 and piece != null and piece.patch != null:
			synth.set_patch(ch, piece.patch)

## Swap the pattern, optionally with a different transition mode.
## Default uses [member swap_mode]. Ongoing notes are released so the
## new pattern starts cleanly.
func swap_pattern(new_pattern: MusicPattern, mode: int = -1) -> void:
	var resolved_mode: int = mode if mode >= 0 else int(swap_mode)
	_release_all()
	pattern = new_pattern
	if _active and _was_playing:
		_resolve_start_state(resolved_mode)
		_sync_cursor_to_now()

## Play [param new_pattern] with its beat 0 on director beat [param origin_beat],
## sounding from director beat [param from_beat] on (default: the origin; notes
## of the pattern before it are skipped, a note exactly on it plays). Exact: the
## pattern grid stays on the origin however late in a frame this is called, as
## long as the director's clock has not passed [param from_beat] by more than
## the frame. Ignores [member swap_mode] and [member sync_to_director]. Releases
## sounding notes and activates the track if it is not active. A track on its
## own clock ([member bpm_override]) just restarts the pattern next frame.
## [MusicDataPlayer] calls this for a song section's PLAY slots; call it after
## the director has started playing.
func start_pattern_at(new_pattern: MusicPattern, origin_beat: float, from_beat: float = NAN) -> void:
	var from: float = origin_beat if is_nan(from_beat) else from_beat
	_release_all()
	pattern = new_pattern
	if not _active:
		apply_patches()
		_configure_bus()
		_active = true
	if bpm_override > 0.0:
		_was_playing = false
		return
	_local_time = 0.0
	_start_at_beat = from
	_activated_at_beat = origin_beat
	_was_playing = director != null and director.playing
	_scanned_to = from - 0.0001
	var length: float = pattern.get_play_length() if pattern != null else 0.0
	var rel: float = from - origin_beat
	if length <= 0.0 or rel <= 0.0001:
		_prev_cursor = -0.001
	else:
		_prev_cursor = fposmod(rel, length) - 0.0001

## Play everything due before director beat [param beat] (not on it) now: note-
## offs, bends and pattern notes, resolved against the director's block as it is
## now. [MusicDataPlayer] calls it when a song section ends partway through a
## frame, before it swaps the progression, so the old section's last notes keep
## the old harmony and nothing on the new section's first beat sounds early.
## Does nothing for a track that is not playing, runs on its own clock, or has
## already been played up to there.
func flush_to(beat: float) -> void:
	if synth == null or director == null or not _active or not _was_playing:
		return
	if bpm_override > 0.0 or not director.playing:
		return
	var target: float = beat - 0.0001
	if target <= _scanned_to:
		return
	_advance(target)

## Re-apply effect chain + send target on this channel's auto-bus.
## Call after mutating [member effects] or [member output_bus] at
## runtime.
func refresh_bus() -> void:
	_configure_bus()

func _configure_bus() -> void:
	if synth == null:
		return
	# The editor's AudioServer is the editor's own (its Audio panel edits and
	# saves the project's bus layout). The preview plays dry on Master and must
	# not add auto-buses to it.
	if Engine.is_editor_hint():
		return
	if uses_kit():
		for i in kit.pieces.size():
			var ch := _piece_channel(i)
			if ch >= 0:
				synth.ensure_channel_bus(ch, effects, output_bus)
		return
	synth.ensure_channel_bus(synth_channel, effects, output_bus)

# ---------------------------------------------------------------------------
# Mute
# ---------------------------------------------------------------------------

## [MusicDataPlayer] calls this on the tracks its song drives (null when it lets
## go), so a NEXT_BAR mute counts bars the way the song does.
func set_song_player(player: Node) -> void:
	_song_player = player

# The effective beat a change with timing [param at] takes effect on, or NAN for
# "at once".
func _mute_change_beat(at: MuteTiming) -> float:
	if at == MuteTiming.NOW:
		return NAN
	if bpm_override <= 0.0 and (director == null or not director.playing):
		return NAN
	var effective: float = _effective_beats()
	match at:
		MuteTiming.NEXT_BEAT:
			return ceilf(effective - MUTE_EPS)
		MuteTiming.NEXT_BAR:
			if bpm_override <= 0.0 and _song_player != null and is_instance_valid(_song_player) \
					and _song_player.has_method("get_bar_beat_at_or_after"):
				var bar: float = _song_player.get_bar_beat_at_or_after(effective - MUTE_EPS)
				if not is_nan(bar):
					return bar
			return ceilf((effective - MUTE_EPS) / 4.0) * 4.0
		MuteTiming.NEXT_BLOCK:
			return _next_block_start_effective(effective)
	return NAN

func _apply_mute(muted: bool) -> void:
	if muted == _muted:
		return
	_muted = muted
	if muted:
		_release_all()

# Apply a pending change once the clock has played up to its beat.
func _settle_mute(effective: float) -> void:
	if _mute_pending and effective >= _mute_pending_beat - MUTE_EPS:
		_mute_pending = false
		_apply_mute(_mute_pending_value)

# Whether a note that sounds at effective beat [param at] is muted.
func _muted_at(at: float) -> bool:
	if _mute_pending and at >= _mute_pending_beat - MUTE_EPS:
		return _mute_pending_value
	return _muted

# ---------------------------------------------------------------------------
# Per-frame render
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if synth == null or director == null:
		return
	if not _active:
		if _mute_pending:
			_settle_mute(_effective_beats())
		return

	var using_override: bool = bpm_override > 0.0
	var director_playing: bool = director.playing

	# Non-override tracks pause when the global director isn't running.
	if not using_override and not director_playing:
		if _was_playing:
			_release_all()
			_was_playing = false
		return

	# First frame after (re)activation or director-resume: compute when
	# to start, where the cursor begins, and align _prev_cursor so we
	# don't stampede historical notes.
	if not _was_playing:
		_was_playing = true
		_local_time = 0.0
		_resolve_start_state(int(swap_mode))
		_sync_cursor_to_now()

	if using_override:
		# Capped as the director's clock is (see MusicDirector.MAX_FRAME).
		_local_time += minf(delta, MusicDirector.MAX_FRAME)

	_advance(_effective_beats())

# Play what is due up to [param effective]: note-offs, bends, pattern notes.
func _advance(effective: float) -> void:
	_scanned_to = effective

	# Release note-offs whose time has come.
	var i: int = _active_notes.size() - 1
	while i >= 0:
		var entry: Dictionary = _active_notes[i]
		if effective >= entry["off_time"]:
			var off_ch: int = entry.get("channel", synth_channel)
			synth.note_off(off_ch, entry["midi"])
			_cancel_pending_bends(entry["midi"], off_ch)
			_active_notes.remove_at(i)
		i -= 1

	# Fire bends whose scheduled beat has arrived.
	if not _pending_bends.is_empty():
		var bpm: float = _effective_bpm()
		var bi: int = _pending_bends.size() - 1
		while bi >= 0:
			var be: Dictionary = _pending_bends[bi]
			if effective >= float(be["fire_beat"]):
				var glide_seconds: float = 0.0
				if bpm > 0.0:
					glide_seconds = float(be["glide_beats"]) * 60.0 / bpm
				synth.bend_to(int(be.get("channel", synth_channel)), int(be["midi"]),
					float(be["target_freq"]), glide_seconds)
				_pending_bends.remove_at(bi)
			bi -= 1

	_play_due_notes(effective)
	_settle_mute(effective)

# The pattern notes due up to [param effective], except the muted ones (the
# cursor moves on either way).
func _play_due_notes(effective: float) -> void:
	var using_override: bool = bpm_override > 0.0
	if pattern == null:
		return
	var play_notes: Array[PatternNote] = pattern.get_play_notes()
	if play_notes.is_empty():
		return

	if effective < _start_at_beat - 0.001:
		return  # pending — waiting for the swap_mode-defined start point

	var relative: float = effective - _activated_at_beat
	var length: float = pattern.get_play_length()
	if length <= 0.0:
		return
	var cursor: float = fposmod(relative, length)
	var wrapped: bool = cursor < _prev_cursor - 0.001
	var cycle_start: float = effective - cursor
	var gate: bool = _muted or _mute_pending

	for note in play_notes:
		var note_beat: float = note.beat
		if not using_override and director != null:
			note_beat = director.get_swung_beat(note.beat)
		var swung: float = fposmod(note_beat, length)
		var should_trigger: bool = false
		if wrapped:
			should_trigger = (swung > _prev_cursor and swung <= length) or swung <= cursor
		else:
			should_trigger = swung > _prev_cursor and swung <= cursor
		if should_trigger:
			if gate:
				# The beat the note sounds on: this cycle's, or the one that just ended.
				var at: float = cycle_start + swung
				if wrapped and swung > cursor:
					at -= length
				if _muted_at(at):
					continue
			_trigger_note(note, effective)

	_prev_cursor = cursor

# ---------------------------------------------------------------------------
# Clock + context helpers
# ---------------------------------------------------------------------------

func _effective_beats() -> float:
	if bpm_override > 0.0:
		return _local_time * bpm_override / 60.0
	return director.get_total_beats() if director != null else 0.0

func _effective_block() -> MusicBlock:
	if key_override != null:
		return key_override
	if director == null:
		return null
	return director.get_current_block()

## Compute [_start_at_beat] (when playback begins) from the transition
## mode, and [_activated_at_beat] (cursor offset) from sync_to_director.
func _resolve_start_state(mode: int) -> void:
	var effective: float = _effective_beats()
	match mode:
		MusicDirector.SwapMode.IMMEDIATE:
			_start_at_beat = effective
		MusicDirector.SwapMode.NEXT_BEAT:
			_start_at_beat = ceilf(effective)
		MusicDirector.SwapMode.NEXT_BLOCK:
			_start_at_beat = _next_block_start_effective(effective)
		_:
			_start_at_beat = effective
	_activated_at_beat = 0.0 if sync_to_director else _start_at_beat

## Effective-beat at which the director's next block begins. Falls back
## to current effective beats when no director / no progression / on
## bpm_override (in which case NEXT_BLOCK degrades to IMMEDIATE).
func _next_block_start_effective(effective: float) -> float:
	if bpm_override > 0.0 or director == null:
		return effective
	var block := director.get_current_block()
	if block == null:
		return effective
	var beats_remaining: float = float(block.duration_beats) - director.get_beat_in_block()
	if beats_remaining <= 0.001:
		return effective
	return effective + beats_remaining

## Align [_prev_cursor] to the current cursor so the next _process frame
## doesn't trigger notes for the pattern region "before now".
##
## - Pending (effective < _start_at_beat): -0.001, so beat-0 fires when
##   playback actually begins.
## - Fresh start (relative ≈ 0, sync_to_director=false): -0.001, beat-0 fires.
## - Mid-pattern start (sync_to_director=true): cursor at director's
##   absolute position, so historical notes don't stampede.
func _sync_cursor_to_now() -> void:
	var length: float = pattern.get_play_length() if pattern != null else 0.0
	if length <= 0.0:
		_prev_cursor = -0.001
		return
	var effective: float = _effective_beats()
	if effective < _start_at_beat - 0.001:
		_prev_cursor = -0.001
		return
	var relative: float = effective - _activated_at_beat
	if relative <= 0.001:
		_prev_cursor = -0.001
	else:
		_prev_cursor = fposmod(relative, length)

# ---------------------------------------------------------------------------
# Note resolution
# ---------------------------------------------------------------------------

func _trigger_note(note: PatternNote, effective_beats: float) -> void:
	if uses_kit():
		_trigger_kit_note(note, effective_beats)
		return
	var midi_float: float = _resolve_midi_float(note.index, note.octave, note.accidental)
	var midi_handle: int = roundi(midi_float)
	synth.note_on(synth_channel, midi_float, clampf(note.velocity * velocity_scale, 0.0, 1.0), pan)
	_active_notes.append({"midi": midi_handle, "channel": synth_channel, "off_time": effective_beats + note.duration})
	if not note.bends.is_empty():
		_schedule_bends(midi_handle, synth_channel, effective_beats, note.bends, 0.0, 0.0)

# A DRUM note on a kit: the row picks the piece, the piece's channel, patch pitch,
# gain and pan play it. A row no piece owns is silent.
func _trigger_kit_note(note: PatternNote, effective_beats: float) -> void:
	var i: int = kit.piece_for_note(note.index)
	if i < 0:
		return
	var ch := _piece_channel(i)
	if ch < 0:
		return
	var piece: SynthKitPiece = kit.pieces[i]
	var pitch: int = piece.get_pitch()
	synth.note_on(ch, float(pitch), piece.scale_velocity(note.velocity * velocity_scale), piece.combined_pan(pan))
	_active_notes.append({"midi": pitch, "channel": ch, "off_time": effective_beats + note.duration})
	if not note.bends.is_empty():
		# A bend aims at an absolute note, so it moves with the piece's pitch.
		_schedule_bends(pitch, ch, effective_beats, note.bends, 0.0, float(pitch - piece.note))

## Append every bend in [param bends] (and their nested children) to
## [_pending_bends] with absolute fire beats. [param parent_offset] is the
## accumulated offset of this bend's parent within the bend chain — child
## bends fire at parent_start_beat + parent_offset + bend.offset_beats,
## so each nested bend's offset_beats stays "relative to its own parent".
func _schedule_bends(midi_handle: int, channel: int, parent_start_beat: float, bends: Array[PatternBend],
		parent_offset: float, pitch_shift: float) -> void:
	for b in bends:
		var fire_beat: float = parent_start_beat + parent_offset + b.offset_beats
		var target_midi: float = _resolve_midi_float(b.index, b.octave, b.accidental) + pitch_shift
		var target_freq: float = 440.0 * pow(2.0, (target_midi - 69.0) / 12.0)
		_pending_bends.append({
			"midi": midi_handle,
			"channel": channel,
			"fire_beat": fire_beat,
			"target_freq": target_freq,
			"glide_beats": b.glide_beats,
		})
		if not b.bends.is_empty():
			_schedule_bends(midi_handle, channel, parent_start_beat, b.bends, parent_offset + b.offset_beats, pitch_shift)

func _cancel_pending_bends(midi_handle: int, channel: int) -> void:
	var i: int = _pending_bends.size() - 1
	while i >= 0:
		if int(_pending_bends[i]["midi"]) == midi_handle and int(_pending_bends[i].get("channel", synth_channel)) == channel:
			_pending_bends.remove_at(i)
		i -= 1

func _effective_bpm() -> float:
	if bpm_override > 0.0:
		return bpm_override
	if director != null and (director.data != null or director.bpm_override > 0.0):
		return director.get_bpm()
	return 120.0

## Resolve a (index, octave, accidental) triple to a fractional MIDI number
## in the current block's harmonic context. Returns float so microtonal
## accidentals (e.g. 0.5) flow through unrounded.
func _resolve_midi_float(p_index: int, p_octave: int, p_accidental: float) -> float:
	match track_type:
		TrackType.CHORD:
			return _resolve_chord_float(p_index, p_octave, p_accidental)
		TrackType.MELODY:
			return _resolve_melody_float(p_index, p_octave, p_accidental)
		_: # DRUM — index is absolute MIDI
			return float(p_index)

func _resolve_chord_float(p_index: int, p_octave: int, p_accidental: float) -> float:
	var block := _effective_block()
	if block == null:
		return 60.0
	var intervals := block.chord_intervals
	var size: int = intervals.size()
	if size == 0:
		return 60.0
	var idx: int = posmod(p_index, size)
	var extra_oct: int = int(floorf(float(p_index) / float(size)))
	return float(12 * (base_octave + 1 + p_octave + extra_oct) + block.chord_root + intervals[idx]) + p_accidental

func _resolve_melody_float(p_index: int, p_octave: int, p_accidental: float) -> float:
	var block := _effective_block()
	if block == null:
		return 60.0
	var intervals := block.scale_intervals
	var size: int = intervals.size()
	if size == 0:
		return 60.0
	var idx: int = posmod(p_index, size)
	var extra_oct: int = int(floorf(float(p_index) / float(size)))
	return float(12 * (base_octave + 1 + p_octave + extra_oct) + block.scale_root + intervals[idx]) + p_accidental

# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_block_changed(_block: MusicBlock, _index: int) -> void:
	if track_type == TrackType.DRUM:
		return
	if key_override != null:
		return  # we don't care about the director's block
	_release_all()

func _on_seeked() -> void:
	if bpm_override > 0.0:
		return  # our clock is independent of the director
	_release_all()
	if _active and _was_playing:
		_sync_cursor_to_now()

func _release_all() -> void:
	if synth == null:
		return
	for entry in _active_notes:
		synth.note_off(entry.get("channel", synth_channel), entry["midi"])
	_active_notes.clear()
	_pending_bends.clear()
