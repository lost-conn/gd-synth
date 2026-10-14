@tool
class_name SynthSegmented
extends HFlowContainer

# A row of toggle buttons where exactly one is down: a segmented control.
# Wraps onto a second line if the card is too narrow for it.

signal selected(id: int)

var _group := ButtonGroup.new()
var _buttons: Dictionary = {}  # id -> Button

func _init() -> void:
	add_theme_constant_override("h_separation", 0)
	add_theme_constant_override("v_separation", 2)

## [param items]: [[text, id, tooltip?], ...].
func setup(items: Array) -> void:
	for it in items:
		var b := Button.new()
		b.text = it[0]
		b.toggle_mode = true
		b.button_group = _group
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = it[2] if it.size() > 2 else ""
		b.pressed.connect(_on_pressed.bind(it[1]))
		add_child(b)
		_buttons[it[1]] = b

func _on_pressed(id: int) -> void:
	selected.emit(id)

func set_selected_no_signal(id: int) -> void:
	# set_pressed_no_signal does not release the rest of a ButtonGroup.
	for key in _buttons:
		_buttons[key].set_pressed_no_signal(key == id)

func get_selected() -> int:
	for id in _buttons:
		if _buttons[id].button_pressed:
			return id
	return -1

func set_item_disabled(id: int, disabled: bool, tip: String = "") -> void:
	if _buttons.has(id):
		var b: Button = _buttons[id]
		b.disabled = disabled
		if tip != "" or not disabled:
			b.tooltip_text = tip

func get_button(id: int) -> Button:
	return _buttons.get(id)
