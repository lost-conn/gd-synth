@tool
class_name SynthBakeInfo
extends RefCounted

# Where a patch stands against its baked SynthSampleSet: is there one, is it still
# the patch as it is now, which notes does it hold. Answers the Sound view's bake
# chip, the Baked audition and the keyboard's highlighted keys.
#
# RE-BAKING. This file cannot re-bake a patch from a set alone, and says so. A
# set records the patch it was baked from (source_patch, patch_fingerprint) and
# what came out (roots, velocities, gates, bends), but not what went in: the
# notes, velocities and note lengths the game plays the patch at, which
# SynthSampleBaker.Usage holds and which the host's bake tool collects from its
# songs and SFX tables. Baking again from the roots alone would give a different
# set from the one the host's tool makes (other note lengths, no softest
# velocity, no tempo), and would overwrite the host's set with it. So: stale is
# reported, and the Synth tab's Bake button runs the host's own tool, an
# EditorScript named by the project setting BAKE_TOOL_SETTING. Unset, the
# tooltip says how to set it and names the bake tools found in the project
# (SynthProjectIndex.bake_tools).

const SampleBakerScript := preload("../sample_baker.gd")

## Project setting: res:// path of the host's bake EditorScript (its _run() bakes
## every sample set). Registered by plugin.gd; "" = none.
const BAKE_TOOL_SETTING := "godot_synth/bake/tool_script"

enum State { NONE, UP_TO_DATE, STALE }

## One answer.
class Info:
	var state: int = State.NONE
	var sample_set: SynthSampleSet
	var set_path: String = ""
	## Why the state is what it is, one line each (for the tooltip).
	var reasons: PackedStringArray = PackedStringArray()
	## midi note -> loudest velocity recorded for it, over the set's roots.
	var played: Dictionary = {}

	func chip_text() -> String:
		match state:
			State.UP_TO_DATE:
				return "Bake up to date"
			State.STALE:
				return "Bake stale"
		return "No bake"

	func chip_color(c: Control) -> Color:
		match state:
			State.UP_TO_DATE:
				return SynthRackStyle.good(c)
			State.STALE:
				return SynthRackStyle.warn(c)
		return SynthRackStyle.dim(c)

## Always false: a set alone cannot be re-baked here (see the note at the top of
## this file); the host's bake tool is what the Bake button runs.
static func can_rebake(_info: Info) -> bool:
	return false

## The configured bake tool's path ("" = none set).
static func bake_tool_path() -> String:
	if not ProjectSettings.has_setting(BAKE_TOOL_SETTING):
		return ""
	return str(ProjectSettings.get_setting(BAKE_TOOL_SETTING, "")).strip_edges()

## Why [param path] cannot be run as the bake tool, "" when it can: it must be a
## script that extends EditorScript and compiles.
static func bake_tool_problem(path: String) -> String:
	if path == "":
		return "No bake tool is set."
	if not ResourceLoader.exists(path):
		return "%s does not exist." % path
	var script := load(path) as GDScript
	if script == null:
		return "%s is not a GDScript." % path
	if not script.can_instantiate():
		return "%s does not compile." % path
	if not ClassDB.is_parent_class(script.get_instance_base_type(), &"EditorScript"):
		return "%s does not extend EditorScript." % path
	return ""

## The chip's hover text.
static func tooltip(info: Info, bake_tools: PackedStringArray) -> String:
	var lines := PackedStringArray()
	match info.state:
		State.NONE:
			lines.append("No baked sample set was found for this patch.")
		State.UP_TO_DATE:
			lines.append("The baked set matches this patch.")
		State.STALE:
			lines.append("The baked set no longer matches this patch.")
	if info.sample_set != null:
		lines.append("Set: %s  (%d samples, %.0f KB)" % [info.set_path, info.sample_set.size(),
				info.sample_set.get_data_bytes() / 1024.0])
	for r in info.reasons:
		lines.append("- " + r)
	if info.state != State.UP_TO_DATE:
		lines.append("")
		var tool_path := bake_tool_path()
		if tool_path != "" and bake_tool_problem(tool_path) == "":
			lines.append("Press Bake to re-bake every sample set with %s." % tool_path)
		else:
			lines.append("Baking is done by your project's bake tool, not from a patch alone: a set does not record the notes the game plays, which the tool collects.")
			lines.append("Set the tool in Project Settings (%s) to enable the Bake button." % BAKE_TOOL_SETTING)
			if not bake_tools.is_empty():
				lines.append("Bake tool script(s) found: " + ", ".join(bake_tools.slice(0, 3)))
	return "\n".join(lines)

## Look [param patch] (the patch file at [param patch_path], "" for none) up
## among the project's sets. [param reload] re-reads the set from disk, for after
## it was re-baked while the editor was open.
static func inspect(patch: SynthPatch, patch_path: String, index: SynthProjectIndex,
		reload: bool = false) -> Info:
	var info := Info.new()
	if patch == null:
		info.reasons.append("There is no patch.")
		return info
	if patch_path == "":
		info.reasons.append("The patch is not saved as a file, and a set is looked up by the patch's file name.")
		return info
	var found: SynthSampleSet = null
	var found_path := ""
	if index != null:
		for cand in index.set_candidates(patch_path):
			var res: Resource = ResourceLoader.load(cand, "",
					ResourceLoader.CACHE_MODE_REPLACE if reload else ResourceLoader.CACHE_MODE_REUSE)
			var s := res as SynthSampleSet
			if s == null:
				continue
			# Several folders can hold a set of that name: take the one baked from this patch.
			if found == null or s.source_patch == patch_path:
				found = s
				found_path = cand
			if s.source_patch == patch_path:
				break
	if found == null:
		info.reasons.append("No set named %s.res / .tres exists." % patch_path.get_file().get_basename())
		return info
	info.sample_set = found
	info.set_path = found_path
	info.played = played_notes(found)
	update(info, patch)
	return info

## Re-decide stale / up to date against the patch as it is now (cheap: a hash).
static func update(info: Info, patch: SynthPatch) -> void:
	if info.sample_set == null:
		return
	info.reasons = PackedStringArray()
	var stale := false
	if info.sample_set.is_stale(patch):
		stale = true
		info.reasons.append("The patch was edited after the set was baked (its fingerprint differs).")
	if info.sample_set.baker_version != SampleBakerScript.VERSION:
		stale = true
		info.reasons.append("The set was made by baker v%d; the baker is now v%d, so a re-bake would sound different." % [
				info.sample_set.baker_version, SampleBakerScript.VERSION])
	if info.sample_set.source_patch != "" and not ResourceLoader.exists(info.sample_set.source_patch):
		info.reasons.append("The set says it was baked from %s, which no longer exists." % info.sample_set.source_patch)
	info.state = State.STALE if stale else State.UP_TO_DATE
	if not stale:
		info.reasons.append("Baked from %s with baker v%d." % [
				info.sample_set.source_patch if info.sample_set.source_patch != "" else "(no path)",
				info.sample_set.baker_version])

## The keys a set was baked at: rounded root pitch -> loudest velocity recorded.
## (A root is the note the game plays, give or take the baker's one-semitone
## tolerance: a root can serve its neighbours.)
static func played_notes(sample_set: SynthSampleSet) -> Dictionary:
	var out: Dictionary = {}
	for i in sample_set.size():
		var note: int = roundi(sample_set.root_pitches[i])
		out[note] = maxf(out.get(note, 0.0), sample_set.velocities[i])
	return out
