@tool
class_name SynthSongLayout
extends RefCounted

# Where a MusicSong puts things on its timeline, as plain data for the Track view:
# the chips of the section strip, the progression blocks under them and what each
# track does in each of them. Nothing here draws or edits; the rules are the ones
# MusicDataPlayer plays by (see the README's "Sections and songs").

## What a lane region shows.
enum Kind {
	PLAY,    ## the slot plays its pattern, restarted at the region start
	SILENT,  ## the slot stops the track
	KEEP,    ## the track carries on with what it was playing (no slot, or a KEEP slot)
}

## What a KEEP region carries on with.
enum Carry {
	NONE,    ## the track was not playing: it stays silent
	OWN,     ## the track's own pattern, as if from the song's beat 0
	PLAY,    ## the pattern an earlier section's PLAY slot started
	SILENT,  ## an earlier section silenced it
}

## One chip per repeat of every entry that has a length, in order, on one pass of the
## song: {entry, repeat, section, start, length, progression}. [code]start[/code] is
## the song's timeline beat; [code]progression[/code] the MusicData the section plays.
static func segments(song: MusicSong) -> Array:
	var out: Array = []
	if song == null:
		return out
	for i in song.entries.size():
		var e: MusicSongEntry = song.entries[i]
		if e == null or e.section == null:
			continue
		var length := song.section_length(e.section)
		if length <= 0.0:
			continue
		var base := song.entry_start(i)
		for r in maxi(1, e.repeats):
			out.append({"entry": i, "repeat": r, "section": e.section, "start": base + float(r) * length,
					"length": length, "progression": e.section.get_progression(song)})
	return out

## [param total] (a director beat, which keeps counting after the song loops) as a
## beat of the song's timeline: past one pass it folds into the loop region.
static func fold(song: MusicSong, total: float) -> float:
	if song == null:
		return total
	var length := song.get_length_beats()
	if length <= 0.0 or total < length:
		return maxf(total, 0.0)
	var loop_start := song.get_loop_start_beats()
	var loop_len := length - loop_start
	if loop_len <= 0.0:
		return maxf(total, 0.0)
	return loop_start + fposmod(total - length, loop_len)

## A colour for [param section]: the same one wherever it appears, a different one
## for each section the song can play.
static func section_color(song: MusicSong, section: MusicSection) -> Color:
	var idx := 0
	if song != null:
		idx = maxi(0, song.get_reachable_sections().find(section))
	return Color.from_hsv(fposmod(0.58 + float(idx) * 0.381966, 1.0), 0.46, 0.60)

## What to call [param section] in labels.
static func section_label(section: MusicSection) -> String:
	if section == null:
		return "(none)"
	return section.name if section.name != "" else "(unnamed)"

## "Section N" with the smallest N no section of [param song] is called yet.
static func new_section_name(song: MusicSong) -> String:
	var used := {}
	if song != null:
		for s in song.get_reachable_sections():
			used[s.name] = true
	var n := 1
	while used.has("Section %d" % n):
		n += 1
	return "Section %d" % n

## What the track called [param track_name] does across one pass of the song, one
## region per [method segments] chip: {entry, repeat, start, end, section, kind
## (Kind), carry (Carry), pattern, origin}. [param pattern] and [param autoplay] are
## the track's own pattern and its [code]autoplay[/code] (a track that is not
## active at the start plays nothing until a PLAY slot starts it). For PLAY the
## pattern is the slot's (else the track's own) and [code]origin[/code] the region
## start; for a KEEP region that carries on with something, the pattern and the
## beat its first note was due on.
static func lane_regions(song: MusicSong, track_name: StringName, own: MusicPattern, autoplay: bool) -> Array:
	var out: Array = []
	var carry := Carry.OWN if autoplay else Carry.NONE
	var pat: MusicPattern = own
	var origin := 0.0
	for seg in segments(song):
		var section: MusicSection = seg["section"]
		var slot := section.get_slot(track_name)
		var kind := Kind.KEEP
		if slot != null:
			match slot.mode:
				MusicSectionSlot.Mode.PLAY:
					kind = Kind.PLAY
					carry = Carry.PLAY
					pat = slot.pattern if slot.pattern != null else own
					origin = seg["start"]
				MusicSectionSlot.Mode.SILENT:
					kind = Kind.SILENT
					carry = Carry.SILENT
		out.append({"entry": seg["entry"], "repeat": seg["repeat"], "start": seg["start"],
				"end": seg["start"] + seg["length"], "section": section, "kind": kind, "carry": carry,
				"pattern": pat if carry == Carry.OWN or carry == Carry.PLAY else null, "origin": origin})
	return out

## A short text that changes whenever anything the song says changes (the patterns
## in its slots are told by [param pattern_sig], a Callable(MusicPattern) -> String).
static func fingerprint(song: MusicSong, pattern_sig: Callable) -> String:
	if song == null:
		return "-"
	var s := "%d|%.4f|%d|%d|" % [song.get_instance_id(), song.bpm, song.beats_per_bar, song.loop_entry]
	s += "P%s|" % _data_sig(song.progression)
	for e in song.entries:
		s += "E-;" if e == null else "E%d,%d;" % [e.section.get_instance_id() if e.section != null else 0, e.repeats]
	var seen := {}
	var list := song.get_reachable_sections()
	for sec in list:
		if seen.has(sec):
			continue
		seen[sec] = true
		s += "S%d,%s,%d,%s:" % [sec.get_instance_id(), sec.name, sec.repeats, _data_sig(sec.progression)]
		for slot in sec.slots:
			s += "-" if slot == null else "%s/%d/%s," % [slot.track, int(slot.mode), pattern_sig.call(slot.pattern)]
		s += ";"
	for sec in song.also_bake:
		s += "B%d;" % (sec.get_instance_id() if sec != null else 0)
	return s

static func _data_sig(d: MusicData) -> String:
	return "-" if d == null else "%d:%s" % [d.get_instance_id(), SynthHarmony.fingerprint(d)]
