@tool
class_name PatternChainStep
extends Resource

# One link of a PatternChain: a pattern (or another chain) played [member repeats]
# times, optionally transposed by whole octaves and scaled in velocity.

## The pattern this step plays. Another [PatternChain] is allowed (a chain that
## contains itself, directly or not, is skipped with a warning). A null pattern
## or one with no length contributes nothing.
@export var pattern: MusicPattern

## How many times in a row the pattern plays before the next step. At least 1.
@export_range(1, 64, 1, "or_greater") var repeats: int = 1:
	set(value):
		repeats = maxi(1, value)

## Whole octaves added to every note's (and bend's) octave in this step. Ignored
## by DRUM tracks, like [member PatternNote.octave].
@export var octave_shift: int = 0

## Multiplier on every note's velocity in this step. The result is clamped to
## 0..1.
@export_range(0.0, 4.0, 0.01, "or_greater") var velocity_scale: float = 1.0

static func create(p_pattern: MusicPattern, p_repeats: int = 1, p_octave_shift: int = 0,
		p_velocity_scale: float = 1.0) -> PatternChainStep:
	var s := PatternChainStep.new()
	s.pattern = p_pattern
	s.repeats = p_repeats
	s.octave_shift = p_octave_shift
	s.velocity_scale = p_velocity_scale
	return s
