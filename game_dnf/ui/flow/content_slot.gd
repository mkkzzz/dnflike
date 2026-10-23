extends Button
## All inventory, equipment, shop, item hotkeys and skill cells use this control.
var game
var cell: Dictionary = {}
var image_view: TextureRect
var amount: Label

func setup(root, data: Dictionary) -> void:
	game = root
	cell = data.duplicate(true)
	custom_minimum_size = Vector2(28, 28)
	size = Vector2(28, 28)
	focus_mode = Control.FOCUS_NONE
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:add_theme_stylebox_override(state, StyleBoxEmpty.new())
	var id: String = cell.get("id", "")
	if id != "":
		var texture: Texture2D = game.slot_texture(cell)
		image_view = game.skin.image(self, texture, Vector2.ZERO)
		image_view.name = "item_icon"
		if cell["place"] != "skill":
			var item: Dictionary = game.Catalog.ITEMS[id]
			game.skin.rarity_frame(self, item["rarity"], Color(game.Catalog.RARITIES[item["rarity"]]["color"]))
			set_meta("item_id", id)
			set_meta("item_name", item["name"])
			amount = game.skin.label(self, "", Vector2(0, 14), 9, Color.WHITE)
			amount.size.x = 26
			amount.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			amount.name = "item_amount"
		else:set_meta("skill_id", id)
	mouse_entered.connect(func(): game.slot_hover(self))
	mouse_exited.connect(func(): game.windows.hide_tooltip())
	pressed.connect(func(): game.slot_pressed(self))
	refresh_quantity()

func refresh_quantity() -> void:
	if not is_instance_valid(amount):return
	var id: String = cell["id"]
	var count := int(cell.get("count", game.session.profile["inventory"].get(id, 0)))
	if cell["place"] == "bag":count = game.session.Layout.available(game.session.profile, id)
	amount.text = str(count) if game.Catalog.ITEMS[id]["kind"] == "consumable" or count > 1 else ""
	if cell["place"] in ["equipment", "shop"]:amount.text = ""
	if cell["place"] == "quick":image_view.modulate = Color.WHITE if count > 0 else Color("666666")

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and event.double_click:
		game.slot_double_clicked(self)
		accept_event()

func _get_drag_data(_at: Vector2):
	if cell.get("id", "") == "":return null
	if cell["place"] not in ["bag", "equipment", "quick", "shop", "skill"]:return null
	game.windows.hide_tooltip()
	var preview := TextureRect.new()
	preview.texture = game.slot_texture(cell)
	preview.size = Vector2(50, 50)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	set_drag_preview(preview)
	return cell.duplicate(true)

func _can_drop_data(_at: Vector2, data) -> bool:
	return data is Dictionary and game.can_drop_slot(data, cell)

func _drop_data(_at: Vector2, data) -> void:
	game.drop_slot(data, cell)
