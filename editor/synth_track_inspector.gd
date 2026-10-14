@tool
class_name SynthTrackInspector
extends PanelContainer

# The Track view's right-hand panel: the selected MusicTrack's own settings. It
# owns no data. A change is reported as [signal edited] and the view turns it into
# an undo action on the scene's node. When the scene is not open in the editor the
# whole panel is read-only.

## [param prop] is the MusicTrack property; [param merge] true for a spin box
## click (consecutive ones fold into one undo step).
signal edited(prop: StringName, value: Variant, merge: bool)
signal pattern_open_requested
signal patch_open_requested
signal remove_requested

const TYPE_NAMES := ["Chord", "Melody", "Drum"]
const SWAP_NAMES := ["Immediate", "Next beat", "Next block"]
const TYPE_TIPS := "Chord: notes are chord tones. Melody: notes are scale degrees. Drum: notes are MIDI notes."

var _title: Label
var _banner: Label
var _body: VBoxContainer
var _type: OptionButton
var _pattern: SynthResourceField
var _patch: SynthResourceField
var _open_pattern: Button
var _open_patch: Button
var _bake: Label
var _channel: SpinBox
var _octave: SpinBox
var _pan: SpinBox
var _swap: OptionButton
var _bus: OptionButton
var _effects: Label
var _extras: Label
var _remove: Button
var _editable: bool = true

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
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	root.add_child(_title)
	_banner = _wrapped()
	root.add_child(_banner)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	root.add_child(_body)

	_type = OptionButton.new()
	_type.focus_mode = Control.FOCUS_NONE
	for i in TYPE_NAMES.size():
		_type.add_item(TYPE_NAMES[i], i)
	_type.item_selected.connect(func(i: int): edited.emit(&"track_type", _type.get_item_id(i), false))
	_row("Type", _type, TYPE_TIPS)

	_pattern = SynthResourceField.new()
	_pattern.setup("MusicPattern")
	_pattern.resource_changed.connect(func(r: Resource): edited.emit(&"pattern", r, false))
	_pattern.resource_opened.connect(func(_r: Resource): pattern_open_requested.emit())
	_row("Pattern", _pattern, "The pattern this track loops. Click it to edit it in Pattern.")
	_open_pattern = Button.new()
	_open_pattern.text = "Open in Pattern"
	_open_pattern.focus_mode = Control.FOCUS_NONE
	_open_pattern.pressed.connect(func(): pattern_open_requested.emit())
	_body.add_child(_open_pattern)

	_patch = SynthResourceField.new()
	_patch.setup("SynthPatch")
	_patch.resource_changed.connect(func(r: Resource): edited.emit(&"patch", r, false))
	_patch.resource_opened.connect(func(_r: Resource): patch_open_requested.emit())
	_row("Patch", _patch, "The timbre this track puts on its channel.")
	_open_patch = Button.new()
	_open_patch.text = "Open in Sound"
	_open_patch.focus_mode = Control.FOCUS_NONE
	_open_patch.pressed.connect(func(): patch_open_requested.emit())
	_body.add_child(_open_patch)
	_bake = _wrapped()
	_body.add_child(_bake)

	_channel = _spin(0, 15, 1)
	_channel.value_changed.connect(func(v: float): edited.emit(&"synth_channel", int(v), true))
	_row("Channel", _channel, "SynthEngine channel (0 to 15). Tracks that share one share its patch.")
	_octave = _spin(-2, 10, 1)
	_octave.value_changed.connect(func(v: float): edited.emit(&"base_octave", int(v), true))
	_row("Base octave", _octave, "Octave offset for chord and melody tracks. A drum track ignores it.")
	_pan = _spin(-1.0, 1.0, 0.05)
	_pan.value_changed.connect(func(v: float): edited.emit(&"pan", v, true))
	_row("Pan", _pan, "Stereo position of every note: -1 left, 0 centre, 1 right.")

	_swap = OptionButton.new()
	_swap.focus_mode = Control.FOCUS_NONE
	for i in SWAP_NAMES.size():
		_swap.add_item(SWAP_NAMES[i], i)
	_swap.item_selected.connect(func(i: int): edited.emit(&"swap_mode", _swap.get_item_id(i), false))
	_row("Swap mode", _swap, "When this track starts, and when a pattern swap takes effect, in the game. The editor preview starts every track at once.")

	_bus = OptionButton.new()
	_bus.focus_mode = Control.FOCUS_NONE
	_bus.item_selected.connect(func(i: int):
		var md: Variant = _bus.get_item_metadata(i)
		edited.emit(&"output_bus", StringName(md) if md != null else StringName(_bus.get_item_text(i)), false))
	_row("Output bus", _bus, "The audio bus this track's channel sends to in the game.")

	_body.add_child(HSeparator.new())
	var eh := Label.new()
	eh.text = "Effects"
	_body.add_child(eh)
	_effects = _wrapped()
	_body.add_child(_effects)
	_extras = _wrapped()
	_body.add_child(_extras)

	_remove = Button.new()
	_remove.text = "Remove track"
	_remove.focus_mode = Control.FOCUS_NONE
	_remove.pressed.connect(func(): remove_requested.emit())
	_body.add_child(_remove)

func _ready() -> void:
	_restyle()
	show_none("Select a track.")

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

func _wrapped() -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 120.0
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	return l

func _spin(lo: float, hi: float, step: float) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = lo
	sp.max_value = hi
	sp.step = step
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return sp

func _row(text: String, control: Control, tip: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_body.add_child(row)
	var l := Label.new()
	l.text = text
	l.tooltip_text = tip
	l.custom_minimum_size.x = 84.0 * SynthRackStyle.scale(self)
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.tooltip_text = tip
	row.add_child(control)

## Nothing to show: [param message] says why.
func show_none(message: String) -> void:
	_title.text = "Track"
	_banner.text = message
	_banner.visible = true
	_body.visible = false

## Show [param t]. [param info]: editable (bool), bake (String: the patch's bake
## state), can_remove (bool), remove_tip (String), path (String: the node's path).
func show_track(t: MusicTrack, info: Dictionary) -> void:
	_editable = info.get("editable", false)
	_title.text = String(t.name)
	_title.tooltip_text = info.get("path", "")
	_banner.visible = not _editable
	_banner.text = info.get("banner", "")
	_body.visible = true
	_type.select(_type.get_item_index(int(t.track_type)))
	_type.disabled = not _editable
	_pattern.set_resource(t.pattern)
	_pattern.editable = _editable
	_open_pattern.disabled = t.pattern == null
	_patch.set_resource(t.patch)
	_patch.editable = _editable
	_open_patch.disabled = t.patch == null
	_bake.text = info.get("bake", "")
	_bake.visible = _bake.text != ""
	_channel.set_value_no_signal(t.synth_channel)
	_channel.editable = _editable
	_octave.set_value_no_signal(t.base_octave)
	_octave.editable = _editable and t.track_type != MusicTrack.TrackType.DRUM
	_pan.set_value_no_signal(t.pan)
	_pan.editable = _editable
	_swap.select(_swap.get_item_index(int(t.swap_mode)))
	_swap.disabled = not _editable
	_fill_bus(t.output_bus)
	_bus.disabled = not _editable
	if t.effects.is_empty():
		_effects.text = "None."
	else:
		var names := PackedStringArray()
		for e in t.effects:
			names.append(e.resource_name if e != null and e.resource_name != "" else (e.get_class() if e != null else "(empty)"))
		_effects.text = "%s\n\nRead-only here. The editor preview plays dry on Master: effects and the output bus only take effect in the game." % "\n".join(names)
	var extras := PackedStringArray()
	if t.bpm_override > 0.0:
		extras.append("bpm_override %s: in the game this track keeps its own tempo; the preview follows the song." % t.bpm_override)
	if t.key_override != null:
		extras.append("key_override is set: in the game this track ignores the progression's key; the preview uses the progression.")
	_extras.text = "\n".join(extras)
	_extras.visible = not extras.is_empty()
	_remove.visible = _editable
	_remove.disabled = not info.get("can_remove", false)
	_remove.tooltip_text = info.get("remove_tip", "Remove this track from the scene.")

func _fill_bus(current: StringName) -> void:
	_bus.clear()
	var found := false
	for i in AudioServer.bus_count:
		var n := AudioServer.get_bus_name(i)
		_bus.add_item(n)
		if n == String(current):
			_bus.select(i)
			found = true
	if not found:
		_bus.add_item("%s (no such bus)" % current)
		_bus.set_item_metadata(_bus.item_count - 1, current)
		_bus.select(_bus.item_count - 1)

func get_type_option() -> OptionButton:
	return _type

func get_pattern_field() -> SynthResourceField:
	return _pattern

func get_patch_field() -> SynthResourceField:
	return _patch

func get_channel_spin() -> SpinBox:
	return _channel

func get_octave_spin() -> SpinBox:
	return _octave

func get_pan_spin() -> SpinBox:
	return _pan

func get_swap_option() -> OptionButton:
	return _swap

func get_bus_option() -> OptionButton:
	return _bus

func get_remove_button() -> Button:
	return _remove

func get_title_text() -> String:
	return _title.text

func get_banner_text() -> String:
	return _banner.text if _banner.visible else ""

func is_read_only() -> bool:
	return not _editable
