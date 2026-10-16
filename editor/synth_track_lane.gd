@tool
class_name SynthTrackLane
extends HBoxContainer

# One row of the arranger: the track's name, type and mute / solo on the left, its
# clips on the right (SynthClipLane). Clicking either half selects the track.

signal selected
signal clip_activated
signal mute_toggled(on: bool)
signal solo_toggled(on: bool)

## Width of the left half at editor scale 1; the rulers above keep the same gutter.
const GUTTER := 210.0
const GUTTER_NARROW := 132.0

var clips: SynthClipLane
var mute_btn: Button
var solo_btn: Button

var _head: PanelContainer
var _name: Label
var _sub: Label
var _swatch: ColorRect
var _warn: Label
var _is_selected: bool = false
var _gutter_w: float = 0.0
var _warning: String = ""

func _init() -> void:
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

func _ready() -> void:
	var s := SynthRackStyle.scale(self)
	_head = PanelContainer.new()
	_head.custom_minimum_size = Vector2(_gutter_w if _gutter_w > 0.0 else GUTTER * s, 0)
	_head.mouse_filter = Control.MOUSE_FILTER_STOP
	_head.gui_input.connect(_on_head_input)
	add_child(_head)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(6 * s))
	_head.add_child(row)
	_swatch = ColorRect.new()
	_swatch.custom_minimum_size = Vector2(4.0 * s, 0)
	_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_swatch)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	_name = Label.new()
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_name)
	_sub = Label.new()
	_sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_sub.add_theme_font_size_override("font_size", SynthRackStyle.font_size(self, 0.8))
	_sub.add_theme_color_override("font_color", SynthRackStyle.dim(self))
	_sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_sub)
	_warn = Label.new()
	_warn.text = "!"
	_warn.visible = false
	_warn.mouse_filter = Control.MOUSE_FILTER_STOP
	_warn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_warn.add_theme_color_override("font_color", SynthRackStyle.warn(self))
	row.add_child(_warn)
	var ms := HBoxContainer.new()
	ms.add_theme_constant_override("separation", 2)
	ms.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(ms)
	mute_btn = _toggle("M", "Mute this track.", mute_toggled)
	solo_btn = _toggle("S", "Solo: only soloed tracks sound.", solo_toggled)
	ms.add_child(mute_btn)
	ms.add_child(solo_btn)
	set_warning(_warning)

	clips = SynthClipLane.new()
	clips.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clips.pressed.connect(func(): selected.emit())
	clips.clip_activated.connect(func(): clip_activated.emit())
	add_child(clips)
	_restyle()

func _toggle(text: String, tip: String, sig: Signal) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(24.0 * SynthRackStyle.scale(self), 0)
	b.toggled.connect(func(on: bool): sig.emit(on))
	return b

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_restyle()

func _restyle() -> void:
	if _head == null:
		return
	var sb := SynthRackStyle.make_card_style(self)
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	if _is_selected:
		sb.border_color = SynthRackStyle.accent(self)
	_head.add_theme_stylebox_override("panel", sb)

## [param color]: the lane's colour (the same as its notes in the Pattern view's
## overlay). [param sub]: the second line (type, channel).
func setup(track_name: String, sub: String, tip: String, color: Color) -> void:
	_name.text = track_name
	_sub.text = sub
	_head.tooltip_text = tip
	_swatch.color = color

## Mark the track with a warning ([param text], also its tooltip); "" clears it.
func set_warning(text: String) -> void:
	_warning = text
	if _warn != null:
		_warn.visible = text != ""
		_warn.tooltip_text = text

func get_warning_text() -> String:
	return _warning

## Width of the name column, in pixels.
func set_gutter(w: float) -> void:
	_gutter_w = w
	if _head != null:
		_head.custom_minimum_size.x = w

func set_selected(on: bool) -> void:
	_is_selected = on
	clips.selected = on
	_restyle()

func set_state(muted: bool, soloed: bool, audible: bool) -> void:
	mute_btn.set_pressed_no_signal(muted)
	solo_btn.set_pressed_no_signal(soloed)
	clips.audible = audible
	_name.modulate.a = 1.0 if audible else 0.5

func _on_head_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		selected.emit()
		if mb.double_click:
			clip_activated.emit()
