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
## The song whose sections the timeline lays end to end (null: a plain scene, where
## [member data] repeats across the span). Set it with [method set_song].
var song: MusicSong
## SynthSongLayout.segments() of [member song].
var segments: Array = []

## Lay [param s] out (null: back to a plain progression). The span becomes the length
## of one pass of the song.
func set_song(s: MusicSong) -> void:
	song = s
	segments = SynthSongLayout.segments(s)
	if s != null:
		var length := s.get_length_beats()
		span = length if length > 0.0 else 8.0

## The segment of [member segments] that [param beat] falls in, or -1.
func segment_at(beat: float) -> int:
	for i in segments.size():
		if beat >= segments[i]["start"] - 0.0001 and beat < segments[i]["start"] + segments[i]["length"] - 0.0001:
			return i
	return -1

func x_of(beat: float, width: float) -> float:
	return beat / maxf(span, 0.001) * width

func beat_of(x: float, width: float) -> float:
	return clampf(x / maxf(width, 1.0), 0.0, 1.0) * span

## Beats of one trip through the progression (0 without data).
func progression_beats() -> float:
	return float(SynthHarmony.progression_beats(data))

## [beat, block index, block] for every block start inside the span, the
## progression repeating. Empty without data. With a song: each section's own
## progression (its repeats in a row) end to end, and the entries have two more
## elements, [MusicData, segment index], and the section repeat after that.
func block_starts() -> Array:
	var out: Array = []
	if song != null:
		return _song_block_starts()
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

func _song_block_starts() -> Array:
	var out: Array = []
	for si in segments.size():
		var seg: Dictionary = segments[si]
		var d: MusicData = seg["progression"]
		if d == null:
			continue
		var section: MusicSection = seg["section"]
		var t: float = seg["start"]
		for rep in maxi(1, section.repeats):
			for i in d.blocks.size():
				out.append([t, i, d.blocks[i], d, si, rep])
				t += float(d.blocks[i].duration_beats)
	return out

## [param total] (the director's beat) on this timeline: the song's, folded into its
## loop after one pass; a plain scene's wrapped at the span.
func cursor_of(total: float) -> float:
	if song != null:
		return SynthSongLayout.fold(song, total)
	return fposmod(total, span)
