@tool
class_name SynthTimeline
extends RefCounted

# What the Track view's rows share: how many beats the timeline shows, and the
# MusicData whose blocks the rows draw behind their clips. Each row maps beats to
# its own width (width / span), so rows of equal width line up.

## Beats shown, left to right.
var span: float = 8.0
## The progression the timeline sits over (null: none).
var data: MusicData

func x_of(beat: float, width: float) -> float:
	return beat / maxf(span, 0.001) * width

func beat_of(x: float, width: float) -> float:
	return clampf(x / maxf(width, 1.0), 0.0, 1.0) * span

## Beats of one trip through the progression (0 without data).
func progression_beats() -> float:
	return float(SynthHarmony.progression_beats(data))

## [beat, block index, block] for every block start inside the span, the
## progression repeating. Empty without data.
func block_starts() -> Array:
	var out: Array = []
	if data == null or data.blocks.is_empty():
		return out
	var total := progression_beats()
	if total <= 0.0:
		return out
	var t := 0.0
	while t < span - 0.0001:
		for i in data.blocks.size():
			if t >= span - 0.0001:
				break
			out.append([t, i, data.blocks[i]])
			t += maxf(1.0, float(data.blocks[i].duration_beats))
	return out

## The span to show: two trips through the progression or the longest pattern,
## whichever is longer.
static func choose_span(prog_beats: float, longest_pattern: float) -> float:
	var prog_span := 2.0 * prog_beats if prog_beats > 0.0 else 8.0
	return maxf(prog_span, longest_pattern)
