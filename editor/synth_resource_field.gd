@tool
class_name SynthResourceField
extends HBoxContainer

# A resource slot: the editor's own EditorResourcePicker (thumbnail, quick load,
# new, clear, drag and drop) when running inside the editor, and a plain name
# button with a file dialog anywhere else. Created through ClassDB so the script
# still compiles in a build that has no editor classes.
#
# It never writes anywhere: it reports a pick as [signal resource_changed] and a
# click on the resource itself as [signal resource_opened].

signal resource_changed(res: Resource)
signal resource_opened(res: Resource)

var base_type: String = "Resource"
var resource: Resource
var editable: bool = true:
	set(v):
		editable = v
		_apply()

var _picker: Control
var _btn: Button
var _dialog: FileDialog

func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

func setup(type_name: String) -> void:
	base_type = type_name
	if ClassDB.class_exists("EditorResourcePicker") and ClassDB.can_instantiate("EditorResourcePicker"):
		_picker = ClassDB.instantiate("EditorResourcePicker")
		_picker.set("base_type", base_type)
		_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_picker.connect("resource_changed", _on_picked)
		_picker.connect("resource_selected", func(res: Resource, _inspect: bool): resource_opened.emit(res))
		add_child(_picker)
	else:
		_btn = Button.new()
		_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_btn.clip_text = true
		_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_btn.pressed.connect(_on_button)
		add_child(_btn)
		_dialog = FileDialog.new()
		_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_dialog.access = FileDialog.ACCESS_RESOURCES
		_dialog.filters = PackedStringArray(["*.tres, *.res ; Resource"])
		_dialog.size = Vector2i(720, 520)
		_dialog.file_selected.connect(func(path: String):
			var r := ResourceLoader.load(path)
			if r != null and _script_classes(r).has(base_type):
				_on_picked(r))
		add_child(_dialog)
	_apply()

static func _script_classes(r: Resource) -> PackedStringArray:
	var out := PackedStringArray()
	var sc := r.get_script() as Script
	while sc != null:
		out.append(sc.get_global_name())
		sc = sc.get_base_script()
	return out

## Show [param res] without reporting it.
func set_resource(res: Resource) -> void:
	resource = res
	_apply()

func _apply() -> void:
	if _picker != null:
		_picker.set("edited_resource", resource)
		_picker.set("editable", editable)
	if _btn != null:
		_btn.text = _name_of(resource)
		_btn.disabled = not editable
		_btn.tooltip_text = resource.resource_path if resource != null else ""

static func _name_of(res: Resource) -> String:
	if res == null:
		return "(none)"
	if res.resource_path != "" and not "::" in res.resource_path:
		return res.resource_path.get_file()
	return "(inline)"

func _on_picked(res: Resource) -> void:
	resource = res
	_apply()
	resource_changed.emit(res)

func _on_button() -> void:
	if resource != null and not editable:
		resource_opened.emit(resource)
	elif _dialog != null:
		_dialog.popup_centered()

## The picker's own control, if the editor's is in use (for tests).
func get_picker() -> Control:
	return _picker
