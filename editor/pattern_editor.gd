@tool
extends PanelContainer

# Editor for MusicPattern resources. Top-level chrome around a
# PianoRoll: toolbar (new/load/save, track type, length, snap), a scroll
# container hosting the piano roll, and a footer panel with note
# properties for the currently selected note.
#
# Preview playback goes through a SynthPreview (one engine + director + track).
# Standalone (an F6 run, pattern_editor_demo.tscn) the editor builds its own on
# first Play. Hosted by the Synth tab it is handed the tab's shared one with
# bind_preview(), so the pattern is heard through the tab's current patch and
# music data, and the Data/Patch buttons here change that shared state.

const PianoRollScript := preload("./piano_roll.gd")
const DEFAULT_DATA_LABEL := "(default: 120 BPM, C major)"
const DEFAULT_PATCH_LABEL := "(default organ)"

## MusicData used when previewing the pattern. Assign a .tres in the
## inspector or via the toolbar button. Provides chord/scale context so
## CHORD and MELODY tracks resolve to real pitches. Null previews against a
## built-in default (120 BPM, C major) so Play always works. Used to seed the
## editor's own preview; when a shared preview is bound, that one decides.
@export var preview_music_data: MusicData

## SynthPatch (timbre) used for preview playback. Defaults to organ if null.
@export var preview_patch: SynthPatch

## Octave offset applied during preview. 4 = notes resolve around C4.
@export_range(0, 8) var preview_base_octave: int = 4

var pattern: MusicPattern
var current_path: String = ""

# The preview rig: bound from outside (shared) or built here on first use (own).
var _preview: SynthPreview
var _preview_is_own: bool = false

var _piano_roll: PianoRoll
var _track_type_option: OptionButton
var _length_spin: SpinBox
var _snap_option: OptionButton
var _path_label: Label
var _status_label: Label
var _save_dialog: FileDialog
var _load_dialog: FileDialog

var _play_btn: Button
var _data_btn: Button
var _data_label: Label
var _patch_btn: Button
var _patch_label: Label
var _octave_spin: SpinBox
var _data_dialog: FileDialog
var _patch_dialog: FileDialog

var _selected_note: PatternNote
var _selected_bend: PatternBend
var _selected_bend_parent_array: Array
var _selected_bend_note: PatternNote
var _footer_controls: Dictionary = {}
var _bend_controls: Dictionary = {}
var _note_footer: VBoxContainer
var _bend_footer: VBoxContainer
var _suppress: bool = false

func _ready() -> void:
	# Don't write layout into a scene that is merely open in the editor (it would
	# be saved with it); the Synth tab sizes this control itself.
	if not Engine.is_editor_hint():
		custom_minimum_size = Vector2(960, 520)
	_build_ui()
	if pattern == null:
		pattern = MusicPattern.new()
		pattern.length_beats = 8.0
	_piano_roll.pattern = pattern
	_refresh_toolbar()
	_refresh_footer()
	_refresh_preview_labels()

func set_pattern(p: MusicPattern) -> void:
	pattern = p
	_selected_note = null
	if _piano_roll:
		_piano_roll.pattern = p
	if _preview:
		_preview.set_pattern(p)
	_refresh_toolbar()
	_refresh_footer()

# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	_build_toolbar(root)
	_build_preview_bar(root)
	_build_body(root)
	_build_status(root)
	_build_dialogs()

func _build_toolbar(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	var new_btn := Button.new()
	new_btn.text = "New"
	new_btn.pressed.connect(_on_new)
	row.add_child(new_btn)

	var load_btn := Button.new()
	load_btn.text = "Load..."
	load_btn.pressed.connect(_on_load_pressed)
	row.add_child(load_btn)

	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.pressed.connect(_on_save)
	row.add_child(save_btn)

	var save_as_btn := Button.new()
	save_as_btn.text = "Save As..."
	save_as_btn.pressed.connect(_on_save_as)
	row.add_child(save_as_btn)

	row.add_child(VSeparator.new())

	row.add_child(_label("Type:"))
	_track_type_option = OptionButton.new()
	_track_type_option.add_item("Chord", MusicTrack.TrackType.CHORD)
	_track_type_option.add_item("Melody", MusicTrack.TrackType.MELODY)
	_track_type_option.add_item("Drum", MusicTrack.TrackType.DRUM)
	_track_type_option.item_selected.connect(_on_track_type_changed)
	row.add_child(_track_type_option)

	row.add_child(_label("Length:"))
	_length_spin = SpinBox.new()
	_length_spin.min_value = 0.25
	_length_spin.max_value = 256.0
	_length_spin.step = 0.25
	_length_spin.value = 4.0
	_length_spin.custom_minimum_size = Vector2(80, 0)
	_length_spin.value_changed.connect(_on_length_changed)
	row.add_child(_length_spin)

	row.add_child(_label("Snap:"))
	_snap_option = OptionButton.new()
	_snap_option.add_item("1/1", 1)
	_snap_option.add_item("1/2", 2)
	_snap_option.add_item("1/4", 4)
	_snap_option.add_item("1/8", 8)
	_snap_option.add_item("1/16", 16)
	_snap_option.select(2)
	_snap_option.item_selected.connect(_on_snap_changed)
	row.add_child(_snap_option)

	row.add_child(VSeparator.new())

	_path_label = Label.new()
	_path_label.text = "(unsaved)"
	_path_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	row.add_child(_path_label)

func _build_preview_bar(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)

	_play_btn = Button.new()
	_play_btn.text = "Play"
	_play_btn.custom_minimum_size = Vector2(60, 0)
	_play_btn.pressed.connect(_on_play_pressed)
	row.add_child(_play_btn)

	row.add_child(VSeparator.new())

	row.add_child(_label("Data:"))
	_data_btn = Button.new()
	_data_btn.text = "Load MusicData..."
	_data_btn.pressed.connect(func(): _data_dialog.popup_centered())
	_data_btn.tooltip_text = "Chord progression and tempo the pattern is previewed against."
	row.add_child(_data_btn)
	_data_label = Label.new()
	_data_label.text = _resource_label(preview_music_data, DEFAULT_DATA_LABEL)
	_data_label.add_theme_color_override("font_color", Color(0.70, 0.72, 0.78))
	row.add_child(_data_label)

	row.add_child(VSeparator.new())

	row.add_child(_label("Patch:"))
	_patch_btn = Button.new()
	_patch_btn.text = "Load Patch..."
	_patch_btn.pressed.connect(func(): _patch_dialog.popup_centered())
	row.add_child(_patch_btn)
	_patch_label = Label.new()
	_patch_label.text = _resource_label(preview_patch, DEFAULT_PATCH_LABEL)
	_patch_label.add_theme_color_override("font_color", Color(0.70, 0.72, 0.78))
	row.add_child(_patch_label)

	row.add_child(VSeparator.new())

	row.add_child(_label("Octave:"))
	_octave_spin = SpinBox.new()
	_octave_spin.min_value = 0
	_octave_spin.max_value = 8
	_octave_spin.step = 1
	_octave_spin.value = preview_base_octave
	_octave_spin.custom_minimum_size = Vector2(60, 0)
	_octave_spin.value_changed.connect(_on_octave_changed)
	row.add_child(_octave_spin)

func _resource_label(res: Resource, fallback: String) -> String:
	if res == null:
		return fallback
	if res.resource_path != "":
		return res.resource_path.get_file()
	return "(inline)"

func _build_body(parent: VBoxContainer) -> void:
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	parent.add_child(body)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)

	_piano_roll = PianoRollScript.new()
	_piano_roll.selection_changed.connect(_on_selection_changed)
	_piano_roll.bend_selection_changed.connect(_on_bend_selection_changed)
	_piano_roll.pattern_changed.connect(_on_pattern_changed)
	scroll.add_child(_piano_roll)

	var footer := VBoxContainer.new()
	footer.custom_minimum_size = Vector2(220, 0)
	footer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	footer.add_theme_constant_override("separation", 4)
	body.add_child(footer)

	# --- Note properties panel ----------------------------------------
	_note_footer = VBoxContainer.new()
	_note_footer.add_theme_constant_override("separation", 4)
	footer.add_child(_note_footer)
	_note_footer.add_child(_label("Note properties"))
	_add_footer_spin(_note_footer, "index", "Index", -48, 48, 1)
	_add_footer_spin(_note_footer, "octave", "Octave", -4, 4, 1)
	_add_footer_spin(_note_footer, "accidental", "Accidental", -12.0, 12.0, 0.01)
	_add_footer_spin(_note_footer, "beat", "Beat", 0.0, 256.0, 0.01)
	_add_footer_spin(_note_footer, "duration", "Duration", 0.01, 64.0, 0.01)
	_add_footer_slider(_note_footer, "velocity", "Velocity", 0.0, 1.0, 0.01)
	var add_bend_btn := Button.new()
	add_bend_btn.text = "+ Bend"
	add_bend_btn.pressed.connect(_on_add_bend_pressed)
	_note_footer.add_child(add_bend_btn)

	# --- Bend properties panel (hidden until a bend is selected) -------
	_bend_footer = VBoxContainer.new()
	_bend_footer.add_theme_constant_override("separation", 4)
	_bend_footer.visible = false
	footer.add_child(_bend_footer)
	_bend_footer.add_child(_label("Bend properties"))
	_add_bend_spin("offset_beats", "Offset", 0.0, 64.0, 0.01)
	_add_bend_spin("glide_beats", "Glide", 0.0, 64.0, 0.01)
	_add_bend_spin("index", "Index", -48.0, 48.0, 1.0)
	_add_bend_spin("octave", "Octave", -4.0, 4.0, 1.0)
	_add_bend_spin("accidental", "Accidental", -12.0, 12.0, 0.01)
	var add_sub_btn := Button.new()
	add_sub_btn.text = "+ Sub-bend"
	add_sub_btn.pressed.connect(_on_add_sub_bend_pressed)
	_bend_footer.add_child(add_sub_btn)

func _add_bend_spin(prop: String, label: String, mn: float, mx: float, step: float) -> void:
	var row := HBoxContainer.new()
	_bend_footer.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(80, 0)
	row.add_child(lbl)
	var sp := SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = step
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.value_changed.connect(_on_bend_footer_edited.bind(prop))
	row.add_child(sp)
	_bend_controls[prop] = sp

func _add_footer_spin(parent: VBoxContainer, prop: String, label: String, mn: float, mx: float, step: float) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(80, 0)
	row.add_child(lbl)
	var sp := SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = step
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.value_changed.connect(_on_footer_edited.bind(prop))
	row.add_child(sp)
	_footer_controls[prop] = sp

func _add_footer_slider(parent: VBoxContainer, prop: String, label: String, mn: float, mx: float, step: float) -> void:
	var col := VBoxContainer.new()
	parent.add_child(col)
	var row := HBoxContainer.new()
	col.add_child(row)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(80, 0)
	row.add_child(lbl)
	var val_label := Label.new()
	val_label.text = "0.00"
	val_label.custom_minimum_size = Vector2(40, 0)
	row.add_child(val_label)
	var sl := HSlider.new()
	sl.min_value = mn
	sl.max_value = mx
	sl.step = step
	sl.value_changed.connect(_on_footer_edited.bind(prop))
	sl.value_changed.connect(func(v: float): val_label.text = "%.2f" % v)
	col.add_child(sl)
	_footer_controls[prop] = sl

func _build_status(parent: VBoxContainer) -> void:
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.add_theme_color_override("font_color", Color(0.70, 0.72, 0.78))
	parent.add_child(_status_label)

func _build_dialogs() -> void:
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_RESOURCES
	_save_dialog.filters = PackedStringArray(["*.tres ; Pattern Resource"])
	_save_dialog.size = Vector2i(720, 520)
	_save_dialog.file_selected.connect(_on_save_path_chosen)
	add_child(_save_dialog)

	_load_dialog = FileDialog.new()
	_load_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_load_dialog.access = FileDialog.ACCESS_RESOURCES
	_load_dialog.filters = PackedStringArray(["*.tres ; Pattern Resource"])
	_load_dialog.size = Vector2i(720, 520)
	_load_dialog.file_selected.connect(_on_load_path_chosen)
	add_child(_load_dialog)

	_data_dialog = FileDialog.new()
	_data_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_data_dialog.access = FileDialog.ACCESS_RESOURCES
	_data_dialog.filters = PackedStringArray(["*.tres ; MusicData Resource"])
	_data_dialog.size = Vector2i(720, 520)
	_data_dialog.file_selected.connect(_on_data_path_chosen)
	add_child(_data_dialog)

	_patch_dialog = FileDialog.new()
	_patch_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_patch_dialog.access = FileDialog.ACCESS_RESOURCES
	_patch_dialog.filters = PackedStringArray(["*.tres ; SynthPatch Resource"])
	_patch_dialog.size = Vector2i(720, 520)
	_patch_dialog.file_selected.connect(_on_patch_path_chosen)
	add_child(_patch_dialog)

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------

func _refresh_toolbar() -> void:
	if pattern == null:
		return
	_suppress = true
	_length_spin.value = pattern.length_beats
	_path_label.text = current_path if current_path != "" else "(unsaved)"
	_suppress = false

func _refresh_footer() -> void:
	_suppress = true
	# Toggle panel visibility based on which (if any) thing is selected.
	# Bend selection wins because the piano roll clears note selection
	# when a bend is picked.
	_bend_footer.visible = _selected_bend != null
	_note_footer.visible = _selected_bend == null
	var enabled: bool = _selected_note != null
	for prop in _footer_controls.keys():
		var c: Control = _footer_controls[prop]
		if c is SpinBox:
			(c as SpinBox).editable = enabled
		elif c is HSlider:
			(c as HSlider).editable = enabled
	if _selected_note != null:
		(_footer_controls["index"] as SpinBox).value = _selected_note.index
		(_footer_controls["octave"] as SpinBox).value = _selected_note.octave
		(_footer_controls["accidental"] as SpinBox).value = _selected_note.accidental
		(_footer_controls["beat"] as SpinBox).value = _selected_note.beat
		(_footer_controls["duration"] as SpinBox).value = _selected_note.duration
		(_footer_controls["velocity"] as HSlider).value = _selected_note.velocity
	if _selected_bend != null:
		(_bend_controls["offset_beats"] as SpinBox).value = _selected_bend.offset_beats
		(_bend_controls["glide_beats"] as SpinBox).value = _selected_bend.glide_beats
		(_bend_controls["index"] as SpinBox).value = _selected_bend.index
		(_bend_controls["octave"] as SpinBox).value = _selected_bend.octave
		(_bend_controls["accidental"] as SpinBox).value = _selected_bend.accidental
	_suppress = false
	_update_status()

func _update_status() -> void:
	if pattern == null:
		_status_label.text = ""
		return
	var n: int = pattern.notes.size()
	var sel: String = ""
	if _piano_roll != null:
		var sel_count: int = _piano_roll.get_selected().size()
		if sel_count > 1:
			sel = "  •  %d notes selected (footer edits first)" % sel_count
		elif _selected_note != null:
			sel = "  •  Selected: beat %.2f, index %d, dur %.2f" % [
				_selected_note.beat, _selected_note.index, _selected_note.duration
			]
	_status_label.text = "Length: %.2f beats  •  Notes: %d%s" % [pattern.length_beats, n, sel]

# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_selection_changed(selected: Array) -> void:
	_selected_note = selected[0] if selected.size() > 0 else null
	# Selecting a note clears any pre-existing bend selection (piano roll
	# already does this internally, but mirror it here so the panels swap).
	if _selected_note != null:
		_selected_bend = null
		_selected_bend_parent_array = []
		_selected_bend_note = null
	_refresh_footer()

func _on_bend_selection_changed(bend: PatternBend, parent_note: PatternNote) -> void:
	_selected_bend = bend
	_selected_bend_note = parent_note
	# We don't get the parent_array via signal — query the piano roll, which
	# tracks it internally. (`add_bend` calls into the roll which knows.)
	_selected_bend_parent_array = _piano_roll._selected_bend_parent_array if bend != null else []
	_refresh_footer()

func _on_pattern_changed() -> void:
	_refresh_footer()

func _on_track_type_changed(idx: int) -> void:
	_piano_roll.track_type = _track_type_option.get_item_id(idx)
	if _preview:
		_preview.set_track_type(_piano_roll.track_type)

func _on_length_changed(v: float) -> void:
	if _suppress or pattern == null:
		return
	pattern.length_beats = v
	_piano_roll.refresh()
	_update_status()

func _on_snap_changed(idx: int) -> void:
	_piano_roll.grid_subdivisions = _snap_option.get_item_id(idx)

func _on_footer_edited(value: float, prop: String) -> void:
	if _suppress or _selected_note == null:
		return
	# accidental is float (microtonal); beat/duration/velocity always float.
	if prop in ["velocity", "beat", "duration", "accidental"]:
		_selected_note.set(prop, value)
	else:
		_selected_note.set(prop, int(value))
	_piano_roll.refresh()
	_update_status()

func _on_bend_footer_edited(value: float, prop: String) -> void:
	if _suppress or _selected_bend == null:
		return
	# Float props (continuous time / pitch); int props (index/octave snap).
	if prop in ["offset_beats", "glide_beats", "accidental"]:
		_selected_bend.set(prop, value)
	else:
		_selected_bend.set(prop, int(value))
	_piano_roll.refresh()
	_update_status()

func _on_add_bend_pressed() -> void:
	if _selected_note == null:
		return
	# Target = a couple rows above the note for an audible upward bend by default.
	var target_idx: int = _selected_note.index + 2
	_piano_roll.add_bend(_selected_note.bends, _selected_note, target_idx)

func _on_add_sub_bend_pressed() -> void:
	if _selected_bend == null:
		return
	var target_idx: int = _selected_bend.index + 2
	_piano_roll.add_bend(_selected_bend.bends, _selected_bend_note, target_idx)

# ---------------------------------------------------------------------------
# New / Load / Save
# ---------------------------------------------------------------------------

func _on_new() -> void:
	var p := MusicPattern.new()
	p.length_beats = 4.0
	current_path = ""
	set_pattern(p)

func _on_load_pressed() -> void:
	_load_dialog.popup_centered()

func _on_save() -> void:
	if current_path == "":
		_on_save_as()
		return
	_save_to_path(current_path)

func _on_save_as() -> void:
	_save_dialog.current_file = "pattern.tres"
	_save_dialog.popup_centered()

func _on_save_path_chosen(path: String) -> void:
	if not path.ends_with(".tres"):
		path += ".tres"
	_save_to_path(path)
	current_path = path
	_path_label.text = path

func _save_to_path(path: String) -> void:
	if pattern == null:
		return
	var err := ResourceSaver.save(pattern, path)
	if err == OK:
		print("[PatternEditor] Saved: ", path)
	else:
		push_error("[PatternEditor] Save failed: %s (err=%d)" % [path, err])

func _on_load_path_chosen(path: String) -> void:
	var res := load(path)
	if res is MusicPattern:
		current_path = path
		_path_label.text = path
		set_pattern(res)
	else:
		push_warning("[PatternEditor] Not a MusicPattern: " + path)

# ---------------------------------------------------------------------------
# Preview playback
# ---------------------------------------------------------------------------

## Use a preview owned by someone else (the Synth tab's shared one) instead of
## building a private one. Call after this node is in the tree, with a preview
## that ensure_started() has already run on.
func bind_preview(p: SynthPreview) -> void:
	_unbind_preview()
	if _preview != null and _preview_is_own:
		_preview.shutdown()
		_preview.queue_free()
	_preview = p
	_preview_is_own = false
	_hook_preview()
	_refresh_preview_labels()

func _unbind_preview() -> void:
	if _preview == null:
		return
	if _preview.playing_changed.is_connected(_on_preview_playing_changed):
		_preview.playing_changed.disconnect(_on_preview_playing_changed)
	if _preview.patch_changed.is_connected(_on_preview_patch_changed):
		_preview.patch_changed.disconnect(_on_preview_patch_changed)
	if _preview.music_data_changed.is_connected(_on_preview_data_changed):
		_preview.music_data_changed.disconnect(_on_preview_data_changed)
	if _piano_roll != null and _piano_roll.director == _preview.director:
		_piano_roll.director = null

func _hook_preview() -> void:
	_preview.playing_changed.connect(_on_preview_playing_changed)
	_preview.patch_changed.connect(_on_preview_patch_changed)
	_preview.music_data_changed.connect(_on_preview_data_changed)
	_preview.ensure_started()
	_piano_roll.director = _preview.director
	_preview.set_pattern(pattern)

# Build this editor's own preview, seeded from the exports. Only used when
# nothing was bound.
func _ensure_preview() -> void:
	if _preview != null:
		_preview.ensure_started()
		return
	_preview = SynthPreview.new()
	_preview.name = "Preview"
	_preview_is_own = true
	_preview.music_data = preview_music_data
	_preview.patch = preview_patch
	add_child(_preview)
	_hook_preview()
	_preview.set_base_octave(preview_base_octave)
	_preview.set_track_type(_piano_roll.track_type)

func _refresh_preview_labels() -> void:
	if _data_label == null:
		return
	var data: MusicData = preview_music_data
	var pt: SynthPatch = preview_patch
	if _preview != null:
		data = _preview.music_data
		pt = _preview.patch
	_data_label.text = _resource_label(data, DEFAULT_DATA_LABEL)
	_patch_label.text = _resource_label(pt, DEFAULT_PATCH_LABEL)

func _on_preview_playing_changed(_playing: bool) -> void:
	_update_play_button()

func _on_preview_patch_changed(_p: SynthPatch) -> void:
	_refresh_preview_labels()

func _on_preview_data_changed(_d: MusicData) -> void:
	_refresh_preview_labels()

func _on_data_path_chosen(path: String) -> void:
	var res := load(path)
	if res is MusicData:
		preview_music_data = res
		_ensure_preview()
		_preview.set_music_data(res)
		_refresh_preview_labels()
	else:
		push_warning("[PatternEditor] Not a MusicData: " + path)

func _on_patch_path_chosen(path: String) -> void:
	var res := load(path)
	if res is SynthPatch:
		preview_patch = res
		_ensure_preview()
		_preview.set_patch(res)
		_refresh_preview_labels()
	else:
		push_warning("[PatternEditor] Not a SynthPatch: " + path)

func _on_octave_changed(v: float) -> void:
	preview_base_octave = int(v)
	if _preview:
		_preview.set_base_octave(preview_base_octave)

func _on_play_pressed() -> void:
	if is_previewing():
		stop_preview()
	else:
		start_preview()

func is_previewing() -> bool:
	return _preview != null and _preview.is_playing()

func _update_play_button() -> void:
	if _play_btn != null:
		_play_btn.text = "Stop" if is_previewing() else "Play"

## Play the pattern through the preview, from the top of the progression.
func start_preview() -> void:
	if pattern == null:
		push_warning("[PatternEditor] No pattern to preview.")
		return
	_ensure_preview()
	_preview.play_pattern(pattern, _piano_roll.track_type, preview_base_octave)
	_update_play_button()

func stop_preview() -> void:
	if _preview != null:
		_preview.stop()
	_update_play_button()

func _exit_tree() -> void:
	if _preview != null and _preview_is_own:
		_preview.stop()
