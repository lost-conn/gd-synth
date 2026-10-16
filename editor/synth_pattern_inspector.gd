@tool
class_name SynthPatternInspector
extends PanelContainer

# The Pattern view's right-hand panel. It edits every selected note at once (a
# field the notes disagree on reads "—"; typing a number sets them all), or the
# selected bend, and tells where the pattern's track type came from. It owns no
# data: it reports edits as signals and the view turns them into undo actions.

signal note_edited(prop: StringName, value: float)
signal bend_edited(prop: StringName, value: float)
signal add_bend_requested
signal add_sub_bend_requested
signal remove_bend_requested
signal base_octave_edited(value: int)

const NOTE_FIELDS := [
	[&"beat", "Beat", 0.0, 1024.0, 0.01, "When the note starts, in beats from the pattern's start."],
	[&"duration", "Duration", 0.01, 256.0, 0.01, "How long it sounds, in beats."],
	[&"index", "Index", -64.0, 127.0, 1.0, "Chord tone, scale degree or MIDI note, by track type."],
	[&"octave", "Octave", -6.0, 6.0, 1.0, "Octaves added to the resolved pitch (ignored by drums)."],
	[&"accidental", "Accidental", -12.0, 12.0, 0.01, "Semitones added to the pitch; fractions are microtones."],
	[&"velocity", "Velocity", 0.0, 1.0, 0.01, "How hard the note is struck, 0 to 1."],
]
const BEND_FIELDS := [
	[&"offset_beats", "Offset", 0.0, 256.0, 0.01, "When the glide starts, in beats after its parent starts."],
	[&"glide_beats", "Glide", 0.0, 256.0, 0.01, "How long the glide takes. 0 jumps."],
	[&"index", "Index", -64.0, 127.0, 1.0, "The pitch it glides to (chord tone, degree or MIDI note)."],
	[&"octave", "Octave", -6.0, 6.0, 1.0, "Octaves added to the target."],
	[&"accidental", "Accidental", -12.0, 12.0, 0.01, "Semitones added to the target."],
]

var _title: Label
var _note_box: VBoxContainer
var _bend_box: VBoxContainer
var _note_spins: Dictionary = {}
var _bend_spins: Dictionary = {}
var _info_type: Label
var _type_warn: Label
var _info_patch: Label
var _context_box: VBoxContainer
var _octave_spin: SpinBox
var _bend_btn: Button

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	scroll.add_child(root)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 15)
	root.add_child(_title)

	_note_box = VBoxContainer.new()
	_note_box.add_theme_constant_override("separation", 4)
	root.add_child(_note_box)
	for f in NOTE_FIELDS:
		_note_spins[f[0]] = _add_field(_note_box, f, note_edited)
	_bend_btn = Button.new()
	_bend_btn.text = "Add bend (B)"
	_bend_btn.focus_mode = Control.FOCUS_NONE
	_bend_btn.tooltip_text = "Glide the selected note's pitch toward a target row. Press B with the mouse over the row you want."
	_bend_btn.pressed.connect(func(): add_bend_requested.emit())
	_note_box.add_child(_bend_btn)

	_bend_box = VBoxContainer.new()
	_bend_box.add_theme_constant_override("separation", 4)
	root.add_child(_bend_box)
	for f in BEND_FIELDS:
		_bend_spins[f[0]] = _add_field(_bend_box, f, bend_edited)
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	_bend_box.add_child(row)
	var sub := Button.new()
	sub.text = "Add sub-bend"
	sub.focus_mode = Control.FOCUS_NONE
	sub.tooltip_text = "Chain another glide off this one; its offset is relative to this bend's start."
	sub.pressed.connect(func(): add_sub_bend_requested.emit())
	row.add_child(sub)
	var rm := Button.new()
	rm.text = "Remove bend"
	rm.focus_mode = Control.FOCUS_NONE
	rm.pressed.connect(func(): remove_bend_requested.emit())
	row.add_child(rm)

	root.add_child(HSeparator.new())
	var th := Label.new()
	th.text = "Track"
	th.add_theme_font_size_override("font_size", 15)
	root.add_child(th)
	_info_type = _wrapped_label()
	root.add_child(_info_type)
	_type_warn = _wrapped_label()
	_type_warn.add_theme_color_override("font_color", SynthRackStyle.warn(self))
	_type_warn.mouse_filter = Control.MOUSE_FILTER_STOP
	_type_warn.visible = false
	root.add_child(_type_warn)
	var orow := HBoxContainer.new()
	orow.add_theme_constant_override("separation", 6)
	root.add_child(orow)
	var ol := Label.new()
	ol.text = "Base octave"
	ol.tooltip_text = "Octave the preview plays the pattern in. The MusicTrack's own base_octave decides in the game; this only changes what you hear here."
	ol.custom_minimum_size.x = 84.0 * SynthRackStyle.scale(self)
	orow.add_child(ol)
	_octave_spin = SpinBox.new()
	_octave_spin.min_value = 0
	_octave_spin.max_value = 8
	_octave_spin.step = 1
	_octave_spin.value = 4
	_octave_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_octave_spin.value_changed.connect(func(v): base_octave_edited.emit(int(v)))
	orow.add_child(_octave_spin)
	_info_patch = _wrapped_label()
	root.add_child(_info_patch)
	_context_box = VBoxContainer.new()
	_context_box.add_theme_constant_override("separation", 2)
	root.add_child(_context_box)

func _ready() -> void:
	_restyle()
	show_notes([])

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_restyle()

var _restyling := false

func _restyle() -> void:
	if _restyling or _title == null:
		return
	_restyling = true
	add_theme_stylebox_override("panel", SynthRackStyle.make_card_style(self))
	_restyling = false

func _wrapped_label() -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 120.0
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	return l

func _add_field(parent: Control, f: Array, sig: Signal) -> SynthMixedSpin:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var l := Label.new()
	l.text = f[1]
	l.tooltip_text = f[5]
	l.custom_minimum_size.x = 84.0 * SynthRackStyle.scale(self)
	row.add_child(l)
	var sp := SynthMixedSpin.new()
	sp.min_value = f[2]
	sp.max_value = f[3]
	sp.step = f[4]
	sp.allow_greater = f[3] >= 256.0
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.tooltip_text = f[5]
	sp.edited.connect(func(v: float): sig.emit(f[0], v))
	row.add_child(sp)
	return sp

# ---------------------------------------------------------------------------
# Showing a selection
# ---------------------------------------------------------------------------

## Show [param notes] (PatternNotes); [] = nothing selected.
func show_notes(notes: Array) -> void:
	_bend_box.visible = false
	_note_box.visible = true
	_title.text = "Nothing selected" if notes.is_empty() else ("1 note" if notes.size() == 1 else "%d notes" % notes.size())
	for f in NOTE_FIELDS:
		var vals: Array = []
		for n in notes:
			vals.append(float(n.get(f[0])))
		(_note_spins[f[0]] as SynthMixedSpin).set_values(vals)
	_bend_btn.disabled = notes.is_empty()

## Show the bend of [param entry] (see SynthRoll.get_selected_bend()).
func show_bend(bend: PatternBend) -> void:
	_note_box.visible = false
	_bend_box.visible = true
	_title.text = "Bend"
	for f in BEND_FIELDS:
		(_bend_spins[f[0]] as SynthMixedSpin).set_values([float(bend.get(f[0]))])

func set_type_info(text: String, tooltip: String) -> void:
	_info_type.text = text
	_info_type.tooltip_text = tooltip
	_info_type.mouse_filter = Control.MOUSE_FILTER_STOP

## The warning under the type: a MusicTrack plays the pattern as another type.
## "" clears it.
func set_type_warning(text: String) -> void:
	_type_warn.text = text
	_type_warn.tooltip_text = text
	_type_warn.visible = text != ""

func get_type_warning() -> String:
	return _type_warn.text if _type_warn.visible else ""

func set_patch_info(text: String) -> void:
	_info_patch.text = text

func set_base_octave(v: int, enabled: bool) -> void:
	_octave_spin.set_value_no_signal(v)
	_octave_spin.editable = enabled

## Other tracks drawn behind the roll: [{name, color, total, shown}].
func set_context(lines: Array, header: String) -> void:
	for c in _context_box.get_children():
		c.queue_free()
	if header == "":
		return
	var h := _wrapped_label()
	h.text = header
	_context_box.add_child(h)
	for ln in lines:
		var l := Label.new()
		l.text = "■ %s: %d notes%s" % [ln["name"], ln["total"], "" if ln["shown"] == ln["total"] else " (%d in view rows)" % ln["shown"]]
		l.add_theme_font_size_override("font_size", 12)
		l.add_theme_color_override("font_color", Color(ln["color"], 1.0))
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_context_box.add_child(l)

func get_note_spin(prop: StringName) -> SynthMixedSpin:
	return _note_spins.get(prop)

func get_bend_spin(prop: StringName) -> SynthMixedSpin:
	return _bend_spins.get(prop)

func get_title_text() -> String:
	return _title.text
