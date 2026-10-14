@tool
class_name SynthPatternView
extends VBoxContainer

# The Synth tab's Pattern view.
#
#   header     pattern name and file, New / Open / Save / Save As, track type,
#              length, snap, the patch the pattern is heard through, and toggles
#              for the other tracks' notes and the inspector
#   centre     the piano roll (SynthRoll) over a velocity lane, with the yellow
#              playhead (SynthPlayhead) above both
#   right      the inspector (SynthPatternInspector), collapsible
#
# What the view decides, and the roll does not know:
#
#   Track type    how the rows read. It is saved with the pattern as an editor
#                 hint (MusicPattern.editor_track_type). While that is AUTO the
#                 view finds a MusicTrack that plays the pattern in the project's
#                 scenes (first the tab's song context, then a scan through the
#                 scenes that mention the pattern's file), and failing that guesses
#                 from the notes. The tooltip on the Type menu says which.
#   Patch         the pattern is heard through the tab's shared current patch. When
#                 the MusicTrack found pairs the pattern with a patch, the header
#                 offers "Use <patch>", and applies it by itself when the shared
#                 patch is still the untouched default.
#   Other tracks  the other MusicTracks of the song context, drawn faintly. Each
#                 note's pitch is resolved the way its own track would play it,
#                 against the preview MusicData's block at that beat, and put on
#                 the nearest row of this roll. It is an approximation: accidentals
#                 are rounded away, a source pattern shorter than this one is
#                 repeated to fill it, and a progression whose chord size changes
#                 mid-pattern is read at the note's own beat only.
#   Undo          every edit is one EditorUndoRedoManager action (a drag is one),
#                 applied as a SynthPatternSnapshot. Without an undo manager
#                 (outside the editor) edits apply with no history. Edits made
#                 elsewhere (Godot's inspector, Ctrl+Z) arrive through `changed`
#                 on the pattern and its notes and refresh the view.
#
# Playback and note auditioning go through the shared SynthPreview.

signal sound_requested
## Use this patch file as the tab's current patch.
signal patch_requested(path: String)
## The view worked out the song context for the pattern it opened (null: none).
signal song_context_inferred(ctx: SynthSongContext)

const AUTO := MusicPattern.EditorTrackType.AUTO
const INSPECTOR_WIDTH := 280.0
# Below this width (editor scale 1) the inspector folds away unless asked for.
const INSPECTOR_AUTO_HIDE := 820.0
const FAINT_COLORS := [
	Color(0.95, 0.60, 0.35), Color(0.50, 0.85, 0.55), Color(0.72, 0.56, 0.95),
	Color(0.95, 0.80, 0.40), Color(0.45, 0.80, 0.90), Color(0.95, 0.5, 0.65),
]
const AUDITION_SECONDS := 0.28

## The editor's EditorUndoRedoManager. Null: edits apply directly, with no history.
var undo_redo: Object
## The project index (the Sound view's); built here on first need if not given.
var index: SynthProjectIndex
var pattern: MusicPattern
## File the pattern was loaded from / last saved to ("" = unsaved).
var current_path: String = ""
var song_context: SynthSongContext
## Octave the preview plays the pattern in (the MusicTrack's own base_octave in the game).
var base_octave: int = 4

var _preview: SynthPreview
var _preview_is_own: bool = false
var _addon_dir: String = ""
var _inferred: Dictionary = {}
var _offer_path: String = ""
var _clean_fp: String = ""
var _last_edited_flag: bool = false
var _refresh_queued: bool = false
var _watched: Array = []
var _pending: Callable = Callable()
var _after_save: Callable = Callable()
var _inspector_pref: int = -1       # -1 auto, 0 hidden, 1 shown
var _audition_tickets: Dictionary = {}
var _built: bool = false

var _name_label: Label
var _path_label: Label
var _type_opt: OptionButton
var _length_spin: SpinBox
var _snap_opt: OptionButton
var _patch_btn: Button
var _offer_btn: Button
var _context_btn: Button
var _inspector_btn: Button
var _roll: SynthRoll
var _lane: SynthVelocityLane
var _playhead: SynthPlayhead
var _inspector: SynthPatternInspector
var _stage: Control
var _save_dialog: FileDialog
var _open_dialog: FileDialog
var _confirm: ConfirmationDialog

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _ready() -> void:
	_addon_dir = (get_script() as Script).resource_path.get_base_dir().get_base_dir()
	focus_mode = Control.FOCUS_CLICK
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)
	_build_header()
	_build_body()
	_build_dialogs()
	_built = true
	_relayout()
	_attach(_new_pattern(), "")

func _exit_tree() -> void:
	_unwatch()
	if _preview != null and _preview_is_own:
		_preview.stop()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _built:
		_relayout()

func _s() -> float:
	return SynthRackStyle.scale(self)

func _build_header() -> void:
	var s := _s()
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 8)
	bar.add_theme_constant_override("v_separation", 4)
	add_child(bar)

	_name_label = Label.new()
	_name_label.add_theme_font_size_override("font_size", 15)
	_name_label.custom_minimum_size.x = 120.0 * s
	bar.add_child(_name_label)
	_path_label = Label.new()
	_path_label.custom_minimum_size.x = 160.0 * s
	_path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_path_label.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	_path_label.mouse_filter = Control.MOUSE_FILTER_PASS
	bar.add_child(_path_label)

	for spec in [["New", "A new, empty pattern.", _on_new], ["Open...", "Open a MusicPattern file.", _on_open],
			["Save", "Save the pattern to its file.", _on_save], ["Save As...", "Save the pattern to a new file.", _on_save_as]]:
		var b := Button.new()
		b.text = spec[0]
		b.tooltip_text = spec[1]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(spec[2])
		bar.add_child(b)

	bar.add_child(_head_label("Type"))
	_type_opt = OptionButton.new()
	_type_opt.focus_mode = Control.FOCUS_NONE
	_type_opt.add_item("Auto", 0)
	_type_opt.add_item("Chord", 1)
	_type_opt.add_item("Melody", 2)
	_type_opt.add_item("Drum", 3)
	_type_opt.item_selected.connect(_on_type_selected)
	bar.add_child(_type_opt)

	bar.add_child(_head_label("Length"))
	_length_spin = SpinBox.new()
	_length_spin.min_value = 0.25
	_length_spin.max_value = 256.0
	_length_spin.step = 0.25
	_length_spin.suffix = "beats"
	_length_spin.custom_minimum_size.x = 120.0 * s
	_length_spin.tooltip_text = "How many beats before the pattern loops."
	_length_spin.value_changed.connect(_on_length_changed)
	bar.add_child(_length_spin)

	bar.add_child(_head_label("Snap"))
	_snap_opt = OptionButton.new()
	_snap_opt.focus_mode = Control.FOCUS_NONE
	_snap_opt.tooltip_text = "Grid step, as a fraction of a beat (1/4 = a sixteenth note; 1/3 and 1/6 are triplets)."
	for n in [1, 2, 3, 4, 6, 8, 16]:
		_snap_opt.add_item("1/%d" % n, n)
	_snap_opt.select(_snap_opt.get_item_index(4))
	_snap_opt.item_selected.connect(_on_snap_selected)
	bar.add_child(_snap_opt)

	bar.add_child(_head_label("Patch"))
	_patch_btn = Button.new()
	_patch_btn.flat = true
	_patch_btn.focus_mode = Control.FOCUS_NONE
	_patch_btn.tooltip_text = "The patch the pattern is heard through. Click to edit it in Sound."
	_patch_btn.add_theme_color_override("font_color", SynthRackStyle.accent(self))
	_patch_btn.pressed.connect(func(): sound_requested.emit())
	bar.add_child(_patch_btn)
	_offer_btn = Button.new()
	_offer_btn.focus_mode = Control.FOCUS_NONE
	_offer_btn.visible = false
	_offer_btn.pressed.connect(_on_offer_pressed)
	bar.add_child(_offer_btn)

	_context_btn = Button.new()
	_context_btn.text = "Other tracks"
	_context_btn.toggle_mode = true
	_context_btn.button_pressed = true
	_context_btn.focus_mode = Control.FOCUS_NONE
	_context_btn.disabled = true
	_context_btn.toggled.connect(func(_on): _refresh_faint())
	bar.add_child(_context_btn)

	var fit := Button.new()
	fit.text = "Fit"
	fit.focus_mode = Control.FOCUS_NONE
	fit.tooltip_text = "Fit the whole pattern into the width (Ctrl+wheel zooms time; Shift or Alt+wheel zooms rows)."
	fit.pressed.connect(func(): _roll.zoom_fit())
	bar.add_child(fit)

	_inspector_btn = Button.new()
	_inspector_btn.text = "Inspector"
	_inspector_btn.toggle_mode = true
	_inspector_btn.button_pressed = true
	_inspector_btn.focus_mode = Control.FOCUS_NONE
	_inspector_btn.tooltip_text = "Show or hide the inspector."
	_inspector_btn.toggled.connect(func(on: bool):
		_inspector_pref = 1 if on else 0
		_relayout())
	bar.add_child(_inspector_btn)

func _head_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	return l

func _build_body() -> void:
	var s := _s()
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	add_child(body)

	_stage = Control.new()
	_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stage.clip_contents = true
	body.add_child(_stage)
	var col := VBoxContainer.new()
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 0)
	_stage.add_child(col)
	_roll = SynthRoll.new()
	_roll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_roll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_roll)
	_lane = SynthVelocityLane.new()
	col.add_child(_lane)
	_lane.setup(_roll)
	_playhead = SynthPlayhead.new()
	_playhead.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_playhead.roll = _roll
	_playhead.lane = _lane
	_stage.add_child(_playhead)

	_roll.selection_changed.connect(_refresh_inspector)
	_roll.pattern_edited.connect(_on_roll_edited)
	_roll.edit_committed.connect(_on_edit_committed)
	_roll.note_auditioned.connect(_on_note_auditioned)
	_roll.row_auditioned.connect(_on_row_auditioned)
	_roll.seek_requested.connect(_on_seek)
	_roll.view_changed.connect(_playhead.queue_redraw)

	_inspector = SynthPatternInspector.new()
	_inspector.custom_minimum_size = Vector2(INSPECTOR_WIDTH * s, 0)
	_inspector.note_edited.connect(_on_note_field)
	_inspector.bend_edited.connect(_on_bend_field)
	_inspector.add_bend_requested.connect(func(): _roll.add_bend_at_mouse())
	_inspector.add_sub_bend_requested.connect(func(): _roll.add_bend_at_mouse())
	_inspector.remove_bend_requested.connect(func(): _roll.remove_selected_bend())
	_inspector.base_octave_edited.connect(_on_base_octave)
	body.add_child(_inspector)

func _build_dialogs() -> void:
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_RESOURCES
	_save_dialog.filters = PackedStringArray(["*.tres ; Pattern Resource"])
	_save_dialog.size = Vector2i(720, 520)
	_save_dialog.file_selected.connect(_on_save_path_chosen)
	_save_dialog.canceled.connect(func(): _after_save = Callable())
	add_child(_save_dialog)

	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_RESOURCES
	_open_dialog.filters = PackedStringArray(["*.tres ; Pattern Resource"])
	_open_dialog.size = Vector2i(720, 520)
	_open_dialog.file_selected.connect(_on_open_path_chosen)
	add_child(_open_dialog)

	_confirm = ConfirmationDialog.new()
	_confirm.title = "Unsaved changes"
	_confirm.ok_button_text = "Discard changes"
	_confirm.cancel_button_text = "Cancel"
	_confirm.add_button("Save", false, "save")
	_confirm.confirmed.connect(_on_confirm_discard)
	_confirm.canceled.connect(func(): _pending = Callable())
	_confirm.custom_action.connect(_on_confirm_custom)
	add_child(_confirm)

func _relayout() -> void:
	var show: bool = _inspector_pref == 1 or (_inspector_pref == -1 and size.x >= INSPECTOR_AUTO_HIDE * _s())
	_inspector.visible = show
	_inspector_btn.set_pressed_no_signal(show)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func get_roll() -> SynthRoll:
	return _roll

func get_lane() -> SynthVelocityLane:
	return _lane

func get_inspector() -> SynthPatternInspector:
	return _inspector

func get_playhead() -> SynthPlayhead:
	return _playhead

func get_preview() -> SynthPreview:
	return _preview

## The track type the rows are read as (MusicTrack.TrackType).
func get_effective_type() -> int:
	if pattern != null and int(pattern.editor_track_type) != AUTO:
		return int(pattern.editor_track_type)
	return _inferred.get("type", MusicTrack.TrackType.CHORD)

## Where the type came from, as the Type menu's tooltip says it.
func get_type_source() -> String:
	return _type_opt.tooltip_text

## The patch file the MusicTrack that plays this pattern pairs it with ("" if none).
func get_offer_path() -> String:
	return _offer_path

func is_dirty() -> bool:
	return pattern != null and SynthPatternSnapshot.fingerprint(pattern) != _clean_fp

func is_inspector_visible() -> bool:
	return _inspector.visible

## Edit [param p]; [param path] is its file ("" if it has none). Asks first when the
## pattern being edited has unsaved changes.
func open_pattern(p: MusicPattern, path: String = "") -> void:
	if p == null:
		return
	if p == pattern:
		current_path = path
		_refresh_header()
		return
	_guard(func(): _attach(p, path))

## Edit [param p] with no questions asked (the old PatternEditor's name).
func set_pattern(p: MusicPattern) -> void:
	_attach(p, current_path if p == pattern else "")

## Give the roll the keyboard focus (so Space, arrows and B work at once).
func focus_roll() -> void:
	if is_visible_in_tree():
		_roll.grab_focus()

## The song around the pattern: its other tracks draw faintly behind the roll.
func set_song_context(ctx: SynthSongContext) -> void:
	var changed := ctx != song_context
	song_context = ctx
	if not _built or pattern == null:
		return
	if changed and int(pattern.editor_track_type) == AUTO:
		_apply_type(true)
	else:
		_refresh_faint()
		_refresh_info()

# ---------------------------------------------------------------------------
# Attaching a pattern
# ---------------------------------------------------------------------------

func _new_pattern() -> MusicPattern:
	var p := MusicPattern.new()
	p.length_beats = 4.0
	return p

func _attach(p: MusicPattern, path: String) -> void:
	_unwatch()
	_audition_off()
	pattern = p
	current_path = path
	_roll.pattern = p
	_roll.snap_step = 1.0 / float(_snap_opt.get_selected_id())
	_apply_type(true, true)
	_clean_fp = SynthPatternSnapshot.fingerprint(p)
	_last_edited_flag = false
	_watch()
	_refresh_header()
	_refresh_inspector()
	if _preview != null:
		_preview.set_pattern(p)

# Work out the effective type (and everything that follows from it) and show it.
# [param infer]: look for the MusicTrack again. [param adopt]: a freshly opened
# pattern, so take the track's octave and offer its patch.
func _apply_type(infer: bool, adopt: bool = false) -> void:
	if infer:
		_inferred = _infer_type()
		var track: Dictionary = _inferred.get("track", {})
		_offer_path = track.get("patch_path", "")
		if adopt:
			base_octave = int(track["base_octave"]) if not track.is_empty() else 4
			if _preview != null:
				_preview.set_base_octave(base_octave)
		if adopt and _offer_path != "" and _shared_patch_is_empty():
			patch_requested.emit(_offer_path)
	var type := get_effective_type()
	_roll.track_type = type
	_roll.rows_per_octave = SynthPitchMap.rows_per_octave(type, _first_block())
	if _preview != null:
		_preview.set_track_type(type)
	_refresh_header()
	_refresh_faint()
	_refresh_info()

func _first_block() -> MusicBlock:
	var data := _data()
	return data.blocks[0] if data != null and not data.blocks.is_empty() else null

func _data() -> MusicData:
	if _preview != null:
		return _preview.get_effective_music_data()
	return SynthPreview.make_default_music_data()

# --- Type inference ----------------------------------------------------------

func _infer_type() -> Dictionary:
	var found := _find_track()
	if not found.is_empty():
		var t: Dictionary = found["track"]
		var ctx: SynthSongContext = found["ctx"]
		var others: PackedStringArray = PackedStringArray()
		for o in ctx.tracks_for(pattern):
			if o != t:
				others.append(str(o["name"]))
		var src := "From MusicTrack \"%s\" in %s: a %s track." % [
			t["name"], ctx.scene_path.get_file() if ctx.scene_path != "" else "the song context",
			SynthPitchMap.type_name(t["type"]).to_lower()]
		if not others.is_empty():
			src += " Also played by " + ", ".join(others) + "."
		return {"type": int(t["type"]), "source": src, "track": t, "ctx": ctx}
	# Nothing plays it: guess from the notes.
	var type := MusicTrack.TrackType.CHORD
	var why := "no notes yet, so the default (chord)"
	if not pattern.notes.is_empty():
		var all_drum := true
		var any_acc := false
		for n in pattern.notes:
			if n.index < 27:
				all_drum = false
			if n.accidental != 0.0:
				any_acc = true
		if all_drum:
			type = MusicTrack.TrackType.DRUM
			why = "every note is numbered 27 or higher, which only a drum track uses"
		elif any_acc:
			type = MusicTrack.TrackType.MELODY
			why = "some notes have accidentals, which only melody tracks use"
		else:
			why = "nothing marks it as melody or drum, so chord"
	return {"type": type, "source": "No MusicTrack in the project's scenes plays this pattern. Guessed from its notes: %s." % why}

# The MusicTrack that plays the pattern: in the song context first, then in any
# scene of the project that mentions the pattern's file. {"track", "ctx"} or {}.
func _find_track() -> Dictionary:
	if pattern == null:
		return {}
	if song_context != null:
		var t := song_context.track_for(pattern)
		if not t.is_empty():
			return {"track": t, "ctx": song_context}
	var keep_context := song_context != null and not song_context.inferred
	if current_path != "":
		for scene in _get_index().scenes_mentioning(current_path):
			if song_context != null and scene == song_context.scene_path:
				continue
			var ctx := SynthSongContext.read(scene)
			if ctx == null:
				continue
			var t2 := ctx.track_for(pattern)
			if t2.is_empty():
				continue
			ctx.inferred = true
			if not keep_context:
				song_context = ctx
				song_context_inferred.emit(ctx)
			return {"track": t2, "ctx": ctx}
	if song_context != null and song_context.inferred:
		song_context = null
		song_context_inferred.emit(null)
	return {}

func _get_index() -> SynthProjectIndex:
	if index == null:
		index = SynthProjectIndex.new()
		index.rescan(_addon_dir)
	return index

# --- Patch -------------------------------------------------------------------

func _shared_patch() -> SynthPatch:
	return _preview.patch if _preview != null else null

func _shared_patch_path() -> String:
	var p := _shared_patch()
	if p == null or p.resource_path == "" or "::" in p.resource_path:
		return ""
	return p.resource_path

# True when nothing was chosen yet: no patch, or the organ the tab starts with,
# unsaved and untouched.
func _shared_patch_is_empty() -> bool:
	if _preview == null:
		return false
	var p := _shared_patch()
	if p == null:
		return true
	if p.resource_path != "":
		return false
	var organ := SynthPatch.make_organ()
	return SynthSampleSet.fingerprint_patch(p) == SynthSampleSet.fingerprint_patch(organ) and p.patch_name == organ.patch_name

func _on_offer_pressed() -> void:
	if _offer_path != "":
		patch_requested.emit(_offer_path)

# ---------------------------------------------------------------------------
# Header + inspector readouts
# ---------------------------------------------------------------------------

func _refresh_header() -> void:
	if not _built or pattern == null:
		return
	var dirty := is_dirty()
	_name_label.text = (current_path.get_file().get_basename() if current_path != "" else "New pattern") + (" *" if dirty else "")
	_path_label.text = current_path if current_path != "" else "(unsaved)"
	_path_label.tooltip_text = current_path
	var hint := int(pattern.editor_track_type)
	_type_opt.set_item_text(0, "Auto (%s)" % SynthPitchMap.type_name(_inferred.get("type", 0)))
	_type_opt.select(_type_opt.get_item_index(hint + 1))
	_type_opt.tooltip_text = "Saved with the pattern (editor_track_type): %s." % SynthPitchMap.type_name(hint) \
			if hint != AUTO else _inferred.get("source", "")
	_length_spin.set_value_no_signal(pattern.length_beats)
	var p := _shared_patch()
	var ppath := _shared_patch_path()
	_patch_btn.text = ppath.get_file() if ppath != "" else ((p.patch_name + " (unsaved)") if p != null else "(none yet)")
	_patch_btn.tooltip_text = "The patch the pattern is heard through%s. Click to edit it in Sound." % \
			((": " + ppath) if ppath != "" else "")
	var offer_visible := _offer_path != "" and _offer_path != ppath
	_offer_btn.visible = offer_visible
	if offer_visible:
		_offer_btn.text = "Use %s" % _offer_path.get_file()
		_offer_btn.tooltip_text = "The MusicTrack that plays this pattern uses %s. Make it the current patch." % _offer_path
	_sync_edited_flag(dirty)

func _refresh_info() -> void:
	if not _built or pattern == null:
		return
	var type := get_effective_type()
	var hint := int(pattern.editor_track_type)
	_inspector.set_type_info("%s%s. %s" % [SynthPitchMap.type_name(type), "" if hint != AUTO else " (auto)", _type_opt.tooltip_text],
			_type_opt.tooltip_text)
	_inspector.set_base_octave(base_octave, type != MusicTrack.TrackType.DRUM)
	var track: Dictionary = _inferred.get("track", {})
	if not track.is_empty() and track["patch_path"] != "":
		_inspector.set_patch_info("Its MusicTrack plays it with %s on channel %d." % [str(track["patch_path"]).get_file(), track["channel"]])
	elif not track.is_empty():
		_inspector.set_patch_info("Its MusicTrack has no patch of its own.")
	else:
		_inspector.set_patch_info("")
	var counts := get_context_counts()
	var lines: Array = []
	for name in counts:
		lines.append({"name": name, "color": counts[name]["color"], "total": counts[name]["total"], "shown": counts[name]["shown"]})
	var header := ""
	if song_context != null:
		header = "Other tracks of %s%s, faint behind the roll:" % [
			song_context.scene_path.get_file(), " (found from this pattern)" if song_context.inferred else ""]
		if lines.is_empty():
			header = "%s has no other tracks." % song_context.scene_path.get_file()
	_inspector.set_context(lines, header)
	_context_btn.disabled = song_context == null
	_context_btn.tooltip_text = "Draw the other tracks of the song faintly behind this pattern." if song_context != null \
			else "No song context. Pick a music scene in Track, or open a pattern that a MusicTrack plays."

func _refresh_inspector() -> void:
	if not _built:
		return
	var e := _roll.get_selected_bend()
	if not e.is_empty():
		_inspector.show_bend(e["bend"])
	else:
		_inspector.show_notes(_roll.get_selected())

func _on_roll_edited() -> void:
	_refresh_inspector()

func _sync_edited_flag(dirty: bool) -> void:
	if dirty == _last_edited_flag:
		return
	_last_edited_flag = dirty
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface") and pattern != null:
		Engine.get_singleton(&"EditorInterface").call("set_object_edited", pattern, dirty)

# ---------------------------------------------------------------------------
# Other tracks, drawn faintly
# ---------------------------------------------------------------------------

func _refresh_faint() -> void:
	if not _built:
		return
	_faint_data = []
	_faint_counts = {}
	if song_context == null or pattern == null:
		_roll.set_faint([])
		return
	var data := _data()
	var type := get_effective_type()
	var length := pattern.length_beats
	var i := 0
	for t in song_context.tracks:
		var pat: MusicPattern = t["pattern"]
		var color: Color = FAINT_COLORS[i % FAINT_COLORS.size()]
		i += 1
		if pat == null or pat == pattern or (current_path != "" and t["pattern_path"] == current_path):
			continue
		var plen := maxf(pat.length_beats, 0.25)
		var list: Array = []
		var rep := 0
		while float(rep) * plen < length - 0.0001:
			for n in pat.notes:
				var beat: float = n.beat + float(rep) * plen
				if beat >= length - 0.0001:
					continue
				var block := SynthPitchMap.block_at(data, beat)
				var midi := SynthPitchMap.to_midi(t["type"], n.index, n.octave, n.accidental, t["base_octave"], block)
				list.append({"beat": beat, "dur": n.duration, "vel": n.velocity, "color": color,
						"row": SynthPitchMap.midi_to_row(type, midi, base_octave, block)})
			rep += 1
		_faint_data.append_array(list)
		_faint_counts[str(t["name"])] = {"color": color, "all": list}
	_roll.set_faint(_faint_data if _context_btn.button_pressed else [])

var _faint_data: Array = []
var _faint_counts: Dictionary = {}

## Per other track: {color, total, shown} where shown counts notes whose row is
## inside the roll's row range. Empty without a song context.
func get_context_counts() -> Dictionary:
	var out := {}
	for name in _faint_counts:
		var all: Array = _faint_counts[name]["all"]
		var shown := 0
		for f in all:
			if f["row"] >= _roll.row_lo and f["row"] <= _roll.row_hi:
				shown += 1
		out[name] = {"color": _faint_counts[name]["color"], "total": all.size(), "shown": shown}
	return out

# ---------------------------------------------------------------------------
# Watching the pattern for edits made elsewhere
# ---------------------------------------------------------------------------

func _watch() -> void:
	_unwatch()
	if pattern == null:
		return
	_watch_one(pattern)
	for n in pattern.notes:
		_watch_one(n)
		_watch_bends(n.bends)

func _watch_bends(bends: Array) -> void:
	for b in bends:
		_watch_one(b)
		_watch_bends(b.bends)

func _watch_one(r: Resource) -> void:
	if not r.changed.is_connected(_on_resource_changed):
		r.changed.connect(_on_resource_changed)
		_watched.append(r)

func _unwatch() -> void:
	for r in _watched:
		if is_instance_valid(r) and r.changed.is_connected(_on_resource_changed):
			r.changed.disconnect(_on_resource_changed)
	_watched.clear()

func _on_resource_changed() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	_deferred_refresh.call_deferred()

func _deferred_refresh() -> void:
	_refresh_queued = false
	if pattern == null or not _built:
		return
	_watch()
	_roll.refresh()
	_lane.queue_redraw()
	_playhead.queue_redraw()
	_apply_type(false)
	_refresh_inspector()

# ---------------------------------------------------------------------------
# Recording edits
# ---------------------------------------------------------------------------

func _on_edit_committed(label: String, before: SynthPatternSnapshot) -> void:
	_record(label, before, false)

## Make what was just done to the pattern one undo action. [param before] is the
## pattern as it was. [param merge]: fold into the previous action of the same
## name (spin-box clicks).
func _record(label: String, before: SynthPatternSnapshot, merge: bool) -> void:
	if pattern == null:
		return
	var after := SynthPatternSnapshot.capture(pattern)
	if before.same_as(after):
		return
	if undo_redo == null:
		pattern.emit_changed()
		return
	undo_redo.call("create_action", label, UndoRedo.MERGE_ENDS if merge else UndoRedo.MERGE_DISABLE, pattern)
	undo_redo.call("add_do_method", after, &"apply")
	undo_redo.call("add_undo_method", before, &"apply")
	undo_redo.call("add_do_reference", after)
	undo_redo.call("add_undo_reference", before)
	undo_redo.call("commit_action")

func _on_note_field(prop: StringName, value: float) -> void:
	var sel := _roll.get_selected()
	if sel.is_empty():
		return
	var before := SynthPatternSnapshot.capture(pattern)
	for n in sel:
		if prop == &"index" or prop == &"octave":
			n.set(prop, int(roundf(value)))
		elif prop == &"beat":
			n.beat = clampf(value, 0.0, 1024.0)
		else:
			n.set(prop, value)
	_record("Set note %s" % prop, before, true)

func _on_bend_field(prop: StringName, value: float) -> void:
	var e := _roll.get_selected_bend()
	if e.is_empty():
		return
	var before := SynthPatternSnapshot.capture(pattern)
	var b: PatternBend = e["bend"]
	if prop == &"index" or prop == &"octave":
		b.set(prop, int(roundf(value)))
	else:
		b.set(prop, value)
	_record("Set bend %s" % String(prop).replace("_beats", ""), before, true)

func _on_type_selected(idx: int) -> void:
	var hint := _type_opt.get_item_id(idx) - 1
	if pattern == null or hint == int(pattern.editor_track_type):
		return
	var before := SynthPatternSnapshot.capture(pattern)
	pattern.editor_track_type = hint
	_record("Set track type", before, false)

func _on_length_changed(v: float) -> void:
	if pattern == null or is_equal_approx(v, pattern.length_beats):
		return
	var before := SynthPatternSnapshot.capture(pattern)
	pattern.length_beats = v
	_record("Set pattern length", before, true)

func _on_snap_selected(_idx: int) -> void:
	_roll.snap_step = 1.0 / float(_snap_opt.get_selected_id())

func _on_base_octave(v: int) -> void:
	base_octave = v
	if _preview != null:
		_preview.set_base_octave(v)
		if _preview.is_playing():
			_preview.play_pattern(pattern, get_effective_type(), base_octave)
	_refresh_faint()
	_refresh_info()

# ---------------------------------------------------------------------------
# New / open / save
# ---------------------------------------------------------------------------

func _on_new() -> void:
	_guard(func(): _attach(_new_pattern(), ""))

func _on_open() -> void:
	_open_dialog.popup_centered()

func _on_open_path_chosen(path: String) -> void:
	var res := ResourceLoader.load(path)
	if res is MusicPattern:
		open_pattern(res, path)
	else:
		push_warning("[SynthPatternView] Not a MusicPattern: " + path)

func _on_save() -> void:
	if current_path == "":
		_on_save_as()
	else:
		save_to(current_path)

func _on_save_as() -> void:
	var dir := current_path.get_base_dir() if current_path != "" else "res://"
	_save_dialog.current_dir = dir
	_save_dialog.current_file = current_path.get_file() if current_path != "" else "pattern.tres"
	_save_dialog.popup_centered()

func _on_save_path_chosen(path: String) -> void:
	if not path.ends_with(".tres"):
		path += ".tres"
	var then := _after_save
	_after_save = Callable()
	if save_to(path) and then.is_valid():
		then.call()

## Write the pattern to [param path] and make that its file. False on failure.
func save_to(path: String) -> bool:
	if pattern == null:
		return false
	var err := ResourceSaver.save(pattern, path, ResourceSaver.FLAG_CHANGE_PATH)
	if err != OK:
		push_error("[SynthPatternView] Save failed: %s (err=%d)" % [path, err])
		return false
	current_path = path
	_clean_fp = SynthPatternSnapshot.fingerprint(pattern)
	_last_edited_flag = true     # force the editor's flag to be cleared below
	_sync_edited_flag(false)
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		var fs: Object = Engine.get_singleton(&"EditorInterface").call("get_resource_filesystem")
		fs.call("update_file", path)
		fs.call("scan")
	_refresh_header()
	return true

# Run [param then] now, or once the user has said what to do with unsaved edits.
func _guard(then: Callable) -> void:
	if pattern == null or not is_dirty():
		then.call()
		return
	_pending = then
	_confirm.dialog_text = "\"%s\" has unsaved changes.\n\nSave them, or discard them and carry on?" % \
			(current_path.get_file() if current_path != "" else "This pattern")
	_confirm.popup_centered()

func _on_confirm_discard() -> void:
	var then := _pending
	_pending = Callable()
	# A pattern loaded from a file is the editor's cached copy of that file:
	# edits that were not saved have to be taken back from disk.
	if current_path != "" and ResourceLoader.exists(current_path):
		ResourceLoader.load(current_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		pattern.emit_changed()
	_clean_fp = SynthPatternSnapshot.fingerprint(pattern)
	_sync_edited_flag(false)
	if then.is_valid():
		then.call()

func _on_confirm_custom(action: StringName) -> void:
	if action != &"save":
		return
	_confirm.hide()
	var then := _pending
	_pending = Callable()
	if current_path == "":
		_after_save = then
		_on_save_as()
	elif save_to(current_path) and then.is_valid():
		then.call()

# ---------------------------------------------------------------------------
# Preview: transport, playhead, audition
# ---------------------------------------------------------------------------

## Use a preview owned by someone else (the tab's shared one). Call after this
## view is in the tree.
func bind_preview(p: SynthPreview) -> void:
	_unhook_preview()
	if _preview != null and _preview_is_own:
		_preview.shutdown()
		_preview.queue_free()
	_preview = p
	_preview_is_own = false
	_hook_preview()

func _hook_preview() -> void:
	_preview.ensure_started()
	_preview.playing_changed.connect(_on_playing_changed)
	_preview.patch_changed.connect(_on_preview_patch_changed)
	_preview.music_data_changed.connect(_on_preview_data_changed)
	_playhead.director = _preview.director
	_preview.set_pattern(pattern)
	_preview.set_base_octave(base_octave)
	_preview.set_track_type(get_effective_type())
	_apply_type(false)

func _unhook_preview() -> void:
	if _preview == null:
		return
	if _preview.playing_changed.is_connected(_on_playing_changed):
		_preview.playing_changed.disconnect(_on_playing_changed)
	if _preview.patch_changed.is_connected(_on_preview_patch_changed):
		_preview.patch_changed.disconnect(_on_preview_patch_changed)
	if _preview.music_data_changed.is_connected(_on_preview_data_changed):
		_preview.music_data_changed.disconnect(_on_preview_data_changed)
	_playhead.director = null

func _ensure_preview() -> void:
	if _preview != null:
		_preview.ensure_started()
		return
	_preview = SynthPreview.new()
	_preview.name = "Preview"
	_preview_is_own = true
	add_child(_preview)
	_hook_preview()

func _on_playing_changed(_playing: bool) -> void:
	_playhead.queue_redraw()

func _on_preview_patch_changed(_p: SynthPatch) -> void:
	_refresh_header()

func _on_preview_data_changed(_d: MusicData) -> void:
	_apply_type(false)

func is_previewing() -> bool:
	return _preview != null and _preview.is_playing()

## Play the pattern through the preview, from the top of the progression.
func start_preview() -> void:
	if pattern == null:
		return
	_ensure_preview()
	_preview.play_pattern(pattern, get_effective_type(), base_octave)

func stop_preview() -> void:
	if _preview != null:
		_preview.stop()

func toggle_preview() -> void:
	if is_previewing():
		stop_preview()
	else:
		start_preview()

func _on_seek(beat: float) -> void:
	if _preview == null or _preview.director == null or pattern == null or pattern.length_beats <= 0.0:
		return
	var d := _preview.director
	var loop_index := floorf(d.get_total_beats() / pattern.length_beats)
	d.seek(loop_index * pattern.length_beats + beat)
	_playhead.queue_redraw()

func _on_note_auditioned(n: PatternNote) -> void:
	_audition(n.index, n.octave, n.accidental, n.velocity, n.beat)

func _on_row_auditioned(row: int) -> void:
	var type := get_effective_type()
	if type == MusicTrack.TrackType.DRUM:
		_audition(row, 0, 0.0, 0.8, 0.0)
	else:
		_audition(row, 0, 0.0, 0.8, 0.0)

# Play one note briefly through the shared preview, resolved as the track would.
func _audition(index_: int, octave: int, accidental: float, velocity: float, beat: float) -> void:
	if _preview == null or not _preview.is_started() or _preview.is_suspended():
		return
	var block := SynthPitchMap.block_at(_data(), beat)
	var midi := clampi(roundi(SynthPitchMap.to_midi(get_effective_type(), index_, octave, accidental, base_octave, block)), 0, 127)
	_preview.audition_note_on(midi, velocity, false)
	var ticket: int = _audition_tickets.get(midi, 0) + 1
	_audition_tickets[midi] = ticket
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = AUDITION_SECONDS
	t.timeout.connect(func():
		if _audition_tickets.get(midi, 0) == ticket and _preview != null and is_instance_valid(_preview):
			_preview.audition_note_off(midi)
		t.queue_free())
	add_child(t)
	t.start()

func _audition_off() -> void:
	_audition_tickets.clear()
	if _preview != null and _preview.is_started():
		_preview.audition_all_off()

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo or not is_visible_in_tree():
		return
	if k.keycode == KEY_SPACE and not (k.ctrl_pressed or k.alt_pressed or k.meta_pressed or k.shift_pressed) and _view_has_focus():
		toggle_preview()
		get_viewport().set_input_as_handled()

# The view has focus when the focused control is part of it and is not a text
# field (typing a number must not start the music).
func _view_has_focus() -> bool:
	var fo := get_viewport().gui_get_focus_owner()
	if fo == null or not (fo == self or is_ancestor_of(fo)):
		return false
	return not (fo is LineEdit or fo is TextEdit)

# A click on the view's empty space focuses the view (and so Space works).
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		grab_focus()
