@tool
class_name SynthSongEdit
extends RefCounted

# Every change the Track view makes to a scene's nodes or to its MusicData goes
# through here, as one EditorUndoRedoManager action (so Ctrl+Z undoes it, the scene
# tab shows as modified and Ctrl+S saves it). The view never packs or writes a
# scene itself. Without an undo manager (the tab run outside the editor) a change
# is applied directly, with no history.

## The editor's EditorUndoRedoManager, or null.
var undo_redo: Object

## Set properties as one action. [param changes]: [[object, property, value], ...].
## [param context]: the object the action belongs to (a node of the scene, or the
## MusicData), which decides whose history it lands in. [param merge]: fold into
## the previous action of the same name (spin-box clicks). [param emit_changed]:
## resources to tell afterwards (do and undo), since setting a script variable
## does not.
func set_properties(label: String, context: Object, changes: Array, merge: bool = false,
		emit_changed: Array = []) -> void:
	if undo_redo == null:
		for c in changes:
			(c[0] as Object).set(c[1], c[2])
		for r in emit_changed:
			(r as Resource).emit_changed()
		return
	undo_redo.call("create_action", label, UndoRedo.MERGE_ENDS if merge else UndoRedo.MERGE_DISABLE, context)
	for c in changes:
		var obj: Object = c[0]
		undo_redo.call("add_do_property", obj, c[1], c[2])
		undo_redo.call("add_undo_property", obj, c[1], obj.get(c[1]))
	for r in emit_changed:
		undo_redo.call("add_do_method", r, &"emit_changed")
		undo_redo.call("add_undo_method", r, &"emit_changed")
	undo_redo.call("commit_action")

## Add [param node] as a child of [param parent] in the edited scene [param root].
func add_node(label: String, root: Node, parent: Node, node: Node) -> void:
	if undo_redo == null:
		parent.add_child(node, true)
		node.owner = root
		return
	undo_redo.call("create_action", label, UndoRedo.MERGE_DISABLE, root)
	undo_redo.call("add_do_method", parent, &"add_child", node, true)
	undo_redo.call("add_do_method", node, &"set_owner", root)
	undo_redo.call("add_do_reference", node)
	undo_redo.call("add_undo_method", parent, &"remove_child", node)
	undo_redo.call("commit_action")

## Remove [param node] (which owns no children) from the edited scene [param root].
func remove_node(label: String, root: Node, node: Node) -> void:
	var parent := node.get_parent()
	var at := node.get_index()
	if undo_redo == null:
		parent.remove_child(node)
		node.free()
		return
	undo_redo.call("create_action", label, UndoRedo.MERGE_DISABLE, root)
	undo_redo.call("add_do_method", parent, &"remove_child", node)
	undo_redo.call("add_undo_method", parent, &"add_child", node, true)
	undo_redo.call("add_undo_method", parent, &"move_child", node, at)
	undo_redo.call("add_undo_method", node, &"set_owner", root)
	undo_redo.call("add_undo_reference", node)
	undo_redo.call("commit_action")
