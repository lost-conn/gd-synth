@tool
class_name SynthPatchRack
extends VBoxContainer

# The Synth tab's Sound view: a patch rack.
#
#   top      patch name, file path, New / Save / Save As, and the Live / Baked
#            switch that decides what the keyboard plays
#   left     the patch browser: every SynthPatch file in the project, and the
#            factory presets to start a new patch from
#   centre   one card per module of the patch (oscillator, amp envelope, filter,
#            FM and modulation, pitch drop, noise), each with a small live picture
#            and labelled sliders. Every SynthPatch export is on exactly one card.
#   bottom   an audition keyboard (click, or A-K while this view has focus)
#
# The view edits the patch object in place, so the engine, the Pattern view and the
# Inspector all see edits as they happen. Every edit is recorded in the editor's
# undo history (one slider drag = one action), and an edit made anywhere else
# (the Inspector, Ctrl+Z) shows up here through the patch's `changed` signal.
#
# Audition: LIVE plays the patch on the shared preview's SynthEngine. BAKED plays
# the patch's baked SynthSampleSet on the preview's SynthSampler, which is what the
# game does, so it is also how to hear a stale bake. The bake status (up to date,
# stale, none) is shown by the host through bake_status_changed.

## The patch the view edits changed (opened, new, preset). Not for each edit.
signal patch_changed(patch: SynthPatch)
## Text, tooltip and colour for the bake chip in the tab's top bar.
signal bake_status_changed(text: String, tooltip: String, color: Color)

const CARD_MIN_WIDTH := 270.0
const GRID_GAP := 10.0
const BROWSER_WIDTH := 236.0
# Below this width (editor scale 1) the browser folds away unless asked for.
const BROWSER_AUTO_HIDE := 760.0

# Computer keys, by physical key: semitones above the keyboard's second C.
const KEY_MAP := {
	KEY_A: 0, KEY_W: 1, KEY_S: 2, KEY_E: 3, KEY_D: 4, KEY_F: 5, KEY_T: 6, KEY_G: 7,
	KEY_Y: 8, KEY_H: 9, KEY_U: 10, KEY_J: 11, KEY_K: 12, KEY_O: 13, KEY_L: 14, KEY_P: 15,
	KEY_SEMICOLON: 16,
}

## The shared preview rig: where the keyboard's notes are played, and which patch
## the other views hear. Set by the host before the view is used.
var preview: SynthPreview
## The editor's EditorUndoRedoManager (EditorPlugin.get_undo_redo()). Null outside
## the editor: edits are then applied directly, with no history.
var undo_redo: Object
var patch: SynthPatch
## File the patch was loaded from / last saved to ("" = unsaved).
var current_path: String = ""
var audition_baked: bool = false
var bake_info: SynthBakeInfo.Info
var index := SynthProjectIndex.new()

var _rows: Dictionary = {}          # prop -> SynthRackParam
var _cards: Dictionary = {}         # id -> SynthRackCard
var _graphs: Array[SynthRackGraph] = []
var _wave_graph: SynthRackGraph
var _waveform_seg: SynthSegmented
var _filter_seg: SynthSegmented
var _harm: SynthHarmonicsEditor
var _name_edit: LineEdit
var _path_label: Label
var _audition_seg: SynthSegmented
var _browser_btn: Button
var _browser_panel: Control
var _browser: SynthPatchBrowser
var _scroll: ScrollContainer
var _grid: GridContainer
var _keys: SynthKeyboard
var _oct_label: Label
var _vel_slider: HSlider
var _vel_label: Label
var _save_dialog: FileDialog
var _confirm: ConfirmationDialog
var _reindex_timer: Timer

var _clean_fp: String = ""
var _last_edited_flag: bool = false
var _refresh_queued: bool = false
var _pending: Callable = Callable()
var _after_save: Callable = Callable()
var _kb_held: Dictionary = {}       # physical keycode -> midi note
var _browser_pref: int = -1         # -1 auto, 0 hidden, 1 shown
var _addon_dir: String = ""
var _built: bool = false

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _ready() -> void:
	_addon_dir = (get_script() as Script).resource_path.get_base_dir().get_base_dir()
	focus_mode = Control.FOCUS_CLICK
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	_build_bar()
	_build_middle()
	_build_keyboard()
	_build_dialogs()
	_built = true

	_reindex_timer = Timer.new()
	_reindex_timer.one_shot = true
	_reindex_timer.wait_time = 0.4
	_reindex_timer.timeout.connect(_reindex.bind(true))
	add_child(_reindex_timer)
	var fs := _editor_fs()
	if fs != null:
		fs.connect("filesystem_changed", _on_filesystem_changed)
	index.refs_ready.connect(_on_refs_ready)
	_reindex(false)

	_browser.index = index
	if patch != null:
		_attach(patch)
	_relayout()

func _exit_tree() -> void:
	var fs := _editor_fs()
	if fs != null and fs.is_connected("filesystem_changed", _on_filesystem_changed):
		fs.disconnect("filesystem_changed", _on_filesystem_changed)
	_release_all()
	if patch != null and patch.changed.is_connected(_on_patch_changed):
		patch.changed.disconnect(_on_patch_changed)

static func _editor_fs() -> Object:
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		return Engine.get_singleton(&"EditorInterface").call("get_resource_filesystem")
	return null

func _build_bar() -> void:
	var s := SynthRackStyle.scale(self)
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 8)
	bar.add_theme_constant_override("v_separation", 4)
	add_child(bar)

	_browser_btn = Button.new()
	_browser_btn.text = "Patches"
	_browser_btn.toggle_mode = true
	_browser_btn.button_pressed = true
	_browser_btn.focus_mode = Control.FOCUS_NONE
	_browser_btn.tooltip_text = "Show or hide the patch browser."
	_browser_btn.toggled.connect(_on_browser_toggled)
	bar.add_child(_browser_btn)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "Patch name"
	_name_edit.custom_minimum_size = Vector2(170.0 * s, 0)
	_name_edit.tooltip_text = "The patch's name (patch_name). Shown here and used as the default file name."
	_name_edit.text_changed.connect(_on_name_changed)
	bar.add_child(_name_edit)

	_path_label = Label.new()
	_path_label.custom_minimum_size = Vector2(200.0 * s, 0)
	_path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_path_label.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	_path_label.mouse_filter = Control.MOUSE_FILTER_PASS
	bar.add_child(_path_label)

	for spec in [["New", "A new, blank patch.", _on_new], ["Save", "Save the patch to its file.", _on_save],
			["Save As...", "Save the patch to a new file.", _on_save_as]]:
		var b := Button.new()
		b.text = spec[0]
		b.tooltip_text = spec[1]
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(spec[2])
		bar.add_child(b)

	var al := Label.new()
	al.text = "Audition"
	bar.add_child(al)
	_audition_seg = SynthSegmented.new()
	_audition_seg.setup([
		["Live", 0, "Play keys on the synth engine, with the patch as it is now."],
		["Baked", 1, "Play keys on the baked sample set, as the game does."],
	])
	_audition_seg.set_selected_no_signal(0)
	_audition_seg.selected.connect(_on_audition_selected)
	bar.add_child(_audition_seg)

func _build_middle() -> void:
	var s := SynthRackStyle.scale(self)
	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 10)
	add_child(mid)

	_browser_panel = PanelContainer.new()
	_browser_panel.custom_minimum_size = Vector2(BROWSER_WIDTH * s, 0)
	_browser_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_browser_panel.add_theme_stylebox_override("panel", SynthRackStyle.make_card_style(self))
	mid.add_child(_browser_panel)
	_browser = SynthPatchBrowser.new()
	_browser.patch_chosen.connect(_on_browser_patch)
	_browser.preset_chosen.connect(_on_preset)
	_browser_panel.add_child(_browser)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO  # the grid sizes itself to the width; AUTO keeps the scroll from demanding the grid's minimum
	_scroll.resized.connect(_relayout)
	mid.add_child(_scroll)

	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", int(GRID_GAP * s))
	_grid.add_theme_constant_override("v_separation", int(GRID_GAP * s))
	_scroll.add_child(_grid)

	_build_oscillator_card()
	_build_amp_card()
	_build_filter_card()
	_build_mod_card()
	_build_pitch_card()
	_build_noise_card()

func _new_card(id: StringName, title: String, tag: String) -> SynthRackCard:
	var c := SynthRackCard.new(title, tag)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_FILL
	c.custom_minimum_size = Vector2(CARD_MIN_WIDTH * SynthRackStyle.scale(self), 0)
	_grid.add_child(c)
	_cards[id] = c
	return c

func _add_graph(card: SynthRackCard, kind: int, height: float, prefix: String = "") -> SynthRackGraph:
	var g := SynthRackGraph.new(kind, height)
	g.env_prefix = prefix
	card.body.add_child(g)
	_graphs.append(g)
	return g

# opts: see SynthRackParam.setup. A property with no @export_range of its own is
# open_max: the field accepts a value above the slider's end.
func _add_row(card: SynthRackCard, prop: StringName, label: String, mn: float, mx: float,
		step: float, opts: Dictionary = {}) -> SynthRackParam:
	var r := SynthRackParam.new()
	r.setup(prop, label, mn, mx, step, opts)
	r.live.connect(_on_row_live)
	r.committed.connect(_on_row_committed)
	card.body.add_child(r)
	_rows[prop] = r
	return r

func _build_oscillator_card() -> void:
	var c := _new_card(&"oscillator", "Oscillator", "Source")
	_wave_graph = _add_graph(c, SynthRackGraph.Kind.WAVE, 56)
	_waveform_seg = SynthSegmented.new()
	_waveform_seg.setup([
		["Additive", SynthPatch.Waveform.ADDITIVE, "Sum of sine partials, set below."],
		["Sine", SynthPatch.Waveform.SINE], ["Square", SynthPatch.Waveform.SQUARE],
		["Saw", SynthPatch.Waveform.SAW], ["Tri", SynthPatch.Waveform.TRIANGLE, "Triangle"],
	])
	_waveform_seg.selected.connect(func(id): _commit(&"waveform", id, patch.waveform))
	c.body.add_child(_waveform_seg)
	_harm = SynthHarmonicsEditor.new()
	_harm.live.connect(_on_row_live)
	_harm.committed.connect(_on_row_committed)
	c.body.add_child(_harm)
	_add_row(c, &"gain", "Gain", 0.0, 1.0, 0.001, {"open_max": true,
		"tip": "Output level of this patch. Stacks with the engine's master gain."})

func _build_amp_card() -> void:
	var c := _new_card(&"amp", "Amp envelope", "Amp")
	_add_graph(c, SynthRackGraph.Kind.ENVELOPE, 64)
	_add_row(c, &"attack", "Attack", 0.0, 3.0, 0.001, {"suffix": "s", "exp": true, "open_max": true,
		"tip": "Seconds from note-on to full level."})
	_add_row(c, &"decay", "Decay", 0.0, 3.0, 0.001, {"suffix": "s", "exp": true, "open_max": true,
		"tip": "Seconds from full level down to the sustain level."})
	_add_row(c, &"sustain", "Sustain", 0.0, 1.0, 0.001,
		{"tip": "Level held while the note is down. 0 makes a percussive, self-ending sound."})
	_add_row(c, &"release", "Release", 0.0, 3.0, 0.001, {"suffix": "s", "exp": true, "open_max": true,
		"tip": "Seconds to fade out after note-off."})

func _build_filter_card() -> void:
	var c := _new_card(&"filter", "Filter", "Tone")
	_add_graph(c, SynthRackGraph.Kind.FILTER, 72)
	_filter_seg = SynthSegmented.new()
	_filter_seg.setup([
		["Off", SynthPatch.FilterType.OFF], ["LP", SynthPatch.FilterType.LOWPASS, "Lowpass"],
		["HP", SynthPatch.FilterType.HIGHPASS, "Highpass"], ["BP", SynthPatch.FilterType.BANDPASS, "Bandpass"],
	])
	_filter_seg.selected.connect(func(id): _commit(&"filter_type", id, patch.filter_type))
	c.body.add_child(_filter_seg)
	_add_row(c, &"filter_cutoff", "Cutoff", 0.0, 1.0, 0.001,
		{"tip": "0 to 1, log-mapped to 20 Hz - 20 kHz. The envelope moves it from here."})
	_add_row(c, &"filter_resonance", "Resonance", 0.0, 1.0, 0.001,
		{"tip": "0 = gentle slope, 1 = ringing at the cutoff. High values can clip; lower the gain."})
	_add_row(c, &"filter_env_amount", "Env amount", -1.0, 1.0, 0.001,
		{"tip": "How far the filter envelope opens (+) or closes (-) the cutoff on note-on."})
	c.add_section("Filter envelope")
	_add_graph(c, SynthRackGraph.Kind.ENVELOPE, 48, "filter_")
	_add_row(c, &"filter_attack", "Attack", 0.0, 3.0, 0.001, {"suffix": "s", "exp": true, "open_max": true})
	_add_row(c, &"filter_decay", "Decay", 0.0, 3.0, 0.001, {"suffix": "s", "exp": true, "open_max": true})
	_add_row(c, &"filter_sustain", "Sustain", 0.0, 1.0, 0.001)
	_add_row(c, &"filter_release", "Release", 0.0, 3.0, 0.001, {"suffix": "s", "exp": true, "open_max": true})

func _build_mod_card() -> void:
	var c := _new_card(&"mod", "FM and modulation", "Mod")
	_add_graph(c, SynthRackGraph.Kind.FM, 56)
	c.add_section("FM")
	_add_row(c, &"fm_ratio", "Ratio", 0.0, 16.0, 0.01, {"open_max": true,
		"tip": "Modulator frequency as a multiple of the note. Non-integer ratios sound inharmonic, bell-like."})
	_add_row(c, &"fm_index", "Index", 0.0, 8.0, 0.01, {"open_max": true,
		"tip": "How far the modulator bends the carrier. 0 = FM off. 0.1-0.3 warm, 0.5-2 clear FM, 3+ metallic."})
	c.add_section("Unison")
	_add_row(c, &"detune_voices", "Voices", 1.0, 4.0, 1.0, {"int": true,
		"tip": "Stacked, detuned copies of the oscillator. 1 = a single voice; more costs CPU."})
	_add_row(c, &"detune_cents", "Detune", 0.0, 50.0, 0.1, {"suffix": "ct", "open_max": true,
		"tip": "Spread between the stacked voices, in cents."})
	c.add_section("Vibrato")
	_add_row(c, &"vibrato_rate", "Rate", 0.0, 15.0, 0.1, {"suffix": "Hz", "open_max": true,
		"tip": "Vibrato speed. 0 = no vibrato."})
	_add_row(c, &"vibrato_depth_cents", "Depth", 0.0, 50.0, 0.1, {"suffix": "ct", "open_max": true,
		"tip": "Vibrato pitch swing in cents (100 = a semitone)."})
	c.add_section("Humanize")
	_add_row(c, &"pitch_randomize_cents", "Pitch", 0.0, 100.0, 0.5, {"suffix": "ct", "open_max": true,
		"tip": "Random detune on every note-on, up to this many cents. 10-20 is subtle."})
	_add_row(c, &"velocity_randomize", "Velocity", 0.0, 1.0, 0.001,
		{"tip": "Random velocity reduction on every note-on: 0.2 = down to 80%."})

func _build_pitch_card() -> void:
	var c := _new_card(&"pitch", "Pitch drop", "Drum")
	_add_graph(c, SynthRackGraph.Kind.PITCH, 56)
	_add_row(c, &"pitch_decay_semitones", "Amount", 0.0, 96.0, 0.5, {"suffix": "st", "open_max": true,
		"tip": "Semitones above the note the pitch starts at. ~48 for a kick, less for toms. 0 = off."})
	_add_row(c, &"pitch_decay_time", "Time", 0.0, 1.0, 0.001, {"suffix": "s", "exp": true, "open_max": true,
		"tip": "Seconds for the pitch to fall to the note. 0.05-0.1 gives the kick's thump."})

func _build_noise_card() -> void:
	var c := _new_card(&"noise", "Noise", "Drum")
	_add_graph(c, SynthRackGraph.Kind.NOISE, 56)
	_add_row(c, &"noise_mix", "Mix", 0.0, 1.0, 0.001,
		{"tip": "Blend from the oscillator (0) to white noise (1). 0 = no noise."})
	_add_row(c, &"noise_decay", "Decay", 0.0, 3.0, 0.001, {"suffix": "s", "exp": true, "open_max": true,
		"tip": "The noise fades out on its own clock, over this many seconds. 0 = it follows the amp envelope."})
	_add_row(c, &"noise_lowpass", "Lowpass", 0.0, 1.0, 0.001,
		{"tip": "One-pole low-pass on the noise alone. 1 = no filter; lower is duller."})
	_add_row(c, &"noise_highpass", "Highpass", 0.0, 1.0, 0.001,
		{"tip": "One-pole high-pass on the noise alone. 0 = no filter; higher removes more rumble."})

func _build_keyboard() -> void:
	var s := SynthRackStyle.scale(self)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.add_theme_stylebox_override("panel", SynthRackStyle.make_card_style(self))
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 2)
	box.add_child(row)
	var down := Button.new()
	down.text = "<"
	down.tooltip_text = "Octave down (Z)"
	down.focus_mode = Control.FOCUS_NONE
	down.pressed.connect(_shift_octave.bind(-1))
	row.add_child(down)
	_oct_label = Label.new()
	_oct_label.custom_minimum_size = Vector2(70.0 * s, 0)
	_oct_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(_oct_label)
	var up := Button.new()
	up.text = ">"
	up.tooltip_text = "Octave up (X)"
	up.focus_mode = Control.FOCUS_NONE
	up.pressed.connect(_shift_octave.bind(1))
	row.add_child(up)
	row.add_child(VSeparator.new())
	var vl := Label.new()
	vl.text = "Velocity"
	row.add_child(vl)
	_vel_slider = HSlider.new()
	_vel_slider.min_value = 0.05
	_vel_slider.max_value = 1.0
	_vel_slider.step = 0.01
	_vel_slider.value = 0.8
	_vel_slider.custom_minimum_size = Vector2(110.0 * s, 0)
	_vel_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_vel_slider.scrollable = false
	_vel_slider.value_changed.connect(func(v): _vel_label.text = "%.2f" % v)
	row.add_child(_vel_slider)
	_vel_label = Label.new()
	_vel_label.text = "0.80"
	row.add_child(_vel_label)
	var hint := Label.new()
	hint.text = "Keys A-K (W E T Y U black) play while this view has focus; Z / X shift the octave. Gold keys are the notes the game plays."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(200.0 * s, 0)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(hint)

	_keys = SynthKeyboard.new()
	_keys.note_pressed.connect(_play)
	_keys.note_released.connect(_stop)
	box.add_child(_keys)
	_update_octave_label()

func _build_dialogs() -> void:
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_RESOURCES
	_save_dialog.filters = PackedStringArray(["*.tres ; Patch Resource"])
	_save_dialog.size = Vector2i(720, 520)
	_save_dialog.file_selected.connect(_on_save_path_chosen)
	_save_dialog.canceled.connect(_on_save_canceled)
	add_child(_save_dialog)

	_confirm = ConfirmationDialog.new()
	_confirm.title = "Unsaved changes"
	_confirm.ok_button_text = "Discard changes"
	_confirm.cancel_button_text = "Cancel"
	_confirm.add_button("Save", false, "save")
	_confirm.confirmed.connect(_on_confirm_discard)
	_confirm.canceled.connect(_on_confirm_cancel)
	_confirm.custom_action.connect(_on_confirm_custom)
	add_child(_confirm)

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _built:
		_relayout()

# Cards per row from the width there is; the browser folds away on a narrow tab.
func _relayout() -> void:
	if not _built:
		return
	var s := SynthRackStyle.scale(self)
	var show_browser: bool = _browser_pref == 1 or (_browser_pref == -1 and size.x >= BROWSER_AUTO_HIDE * s)
	_browser_panel.visible = show_browser
	_browser_btn.set_pressed_no_signal(show_browser)
	var avail: float = _scroll.size.x - 8.0 * s
	var gap: float = GRID_GAP * s
	var cols: int = clampi(int((avail + gap) / (CARD_MIN_WIDTH * s + gap)), 1, 3)
	if cols != _grid.columns:
		_grid.columns = cols

func get_column_count() -> int:
	return _grid.columns

func _on_browser_toggled(on: bool) -> void:
	_browser_pref = 1 if on else 0
	_relayout()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Edit [param p]; [param path] is its file ("" if it has none). Asks first when
## the patch being edited has unsaved changes, unless [param force]: a host that
## already switched its own patch (the Pattern view's Load Patch) just follows.
func open_patch(p: SynthPatch, path: String = "", force: bool = false) -> void:
	if p == null:
		return
	if p == patch:
		current_path = path
		_refresh_header()
		return
	if force:
		_discard_unsaved_silently()
		current_path = path
		_attach(p)
	else:
		_guard(func():
			current_path = path
			_attach(p))

## Legacy name from the single-column editor: edit [param p], no questions asked.
func set_patch(p: SynthPatch) -> void:
	open_patch(p, current_path if p == patch else "", true)

func get_row(prop: StringName) -> SynthRackParam:
	return _rows.get(prop)

func get_card(id: StringName) -> SynthRackCard:
	return _cards.get(id)

func get_keyboard() -> SynthKeyboard:
	return _keys

func get_browser() -> SynthPatchBrowser:
	return _browser

func get_harmonics_editor() -> SynthHarmonicsEditor:
	return _harm

func get_audition_control() -> SynthSegmented:
	return _audition_seg

## Every SynthPatch property the view has a control for.
func get_covered_props() -> PackedStringArray:
	var out := PackedStringArray()
	for p in _rows:
		out.append(String(p))
	for p in ["patch_name", "waveform", "harmonics", "harmonic_ratios", "filter_type"]:
		out.append(p)
	return out

## True when the patch differs from how it was opened or last saved.
func is_dirty() -> bool:
	return patch != null and _fingerprint() != _clean_fp

## Re-scan the project for patches and baked sets (the tab became visible).
func rescan() -> void:
	if _built:
		_reindex(true)

func release_keys() -> void:
	_release_all()

# ---------------------------------------------------------------------------
# Attaching a patch
# ---------------------------------------------------------------------------

func _fingerprint() -> String:
	return SynthSampleSet.fingerprint_patch(patch) + "|" + patch.patch_name

func _attach(p: SynthPatch) -> void:
	_release_all()
	if patch != null and patch.changed.is_connected(_on_patch_changed):
		patch.changed.disconnect(_on_patch_changed)
	patch = p
	patch.changed.connect(_on_patch_changed)
	_clean_fp = _fingerprint()
	_last_edited_flag = false
	if not _built:
		return
	for g in _graphs:
		g.set_patch(patch)
	_harm.set_patch(patch)
	_refresh_all()
	if preview != null:
		preview.set_patch(patch)
	_update_bake_status(false)
	_choose_octave()
	_browser.select_path(current_path)
	patch_changed.emit(patch)

func _on_patch_changed() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	_deferred_refresh.call_deferred()

func _deferred_refresh() -> void:
	_refresh_queued = false
	if patch == null or not _built:
		return
	_refresh_all()
	_update_bake_status(false, true)

# Pull every control from the patch.
func _refresh_all() -> void:
	if patch == null or not _built:
		return
	for prop in _rows:
		(_rows[prop] as SynthRackParam).set_value(float(patch.get(prop)))
	_waveform_seg.set_selected_no_signal(patch.waveform)
	_filter_seg.set_selected_no_signal(patch.filter_type)
	_harm.visible = patch.waveform == SynthPatch.Waveform.ADDITIVE
	_harm.refresh()
	if _name_edit.text != patch.patch_name:
		_name_edit.text = patch.patch_name
	_refresh_graphs()
	_refresh_header()

# The cheap part of an edit: pictures, dimming, the unsaved marker.
func _refresh_graphs() -> void:
	for g in _graphs:
		g.refresh()
	_cards[&"filter"].set_dimmed(patch.filter_type == SynthPatch.FilterType.OFF)
	_cards[&"pitch"].set_dimmed(patch.pitch_decay_semitones <= 0.0)
	_cards[&"noise"].set_dimmed(patch.noise_mix <= 0.0)
	_harm.visible = patch.waveform == SynthPatch.Waveform.ADDITIVE

func _refresh_header() -> void:
	if _path_label == null:
		return
	var dirty := patch != null and is_dirty()
	_path_label.text = (current_path if current_path != "" else "(unsaved)") + (" *" if dirty else "")
	_path_label.tooltip_text = current_path
	_sync_edited_flag(dirty)

func _sync_edited_flag(dirty: bool) -> void:
	if dirty == _last_edited_flag:
		return
	_last_edited_flag = dirty
	if Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface") and patch != null:
		Engine.get_singleton(&"EditorInterface").call("set_object_edited", patch, dirty)

# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------

# A drag is under way: apply the value, show it, record nothing yet.
func _on_row_live(prop: StringName, value: Variant) -> void:
	if patch == null:
		return
	patch.set(prop, value)
	_after_live_edit()

func _on_row_committed(prop: StringName, new_value: Variant, old_value: Variant) -> void:
	_commit(prop, new_value, old_value)

func _after_live_edit() -> void:
	_refresh_graphs()
	_refresh_header()
	_update_bake_status(false, true)

## Set [param prop] to [param new_value] as one undo action. [param old_value] is
## what Undo restores (for a drag that was applied live, the value before it).
func _commit(prop: StringName, new_value: Variant, old_value: Variant) -> void:
	if patch == null or new_value == old_value:
		return
	if undo_redo == null:
		patch.set(prop, new_value)
		patch.emit_changed()
		return
	undo_redo.call("create_action", "Set %s" % String(prop).replace("_", " "), UndoRedo.MERGE_ENDS, patch)
	undo_redo.call("add_do_property", patch, prop, new_value)
	undo_redo.call("add_undo_property", patch, prop, old_value)
	undo_redo.call("add_do_method", patch, &"emit_changed")
	undo_redo.call("add_undo_method", patch, &"emit_changed")
	undo_redo.call("commit_action")

func _on_name_changed(text: String) -> void:
	if patch != null and text != patch.patch_name:
		_commit(&"patch_name", text, patch.patch_name)

# ---------------------------------------------------------------------------
# Guarding changes of patch
# ---------------------------------------------------------------------------

# Run [param then] now, or after the user decides what to do with unsaved edits.
func _guard(then: Callable) -> void:
	if patch == null or not is_dirty():
		then.call()
		return
	_pending = then
	_confirm.dialog_text = "\"%s\" has unsaved changes.\n\nSave them, or discard them and carry on?" % patch.patch_name
	_confirm.popup_centered()

func _on_confirm_discard() -> void:
	var then := _pending
	_pending = Callable()
	_discard_unsaved_silently()
	if then.is_valid():
		then.call()

func _on_confirm_cancel() -> void:
	_pending = Callable()
	_browser.select_path(current_path)

func _on_confirm_custom(action: StringName) -> void:
	if action != &"save":
		return
	_confirm.hide()
	var then := _pending
	_pending = Callable()
	_save_then(then)

# A patch loaded from a file is the editor's cached copy of that file: edits that
# were not saved have to be taken back from disk, or the next open would still
# show them.
func _discard_unsaved_silently() -> void:
	if patch == null or not is_dirty():
		return
	if current_path != "" and ResourceLoader.exists(current_path):
		ResourceLoader.load(current_path, "", ResourceLoader.CACHE_MODE_REPLACE)
		patch.emit_changed()
	_sync_edited_flag(false)

# ---------------------------------------------------------------------------
# New / preset / browser
# ---------------------------------------------------------------------------

func _on_new() -> void:
	_guard(func():
		var p := SynthPatch.new()
		p.patch_name = "New Patch"
		current_path = ""
		_attach(p))

func _on_preset(id: int) -> void:
	_guard(func():
		current_path = ""
		_attach(SynthPatchBrowser.make_preset(id)))

func _on_browser_patch(path: String) -> void:
	if path == current_path:
		return
	_guard(func():
		var res := ResourceLoader.load(path)
		if res is SynthPatch:
			current_path = path
			_attach(res)
		else:
			push_warning("[SynthPatchRack] Not a SynthPatch: " + path)
			_browser.select_path(current_path))

# ---------------------------------------------------------------------------
# Saving
# ---------------------------------------------------------------------------

func _on_save() -> void:
	if current_path == "":
		_on_save_as()
	else:
		save_to(current_path)

func _on_save_as() -> void:
	if patch == null:
		return
	var dir := current_path.get_base_dir() if current_path != "" else "res://"
	_save_dialog.current_dir = dir
	_save_dialog.current_file = patch.patch_name.to_snake_case() + ".tres" if patch.patch_name != "" else "patch.tres"
	_save_dialog.popup_centered()

func _save_then(then: Callable) -> void:
	if current_path == "":
		_after_save = then
		_on_save_as()
	elif save_to(current_path) and then.is_valid():
		then.call()

func _on_save_path_chosen(path: String) -> void:
	if not path.ends_with(".tres"):
		path += ".tres"
	var then := _after_save
	_after_save = Callable()
	if save_to(path) and then.is_valid():
		then.call()

func _on_save_canceled() -> void:
	_after_save = Callable()
	_browser.select_path(current_path)

## Write the patch to [param path] and make that its file. False on failure.
func save_to(path: String) -> bool:
	if patch == null:
		return false
	var err := ResourceSaver.save(patch, path, ResourceSaver.FLAG_CHANGE_PATH)
	if err != OK:
		push_error("[SynthPatchRack] Save failed: %s (err=%d)" % [path, err])
		return false
	current_path = path
	_clean_fp = _fingerprint()
	_last_edited_flag = true  # force the editor's flag to be cleared below
	_sync_edited_flag(false)
	var fs := _editor_fs()
	if fs != null:
		fs.call("update_file", path)
		fs.call("scan")
	else:
		_reindex(true)
	_refresh_header()
	_update_bake_status(false)
	_browser.select_path(current_path)
	return true

# ---------------------------------------------------------------------------
# Project index + bake status
# ---------------------------------------------------------------------------

func _on_filesystem_changed() -> void:
	if _reindex_timer != null and is_inside_tree():
		_reindex_timer.start()

func _reindex(reload_sets: bool) -> void:
	index.rescan(_addon_dir)
	_browser.index = index
	_browser.current_path = current_path
	_browser.rebuild()
	index.compute_refs(get_tree())
	if patch != null:
		_update_bake_status(reload_sets)

func _on_refs_ready() -> void:
	_browser.refresh_hints()
	_update_bake_status(false, true)

# Work out where the patch stands against its baked set and tell the chip,
# the Baked switch and the keyboard. [param light]: only re-decide stale / fresh
# (the set is unchanged; this runs on every edit).
func _update_bake_status(reload: bool, light: bool = false) -> void:
	if patch == null or not _built:
		return
	if light and bake_info != null:
		SynthBakeInfo.update(bake_info, patch)
	else:
		bake_info = SynthBakeInfo.inspect(patch, current_path, index, reload)
		if preview != null:
			preview.set_audition_set(bake_info.sample_set)
		_keys.played = bake_info.played
		var has_set := bake_info.sample_set != null
		_audition_seg.set_item_disabled(1, not has_set,
				"Play keys on the baked sample set, as the game does." if has_set
				else "This patch has no baked sample set, so there is nothing to play. Bake it with your project's bake tool.")
		if not has_set and audition_baked:
			audition_baked = false
			_audition_seg.set_selected_no_signal(0)
	bake_status_changed.emit(bake_info.chip_text(),
			SynthBakeInfo.tooltip(bake_info, index.bake_tools), bake_info.chip_color(self))

# ---------------------------------------------------------------------------
# Audition
# ---------------------------------------------------------------------------

func _on_audition_selected(id: int) -> void:
	audition_baked = id == 1
	_release_all()

func _play(note: int) -> void:
	if preview == null or patch == null:
		return
	preview.audition_note_on(note, _vel_slider.value, audition_baked)
	_keys.set_held(note, true)

func _stop(note: int) -> void:
	if preview != null:
		preview.audition_note_off(note)
	_keys.set_held(note, false)

func _release_all() -> void:
	for code in _kb_held.keys():
		_stop(_kb_held[code])
	_kb_held.clear()
	if _keys != null:
		_keys.clear_held()
	if preview != null:
		preview.audition_all_off()

func _shift_octave(dir: int) -> void:
	_release_all()
	_keys.first_note += 12 * dir
	_update_octave_label()

func _update_octave_label() -> void:
	_oct_label.text = "%s - %s" % [SynthRackStyle.note_name(_keys.first_note), SynthRackStyle.note_name(_keys.get_last_note())]

# Show the octaves that hold the most of the keys the game plays, with them
# toward the middle.
func _choose_octave() -> void:
	var best_base: int = 48
	var best_score: float = -1.0
	var played := _keys.played
	if not played.is_empty():
		var notes: Array = played.keys()
		notes.sort()
		var mid: float = notes[notes.size() / 2]
		for base in range(0, 73, 12):
			var n := 0
			for note in notes:
				if note >= base and note < base + _keys.octaves * 12:
					n += 1
			var score: float = n * 100.0 - absf(mid - (base + _keys.octaves * 6))
			if score > best_score:
				best_score = score
				best_base = base
	_keys.first_note = best_base
	_update_octave_label()

# A click on the view's empty space (a card's margin, a label) focuses the view,
# which is what lets the A-K keys play. Controls that take clicks themselves
# (sliders, fields, the keyboard) keep the event and the focus.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		grab_focus()

func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not is_visible_in_tree():
		return
	var code: int = k.physical_keycode
	if not k.pressed:
		if _kb_held.has(code):
			_stop(_kb_held[code])
			_kb_held.erase(code)
			get_viewport().set_input_as_handled()
		return
	if k.echo or k.ctrl_pressed or k.alt_pressed or k.meta_pressed or not _view_has_focus():
		return
	if code == KEY_Z or code == KEY_X:
		_shift_octave(-1 if code == KEY_Z else 1)
		get_viewport().set_input_as_handled()
	elif KEY_MAP.has(code) and not _kb_held.has(code):
		var note: int = _keys.first_note + 12 + KEY_MAP[code]
		_kb_held[code] = note
		_play(note)
		get_viewport().set_input_as_handled()

# The view has focus when the focused control is part of it and is not a text
# field (typing a name must not play notes).
func _view_has_focus() -> bool:
	var fo := get_viewport().gui_get_focus_owner()
	if fo == null or not (fo == self or is_ancestor_of(fo)):
		return false
	return not (fo is LineEdit or fo is TextEdit)
