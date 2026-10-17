@tool
class_name PatternChain
extends MusicPattern

# A pattern made of other patterns: its [member steps] play one after another,
# each repeated, and the chain loops at the end of the last one. A chain IS a
# MusicPattern, so it goes anywhere a pattern does (MusicTrack.pattern,
# swap_pattern, the bake).
#
# The notes a chain plays are the steps' notes laid end to end ("flattened"):
# every PatternNote is copied with its beat moved to the step's place in the
# chain, its octave shifted and its velocity scaled, so a chain plays exactly as
# one long pattern with those notes would. Notes are (index, octave, accidental)
# triples that are resolved against the director's block at play time, so the
# chain follows the harmony like any pattern.
#
# Read what plays through [method get_play_notes] and [method get_play_length],
# never [member notes] or [member length_beats]: on a chain those two are derived
# (hidden from the inspector, never saved) and [member length_beats] only holds
# the length as of the last accessor call.
#
# The flattened result is cached and rebuilt when the chain changes. Edits are
# noticed through a fingerprint checked on every call: always the steps and the
# length / note count of each pattern, plus (in the editor, or with
# [member deep_check]) every note field and bend. A game that changes a note's
# fields in code after the chain has played calls [method invalidate].

## Whether the cache fingerprint covers every note field and bend of every
## source pattern, not just their lengths and note counts. On in the editor so a
## step pattern edited in the Synth tab is picked up at once; off in a running
## game, where the patterns are not edited.
static var deep_check: bool = Engine.is_editor_hint()

## What plays, in order. See [PatternChainStep].
@export var steps: Array[PatternChainStep] = []:
	set(value):
		steps = value
		invalidate()

var _cache_notes: Array[PatternNote] = []
var _cache_length: float = 0.0
var _cache_key: int = 0
var _cache_valid: bool = false

func _init() -> void:
	changed.connect(invalidate)

func _validate_property(property: Dictionary) -> void:
	# Derived from the steps: not edited, not stored.
	if property.name == "notes" or property.name == "length_beats":
		property.usage = PROPERTY_USAGE_NONE

## Append a step. Chainable, like [method MusicPattern.add].
func add_step(p_pattern: MusicPattern, p_repeats: int = 1, p_octave_shift: int = 0,
		p_velocity_scale: float = 1.0) -> PatternChain:
	steps.append(PatternChainStep.create(p_pattern, p_repeats, p_octave_shift, p_velocity_scale))
	invalidate()
	return self

## A chain has no notes of its own to add to.
func add(_p_beat: float, _p_dur: float, _p_index: int, _p_oct: int = 0, _p_acc: float = 0.0, _p_vel: float = 0.8) -> MusicPattern:
	push_warning("[PatternChain] add() ignored: a chain's notes come from its steps (see add_step).")
	return self

## Drop the cached flattening; the next accessor call rebuilds it.
func invalidate() -> void:
	_cache_valid = false

## The steps' notes laid end to end, as new PatternNote / PatternBend copies.
## Cached and shared: read it, do not change it.
func get_play_notes() -> Array[PatternNote]:
	_refresh()
	return _cache_notes

## Sum of every step's pattern length times its repeats, in beats.
func get_play_length() -> float:
	_refresh()
	return _cache_length

func _refresh() -> void:
	var key: int = _fingerprint()
	if _cache_valid and key == _cache_key:
		return
	var built: Array = _build([self])
	_cache_notes = built[0]
	_cache_length = built[1]
	_cache_key = key
	_cache_valid = true
	# Only for code that reads the raw field; the accessors are the contract.
	length_beats = _cache_length

# ---------------------------------------------------------------------------
# Flattening
# ---------------------------------------------------------------------------

## Flatten this chain. [param stack] holds the chains being flattened above it
## (itself included); a step reaching one of them would loop forever and is
## skipped. Returns [Array[PatternNote], length].
func _build(stack: Array) -> Array:
	var out: Array[PatternNote] = []
	var pos: float = 0.0
	for step in steps:
		if step == null or step.pattern == null:
			continue
		var p: MusicPattern = step.pattern
		if stack.has(p):
			push_warning("[PatternChain] Step skipped: it would contain the chain that contains it (cycle).")
			continue
		var src: Array[PatternNote]
		var plen: float
		if p is PatternChain:
			stack.append(p)
			var sub: Array = (p as PatternChain)._build(stack)
			stack.pop_back()
			src = sub[0]
			plen = sub[1]
		else:
			src = p.get_play_notes()
			plen = p.get_play_length()
		if plen <= 0.0:
			continue
		for _r in maxi(1, step.repeats):
			for n in src:
				# A plain pattern plays a note at its beat modulo its length.
				out.append(_copy_note(n, pos + fposmod(n.beat, plen), step.octave_shift, step.velocity_scale))
			pos += plen
	return [out, pos]

static func _copy_note(n: PatternNote, beat: float, octave_shift: int, velocity_scale: float) -> PatternNote:
	var c := PatternNote.new()
	c.beat = beat
	c.duration = n.duration
	c.index = n.index
	c.octave = n.octave + octave_shift
	c.accidental = n.accidental
	c.velocity = clampf(n.velocity * velocity_scale, 0.0, 1.0)
	c.bends = _copy_bends(n.bends, octave_shift)
	return c

static func _copy_bends(bends: Array[PatternBend], octave_shift: int) -> Array[PatternBend]:
	var out: Array[PatternBend] = []
	for b in bends:
		var c := PatternBend.new()
		c.offset_beats = b.offset_beats
		c.glide_beats = b.glide_beats
		c.index = b.index
		c.octave = b.octave + octave_shift
		c.accidental = b.accidental
		c.bends = _copy_bends(b.bends, octave_shift)
		out.append(c)
	return out

# ---------------------------------------------------------------------------
# Cache fingerprint
# ---------------------------------------------------------------------------

func _fingerprint() -> int:
	var parts: Array = []
	_key_into(parts, [self], deep_check)
	return parts.hash()

func _key_into(parts: Array, stack: Array, deep: bool) -> void:
	parts.append(steps.size())
	for step in steps:
		if step == null or step.pattern == null:
			parts.append(0)
			continue
		var p: MusicPattern = step.pattern
		parts.append(p.get_instance_id())
		parts.append(step.repeats)
		parts.append(step.octave_shift)
		parts.append(step.velocity_scale)
		if stack.has(p):
			parts.append(-1)
		elif p is PatternChain:
			stack.append(p)
			(p as PatternChain)._key_into(parts, stack, deep)
			stack.pop_back()
		else:
			parts.append(p.get_play_length())
			var notes: Array[PatternNote] = p.get_play_notes()
			parts.append(notes.size())
			if deep:
				for n in notes:
					parts.append_array([n.beat, n.duration, n.index, n.octave, n.accidental, n.velocity])
					_bends_key_into(parts, n.bends)

static func _bends_key_into(parts: Array, bends: Array[PatternBend]) -> void:
	parts.append(bends.size())
	for b in bends:
		parts.append_array([b.offset_beats, b.glide_beats, b.index, b.octave, b.accidental])
		_bends_key_into(parts, b.bends)
