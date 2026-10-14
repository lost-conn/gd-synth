@tool
class_name SynthRackParam
extends HBoxContainer

# One labelled parameter: name, slider, numeric field. It never writes to the
# patch itself; it reports, and the rack turns reports into undo actions:
#
#   live       the value is being dragged: apply it, draw it, but do not record it
#   committed  a finished edit (drag released, field entered, key / wheel step):
#              record old -> new as one undo action
#
# So a slider drag is one undo step however long it was.

signal live(prop: StringName, value: Variant)
signal committed(prop: StringName, new_value: Variant, old_value: Variant)

var prop: StringName
var is_int: bool = false

var _label: Label
var _slider: HSlider
var _spin: SpinBox
# The patch's value as this row last knew it (the "old" of the next commit).
var _value: float = 0.0
var _dragging: bool = false
var _drag_start: float = 0.0

## [param opts]: "suffix" (String), "exp" (bool, log-feel slider for times),
## "open_max" (bool, a value above [param max_value] is allowed: the property has
## no range of its own), "int" (bool), "tip" (String).
func setup(p_prop: StringName, p_label: String, min_value: float, max_value: float,
		step: float, opts: Dictionary = {}) -> void:
	prop = p_prop
	is_int = opts.get("int", false)
	add_theme_constant_override("separation", 6)

	_label = Label.new()
	_label.text = p_label
	_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_label.tooltip_text = opts.get("tip", "")
	add_child(_label)

	_slider = HSlider.new()
	_slider.min_value = min_value
	_slider.max_value = max_value
	_slider.step = step
	_slider.exp_edit = opts.get("exp", false)
	_slider.allow_greater = opts.get("open_max", false)
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.scrollable = false  # a wheel over the panel scrolls the panel, not the value
	_slider.drag_started.connect(_on_drag_started)
	_slider.drag_ended.connect(_on_drag_ended)
	_slider.value_changed.connect(_on_slider_changed)
	add_child(_slider)

	_spin = SpinBox.new()
	_spin.min_value = min_value
	_spin.max_value = max_value
	_spin.step = step
	_spin.allow_greater = opts.get("open_max", false)
	_spin.suffix = opts.get("suffix", "")
	_spin.select_all_on_focus = true
	_spin.value_changed.connect(_on_spin_changed)
	add_child(_spin)

func _ready() -> void:
	var s := SynthRackStyle.scale(self)
	_label.custom_minimum_size = Vector2(84.0 * s, 0)
	_slider.custom_minimum_size = Vector2(56.0 * s, 0)
	_spin.custom_minimum_size = Vector2(88.0 * s, 0)

## Show [param v] without reporting it.
func set_value(v: float) -> void:
	if _dragging:
		return
	_value = v
	_slider.set_value_no_signal(v)
	_spin.set_value_no_signal(v)

func get_value() -> float:
	return _value

func _cast(v: float) -> Variant:
	return int(roundf(v)) if is_int else v

func _on_drag_started() -> void:
	_dragging = true
	_drag_start = _value

func _on_slider_changed(v: float) -> void:
	_spin.set_value_no_signal(v)
	if _dragging:
		_value = v
		live.emit(prop, _cast(v))
	else:
		var old := _value
		_value = v
		committed.emit(prop, _cast(v), _cast(old))

func _on_drag_ended(_changed: bool) -> void:
	_dragging = false
	if not is_equal_approx(_value, _drag_start):
		committed.emit(prop, _cast(_value), _cast(_drag_start))

func _on_spin_changed(v: float) -> void:
	_slider.set_value_no_signal(v)
	var old := _value
	_value = v
	committed.emit(prop, _cast(v), _cast(old))
