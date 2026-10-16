@tool
extends EditorPlugin

# Adds a "Synth" tab to the editor's main-screen row (next to 2D / 3D / Script):
# a Sound / Pattern / Track workspace over one shared preview synth. See
# editor/synth_main_screen.gd.
#
# Double-clicking a SynthPatch, MusicPattern or MusicData .tres in the FileSystem
# dock switches to the tab and opens it in the matching view.
#
# Paths are relative (preload("./...")): the addon is installed as
# addons/godot_synth/ in some projects and addons/gd-synth/ in others.

const MainScreenScript := preload("./editor/synth_main_screen.gd")

var _main_screen: Control

func _enter_tree() -> void:
	_register_settings()
	_main_screen = MainScreenScript.new()
	_main_screen.name = "SynthMainScreen"
	# The Sound view records its edits here, so Ctrl+Z in the editor undoes them.
	_main_screen.undo_redo = get_undo_redo()
	EditorInterface.get_editor_main_screen().add_child(_main_screen)
	# The Track view edits the music scene through its open tab: it wants to know
	# when scenes are opened, switched and closed.
	scene_changed.connect(_on_scene_changed)
	scene_closed.connect(_on_scene_closed)
	_make_visible(false)

# Project > Project Settings > godot_synth/bake/tool_script: the host's bake
# EditorScript, which the tab's Bake button runs. Empty by default, so nothing is
# written to project.godot until a project sets it.
func _register_settings() -> void:
	var key := SynthBakeInfo.BAKE_TOOL_SETTING
	if not ProjectSettings.has_setting(key):
		ProjectSettings.set_setting(key, "")
	ProjectSettings.set_initial_value(key, "")
	ProjectSettings.add_property_info({
		"name": key,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_FILE,
		"hint_string": "*.gd",
	})

func _on_scene_changed(_root: Node) -> void:
	if _main_screen != null:
		_main_screen.editor_scenes_changed()

func _on_scene_closed(_path: String) -> void:
	if _main_screen != null:
		_main_screen.editor_scenes_changed()

func _exit_tree() -> void:
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if scene_closed.is_connected(_on_scene_closed):
		scene_closed.disconnect(_on_scene_closed)
	if _main_screen != null:
		# Hide first so the preview stops and the engine's thread is released,
		# then free the whole tab (preview nodes, dialogs and all).
		_main_screen.set_active(false)
		if _main_screen.get_parent() != null:
			_main_screen.get_parent().remove_child(_main_screen)
		_main_screen.free()
		_main_screen = null

func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return "Synth"

func _get_plugin_icon() -> Texture2D:
	var theme := EditorInterface.get_editor_theme()
	if theme != null and theme.has_icon("AudioStreamPlayer", "EditorIcons"):
		return theme.get_icon("AudioStreamPlayer", "EditorIcons")
	return null

func _make_visible(visible: bool) -> void:
	if _main_screen == null:
		return
	_main_screen.visible = visible
	_main_screen.set_active(visible)

func _handles(object: Object) -> bool:
	return object is SynthPatch or object is MusicPattern or object is MusicData

func _edit(object: Object) -> void:
	if _main_screen == null or object == null:
		return
	if object is SynthPatch:
		_main_screen.open_patch(object)
	elif object is MusicPattern:
		_main_screen.open_pattern(object)
	elif object is MusicData:
		_main_screen.open_music_data(object)
