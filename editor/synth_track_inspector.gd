@tool
class_name SynthTrackInspector
extends PanelContainer

# The Track view's right-hand panel: the selected MusicTrack's own settings. It
# owns no data. A change is reported as [signal edited] and the view turns it into
# an undo action on the scene's node. When the scene is not open in the editor the
# whole panel is read-only. When the track plays a PatternChain it also lists the
# chain's steps (pattern, repeats, octave, velocity) and the buttons that edit them.

## [param prop] is the MusicTrack property; [param merge] true for a spin box
## click (consecutive ones fold into one undo step).
signal edited(prop: StringName, value: Variant, merge: bool)
signal pattern_open_requested
signal patch_open_requested
signal remove_requested
## Set the track's type to the one its pattern is marked with.
signal match_requested
## A step of the track's chain was edited. [param prop] is the PatternChainStep
## property; [param merge] is true for a spin box click.
signal step_edited(step: int, prop: StringName, value: Variant, merge: bool)
## A step button: &"add" (step is -1), &"remove", &"up", &"down", &"duplicate", &"open".
signal step_action(action: StringName, step: int)
signal step_selected(step: int)
signal make_chain_requested
signal unwrap_chain_requested
signal save_chain_requested

const TYPE_NAMES := ["Chord", "Melody", "Drum"]
const SWAP_NAMES := ["Immediate", "Next beat", "Next block"]
const READONLY_TIP := "The scene is not open in the editor, so its tracks are read-only."
const TYPE_TIPS := "Chord: notes are chord tones. Melody: notes are scale degrees. Drum: notes are MIDI notes."

var _title: Label
var _banner: Label
var _body: VBoxContainer
var _type: OptionButton
var _clash: Label
var _match: Button
var _pattern: SynthResourceField
var _patch: SynthResourceField
var _open_pattern: Button
var _make_chain: Button
var _unwrap_chain: Button
var _save_chain: Button
var _steps_box: VBoxContainer
var _step_rows: VBoxContainer
var _add_step: Button
var _rows: Array[Dictionary] = []
var _selected_step: int = -1
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
	_clash = _wrapped()
	_clash.add_theme_color_override("font_color", SynthRackStyle.warn(self))
	_clash.mouse_filter = Control.MOUSE_FILTER_STOP
	_body.add_child(_clash)
	_match = Button.new()
	_match.text = "Match pattern"
	_match.focus_mode = Control.FOCUS_NONE
	_match.pressed.connect(func(): match_requested.emit())
	_body.add_child(_match)

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
	var chain_flow := HFlowContainer.new()
	_body.add_child(chain_flow)
	_make_chain = _flat_button("Make chain", func(): make_chain_requested.emit())
	_unwrap_chain = _flat_button("Use pattern", func(): unwrap_chain_requested.emit())
	_save_chain = _flat_button("Save chain as...", func(): save_chain_requested.emit())
	for b in [_make_chain, _unwrap_chain, _save_chain]:
		chain_flow.add_child(b)

	_steps_box = VBoxContainer.new()
	_steps_box.add_theme_constant_override("separation", 6)
	_body.add_child(_steps_box)
	var sh := Label.new()
	sh.text = "Steps"
	sh.tooltip_text = "The chain plays its steps in order, then loops."
	sh.mouse_filter = Control.MOUSE_FILTER_PASS
	_steps_box.add_child(sh)
	_step_rows = VBoxContainer.new()
	_step_rows.add_theme_constant_override("separation", 6)
	_steps_box.add_child(_step_rows)
	_add_step = _flat_button("Add step", func(): step_action.emit(&"add", -1))
	_steps_box.add_child(_add_step)

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

func _flat_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b

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
## state), can_remove (bool), remove_tip (String), path (String: the node's path),
## clash (String: the warning when the pattern is marked with another type, else
## ""), match_tip (String: the Match pattern button's tooltip), can_match (bool:
## false when Match pattern would change nothing), selected_step (int: the chain
## step shown selected, -1 none).
func show_track(t: MusicTrack, info: Dictionary) -> void:
	_editable = info.get("editable", false)
	_title.text = String(t.name)
	_title.tooltip_text = info.get("path", "")
	_banner.visible = not _editable
	_banner.text = info.get("banner", "")
	_body.visible = true
	_type.select(_type.get_item_index(int(t.track_type)))
	_type.disabled = not _editable
	var clash: String = info.get("clash", "")
	_clash.text = clash
	_clash.tooltip_text = clash
	_clash.visible = clash != ""
	_match.visible = clash != ""
	_match.disabled = not _editable or not info.get("can_match", true)
	_match.tooltip_text = info.get("match_tip", "")
	_pattern.set_resource(t.pattern)
	_pattern.editable = _editable
	_open_pattern.disabled = t.pattern == null
	_selected_step = info.get("selected_step", -1)
	_show_chain(t.pattern)
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

# The chain buttons and the step list for the track's pattern.
func _show_chain(p: MusicPattern) -> void:
	var chain := p as PatternChain
	_make_chain.visible = chain == null
	_make_chain.disabled = not _editable or p == null
	_make_chain.tooltip_text = READONLY_TIP if not _editable else ("This track has no pattern." if p == null \
			else "Wrap the pattern in a chain with one step, to play several patterns in turn. The chain stays in the scene until you save it.")
	_unwrap_chain.visible = chain != null
	var single := chain != null and chain.steps.size() == 1 and chain.steps[0] != null and chain.steps[0].pattern != null
	_unwrap_chain.disabled = not _editable or not single
	_unwrap_chain.tooltip_text = READONLY_TIP if not _editable else ("Replace the chain with its one pattern. The step's repeats, octave and velocity are dropped." \
			if single else "Only a chain with one step can be turned back into a pattern.")
	_save_chain.visible = chain != null
	_save_chain.disabled = not _editable
	_save_chain.tooltip_text = READONLY_TIP if not _editable else "Save the chain to a .tres file."
	_steps_box.visible = chain != null
	if chain == null:
		_selected_step = -1
		return
	_add_step.disabled = not _editable
	_add_step.tooltip_text = READONLY_TIP if not _editable else "Add a step at the end. Pick its pattern in the step."
	while _rows.size() > chain.steps.size():
		var gone: PanelContainer = _rows.pop_back()["panel"]
		_step_rows.remove_child(gone)
		gone.queue_free()
	while _rows.size() < chain.steps.size():
		_rows.append(_make_step_row())
	for i in _rows.size():
		_sync_row(i, chain.steps[i])

func _make_step_row() -> Dictionary:
	var row := {}
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.gui_input.connect(func(e: InputEvent):
		var mb := e as InputEventMouseButton
		if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			step_selected.emit(_rows.find(row)))
	_step_rows.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	box.add_child(head)
	var num := Label.new()
	num.mouse_filter = Control.MOUSE_FILTER_PASS
	head.add_child(num)
	var field := SynthResourceField.new()
	field.setup("MusicPattern")
	field.resource_changed.connect(func(r: Resource): step_edited.emit(_rows.find(row), &"pattern", r, false))
	field.resource_opened.connect(func(_r: Resource): step_action.emit(&"open", _rows.find(row)))
	head.add_child(field)
	var vals := HBoxContainer.new()
	vals.add_theme_constant_override("separation", 4)
	box.add_child(vals)
	var rep := _step_spin(vals, "Repeats", 1, 64, 1, "How many times in a row the pattern plays.")
	rep.value_changed.connect(func(v: float): step_edited.emit(_rows.find(row), &"repeats", int(v), true))
	var oct := _step_spin(vals, "Octave", -4, 4, 1, "Whole octaves added to the pattern's notes. A drum track ignores it.")
	oct.value_changed.connect(func(v: float): step_edited.emit(_rows.find(row), &"octave_shift", int(v), true))
	var vel := _step_spin(vals, "Velocity", 0.0, 4.0, 0.01, "Multiplies the velocity of the pattern's notes (1 leaves them as they are).")
	vel.custom_arrow_step = 0.05
	vel.value_changed.connect(func(v: float): step_edited.emit(_rows.find(row), &"velocity_scale", v, true))
	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 4)
	box.add_child(btns)
	row["panel"] = panel
	row["num"] = num
	row["field"] = field
	row["repeats"] = rep
	row["octave"] = oct
	row["velocity"] = vel
	for e in [["up", "▲", &"up", "Move this step earlier."], ["down", "▼", &"down", "Move this step later."],
			["duplicate", "Duplicate", &"duplicate", "Add a copy of this step after it."], ["remove", "Remove", &"remove", "Remove this step."]]:
		var action: StringName = e[2]
		var b := _flat_button(e[1], func(): step_action.emit(action, _rows.find(row)))
		b.tooltip_text = e[3]
		btns.add_child(b)
		row[e[0]] = b
	var open := _flat_button("Open in Pattern", func(): step_action.emit(&"open", _rows.find(row)))
	open.tooltip_text = "Edit this step's pattern in Pattern."
	box.add_child(open)
	row["open"] = open
	return row

# A small label over a spin box, in [param parent].
func _step_spin(parent: Control, text: String, lo: float, hi: float, step: float, tip: String) -> SpinBox:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 0)
	parent.add_child(col)
	var l := Label.new()
	l.text = text
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	col.add_child(l)
	var sp := _spin(lo, hi, step)
	sp.allow_greater = true
	sp.tooltip_text = tip
	if lo < 0.0:
		sp.allow_lesser = true
	col.add_child(sp)
	return sp

func _sync_row(i: int, step: PatternChainStep) -> void:
	var row := _rows[i]
	var live := _editable and step != null
	(row["num"] as Label).text = "%d" % (i + 1)
	(row["panel"] as PanelContainer).tooltip_text = "Click to select this step."
	var field: SynthResourceField = row["field"]
	field.set_resource(step.pattern if step != null else null)
	field.editable = live
	(row["repeats"] as SpinBox).set_value_no_signal(step.repeats if step != null else 1)
	(row["octave"] as SpinBox).set_value_no_signal(step.octave_shift if step != null else 0)
	(row["velocity"] as SpinBox).set_value_no_signal(step.velocity_scale if step != null else 1.0)
	for k in ["repeats", "octave", "velocity"]:
		(row[k] as SpinBox).editable = live
	var last := i == _rows.size() - 1
	(row["up"] as Button).disabled = not _editable or i == 0
	(row["down"] as Button).disabled = not _editable or last
	(row["duplicate"] as Button).disabled = not live
	(row["remove"] as Button).disabled = not _editable
	(row["open"] as Button).disabled = step == null or step.pattern == null
	_style_row(i)

func _style_row(i: int) -> void:
	var sb := SynthRackStyle.make_card_style(self)
	sb.bg_color = SynthRackStyle.inset(self)
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	if i == _selected_step:
		sb.border_color = SynthRackStyle.accent(self)
	(_rows[i]["panel"] as PanelContainer).add_theme_stylebox_override("panel", sb)

## Show step [param i] selected (-1: none).
func select_step(i: int) -> void:
	var prev := _selected_step
	_selected_step = i
	for k in [prev, i]:
		if k >= 0 and k < _rows.size():
			_style_row(k)

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

func get_match_button() -> Button:
	return _match

func get_clash_text() -> String:
	return _clash.text if _clash.visible else ""

func get_make_chain_button() -> Button:
	return _make_chain

func get_unwrap_button() -> Button:
	return _unwrap_chain

func get_save_chain_button() -> Button:
	return _save_chain

func get_add_step_button() -> Button:
	return _add_step

func get_open_pattern_button() -> Button:
	return _open_pattern

## Whether the step list is showing (the track's pattern is a chain).
func is_chain_shown() -> bool:
	return _steps_box.visible

func get_step_count() -> int:
	return _rows.size() if _steps_box.visible else 0

## Step [param i]'s widgets: panel, num, field, repeats, octave, velocity, up, down,
## duplicate, remove, open.
func get_step_row(i: int) -> Dictionary:
	return _rows[i]

func get_selected_step() -> int:
	return _selected_step

func get_remove_button() -> Button:
	return _remove

func get_title_text() -> String:
	return _title.text

func get_banner_text() -> String:
	return _banner.text if _banner.visible else ""

func is_read_only() -> bool:
	return not _editable
