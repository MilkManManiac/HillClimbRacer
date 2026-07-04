extends RefCounted
## Garage/shop UI extracted from HCMain. Persistent state stays on HCMain.

var main
var _shop_header: Label
var _shop_money: Label
var _shop_tabs: TabContainer
var _shop_rows := {}
var _veh_rows := {}
var _reset_btn: Button
var _restart_btn: Button
var _money_btn: Button
var _reset_armed := false
var _first_veh_btn: Button
var _scroll_repeat := 0.0
var _kit_lbl: Label
var _map_row_lbl: Label
var _cosm_rows := {}
var _shop_summary := ""

func _init(main_ref) -> void:
	main = main_ref

## Display name for a kit path: "Stock" or a cleaned-up filename.
func _kit_name(path: String) -> String:
	if path == "":
		return "Stock"
	return path.get_file().get_basename().replace("_", " ")

## Cycle the ACTIVE vehicle's body kit and rebuild the car wearing it.
func _cycle_body_kit() -> void:
	if main._audio:
		main._audio.call("play_click")
	var cur: String = str(main._body_kits.get(main._vehicle, ""))
	var i: int = main._kit_options.find(cur)
	main._body_kits[main._vehicle] = main._kit_options[(i + 1) % main._kit_options.size()]
	main._swap_vehicle(main._vehicle)   # full rebuild in the new shell (+ saves + refreshes shop)

## Cycle to the next map from the shop/death-screen "MAP" row.
func _cycle_map() -> void:
	if main._audio:
		main._audio.call("play_click")
	var i: int = main.MAP_KEYS.find(main._map)
	main._map = main.MAP_KEYS[(i + 1) % main.MAP_KEYS.size()]
	main._apply_map()
	main._refresh_map_buttons()

## Refresh the "MAP: <name>" readout in the shop/death screen, if built.
func _update_map_row() -> void:
	if _map_row_lbl:
		_map_row_lbl.text = "MAP:  %s" % main.MAPS[main._map].name

func _build_shop() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	main.add_child(layer)
	main._shop = Control.new()
	main._shop.set_anchors_preset(Control.PRESET_FULL_RECT)
	main._shop.visible = false
	layer.add_child(main._shop)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.72)
	main._shop.add_child(dim)

	# a fixed-size centered panel; the upgrade list inside scrolls so nothing
	# can ever run off the bottom of the screen no matter how many upgrades.
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(672, 700)
	panel.position = Vector2(-336, -350)
	main._shop.add_child(panel)
	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 18)
	panel.add_child(pad)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	pad.add_child(box)

	_shop_header = main._shop_label(box, "", 26, Color(1, 0.82, 0.42))
	_shop_money = main._shop_label(box, "", 19, Color(0.65, 1.0, 0.7))
	var sep := HSeparator.new()
	box.add_child(sep)

	# MAP switcher: change tracks between runs (cycles through MAPS + rebuilds).
	var map_row := HBoxContainer.new()
	map_row.add_theme_constant_override("separation", 10)
	box.add_child(map_row)
	_map_row_lbl = Label.new()
	_map_row_lbl.add_theme_font_size_override("font_size", 15)
	_map_row_lbl.add_theme_color_override("font_color", Color(0.8, 0.85, 1.0))
	_map_row_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_row.add_child(_map_row_lbl)
	var map_switch := Button.new()
	map_switch.text = "switch"
	map_switch.custom_minimum_size = Vector2(90, 32)
	map_switch.pressed.connect(_cycle_map)
	map_row.add_child(map_switch)
	_update_map_row()
	box.add_child(HSeparator.new())

	# Three tabs — Garage, Upgrades, Cosmetics — so no section crowds another and every
	# option stays on screen (LB/RB or Q/E switch tabs). Each tab scrolls on its own;
	# the RETRY / NEW GAME footer stays pinned below the tabs.
	_shop_tabs = TabContainer.new()
	_shop_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# min height low enough that the footer (RETRY / NEW GAME / test money / hints)
	# ALWAYS fits inside the 700px panel even with the tall death header — the tabs
	# expand into whatever space is left and their lists scroll internally.
	# 430 used to clip everything below RETRY off the panel (found in playtest).
	_shop_tabs.custom_minimum_size = Vector2(624, 220)
	_shop_tabs.tab_alignment = TabBar.ALIGNMENT_CENTER
	box.add_child(_shop_tabs)
	var garage_list := _make_tab("🚗  Garage")
	var upgrade_list := _make_tab("🔧  Upgrades")
	var cosmetic_list := _make_tab("✨  Cosmetics")

	# --- GARAGE tab: unlock / select a ride ------------------------------------
	var list := garage_list
	for vk in main.VEH_KEYS:
		var vrow := HBoxContainer.new()
		vrow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vrow.add_theme_constant_override("separation", 10)
		list.add_child(vrow)
		var vinfo := VBoxContainer.new()
		vinfo.custom_minimum_size = Vector2(360, 0)
		vinfo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vinfo.add_theme_constant_override("separation", 0)
		vrow.add_child(vinfo)
		var vlbl := Label.new()
		vlbl.add_theme_font_size_override("font_size", 17)
		vinfo.add_child(vlbl)
		var vdesc := Label.new()
		vdesc.text = main.VEHICLES[vk].desc
		vdesc.add_theme_font_size_override("font_size", 12)
		vdesc.add_theme_color_override("font_color", Color(0.62, 0.64, 0.7))
		vdesc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vdesc.custom_minimum_size = Vector2(360, 0)
		vinfo.add_child(vdesc)
		var vbuy := Button.new()
		vbuy.custom_minimum_size = Vector2(110, 40)
		vbuy.pressed.connect(_on_vehicle_button.bind(vk))
		vrow.add_child(vbuy)
		if _first_veh_btn == null:
			_first_veh_btn = vbuy
		_veh_rows[vk] = {"label": vlbl, "buy": vbuy}
	# --- BODY KIT: dress the active ride in an imported .glb shell -------------
	list.add_child(HSeparator.new())
	var khint: Label = main._shop_label(list, "BODY KIT — a 3-D model shell for the ACTIVE ride (free; drop .glb files into assets/car/). Wheels auto-fit to the model.", 13, Color(0.62, 0.64, 0.7))
	khint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var krow := HBoxContainer.new()
	krow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	krow.add_theme_constant_override("separation", 10)
	list.add_child(krow)
	_kit_lbl = Label.new()
	_kit_lbl.add_theme_font_size_override("font_size", 16)
	_kit_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	krow.add_child(_kit_lbl)
	var kbtn := Button.new()
	kbtn.text = "next kit ▸"
	kbtn.custom_minimum_size = Vector2(110, 40)
	kbtn.pressed.connect(_cycle_body_kit)
	krow.add_child(kbtn)
	# --- UPGRADES tab ----------------------------------------------------------
	list = upgrade_list
	for key in main.UP_KEYS:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 10)
		list.add_child(row)
		var info := VBoxContainer.new()
		info.custom_minimum_size = Vector2(300, 0)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.add_theme_constant_override("separation", 0)
		row.add_child(info)
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 18)
		info.add_child(lbl)
		var desc := Label.new()
		desc.text = main.UP_DESC.get(key, "")
		desc.add_theme_font_size_override("font_size", 12)
		desc.add_theme_color_override("font_color", Color(0.62, 0.64, 0.7))
		info.add_child(desc)
		var sell := Button.new()
		sell.custom_minimum_size = Vector2(62, 40)
		sell.add_theme_color_override("font_color", Color(1.0, 0.7, 0.6))
		sell.pressed.connect(_sell.bind(key))
		row.add_child(sell)
		var buy := Button.new()
		buy.custom_minimum_size = Vector2(96, 40)
		buy.pressed.connect(_buy.bind(key))
		row.add_child(buy)
		_shop_rows[key] = {"label": lbl, "desc": desc, "buy": buy, "sell": sell}

	# --- COSMETICS tab: purely visual; buy cheap once, then pick a colour ------
	list = cosmetic_list
	var coshint: Label = main._shop_label(list, "Purely visual — buy once, then hover a swatch to preview it and click to apply.", 13, Color(0.62, 0.64, 0.7))
	coshint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for ck in main.COSM_KEYS:
		var c: Dictionary = main.COSMETICS[ck]
		var crow := HBoxContainer.new()
		crow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		crow.add_theme_constant_override("separation", 10)
		list.add_child(crow)
		var cinfo := Label.new()
		cinfo.text = str(c.name)
		cinfo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cinfo.add_theme_font_size_override("font_size", 18)
		crow.add_child(cinfo)
		# live preview: shows the colour you are hovering / have selected before you commit
		var cprev := Panel.new()
		cprev.custom_minimum_size = Vector2(72, 34)
		var pv_sb := StyleBoxFlat.new()
		pv_sb.bg_color = main._cosm_color[ck]
		pv_sb.set_corner_radius_all(5)
		pv_sb.set_border_width_all(2)
		pv_sb.border_color = Color(1, 1, 1, 0.55)
		cprev.add_theme_stylebox_override("panel", pv_sb)
		crow.add_child(cprev)
		var cbuy := Button.new()
		cbuy.custom_minimum_size = Vector2(110, 40)
		cbuy.pressed.connect(_buy_cosmetic.bind(ck))
		crow.add_child(cbuy)
		var sw_row := HBoxContainer.new()
		sw_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sw_row.add_theme_constant_override("separation", 6)
		list.add_child(sw_row)
		var swatch_btns := []
		for col in c.colors:
			var sw := Button.new()
			sw.custom_minimum_size = Vector2(46, 32)
			var sb := StyleBoxFlat.new(); sb.bg_color = col; sb.set_corner_radius_all(4)
			# the SAME stylebox drives every state so the hover/selected ring shows in any state.
			for st in ["normal", "hover", "pressed", "focus"]:
				sw.add_theme_stylebox_override(st, sb)
			sw.pressed.connect(_pick_cosmetic.bind(ck, col))
			# hovering (mouse) or focusing (pad/keys) live-previews the colour + rings the swatch
			sw.mouse_entered.connect(_preview_cosmetic.bind(ck, col))
			sw.focus_entered.connect(_preview_cosmetic.bind(ck, col))
			sw_row.add_child(sw)
			swatch_btns.append({"btn": sw, "sb": sb, "color": col})
		_cosm_rows[ck] = {"buy": cbuy, "swatches": sw_row, "swatch_btns": swatch_btns, "preview": pv_sb}

	_restart_btn = Button.new()
	_restart_btn.text = "RETRY  (Enter / ⓑ)  —  keeps your garage"
	_restart_btn.custom_minimum_size = Vector2(0, 46)
	_restart_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_restart_btn.pressed.connect(Callable(main, "_restart"))
	box.add_child(_restart_btn)

	# Fresh start: wipe ALL progress (money, every vehicle's upgrades, unlocks) and
	# return to the starter Hot Rod. Two-click confirm so it can't be a mis-tap.
	_reset_btn = Button.new()
	_reset_btn.text = "🔄 NEW GAME  —  wipe ALL upgrades & money"
	_reset_btn.custom_minimum_size = Vector2(0, 40)
	_reset_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reset_btn.add_theme_color_override("font_color", Color(1.0, 0.62, 0.55))
	_reset_btn.pressed.connect(_on_reset_pressed)
	box.add_child(_reset_btn)

	if OS.is_debug_build():
		# TEST-ONLY: instant cash so you can buy anything while iterating
		_money_btn = Button.new()
		_money_btn.text = "🧪 +$1,000,000  (test money)"
		_money_btn.custom_minimum_size = Vector2(0, 34)
		_money_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_money_btn.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
		_money_btn.pressed.connect(_on_test_money)
		box.add_child(_money_btn)

	# navigation legend — keycap "icons" so it's obvious how to move through the menu
	box.add_child(HSeparator.new())
	var hints := HBoxContainer.new()
	hints.alignment = BoxContainer.ALIGNMENT_CENTER
	hints.add_theme_constant_override("separation", 16)
	box.add_child(hints)
	_nav_hint(hints, "Q / E  ·  ⇦⇨", "Tabs")
	_nav_hint(hints, "↑ / ↓", "Move")
	_nav_hint(hints, "← / →", "Sell / Buy")
	_nav_hint(hints, "⏎ · Ⓐ", "Select")
	_nav_hint(hints, "Tab · ☰", "Close")

	_wire_focus_chain()
	# connect AFTER the rows exist (adding tabs above fires tab_changed early, when the
	# row dicts are still empty). Now mouse tab clicks relink the focus ring too.
	_shop_tabs.tab_changed.connect(func(_i): _relink_active_chain())

## TEST-ONLY: dump a million dollars in the bank and refresh the shop.
func _on_test_money() -> void:
	main.money += 1000000
	main._save_game()
	_refresh_shop()

## HOLD up/down (d-pad or arrow keys) to keep moving the shop focus, instead of tapping
## once per item. The first press is handled by the built-in nav; after a short delay
## this repeats while held.
func _shop_autoscroll(delta: float) -> void:
	if main._shop == null or not main._shop.visible:
		_scroll_repeat = 0.0
		return
	var dir := 0
	if Input.is_action_pressed("ui_down"):
		dir = 1
	elif Input.is_action_pressed("ui_up"):
		dir = -1
	if dir == 0:
		_scroll_repeat = 0.0
		return
	if Input.is_action_just_pressed("ui_down") or Input.is_action_just_pressed("ui_up"):
		_scroll_repeat = 0.4   # let the first tap move once, then wait before auto-repeating
		return
	_scroll_repeat -= delta
	if _scroll_repeat <= 0.0:
		_move_shop_focus(dir)
		_scroll_repeat = 0.08   # repeat cadence while held

func _move_shop_focus(dir: int) -> void:
	var f: Control = main.get_viewport().gui_get_focus_owner()
	if f == null:
		return
	var np: NodePath = f.focus_neighbor_bottom if dir > 0 else f.focus_neighbor_top
	if np.is_empty():
		return
	var target: Node = f.get_node_or_null(np)
	if target and target is Control:
		(target as Control).grab_focus()

## Build one scrolling tab (named `title`) in the TabContainer and return its content
## VBox to fill. follow_focus keeps the gamepad-focused row on screen as you walk it.
func _make_tab(title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.follow_focus = true
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 8)
	sc.add_child(vb)
	_shop_tabs.add_child(sc)
	_shop_tabs.set_tab_title(_shop_tabs.get_tab_count() - 1, title)
	return vb

## Cycle the visible tab (LB/RB or Q/E) and focus its first row.
func _switch_tab(dir: int) -> void:
	if _shop_tabs == null:
		return
	var n := _shop_tabs.get_tab_count()
	_shop_tabs.current_tab = (_shop_tabs.current_tab + dir + n) % n
	if main._audio:
		main._audio.call("play_click")
	_relink_active_chain()
	_focus_tab_first()

## Grab focus on the first button of the currently-visible tab.
func _focus_tab_first() -> void:
	var firsts := [
		_veh_rows[main.VEH_KEYS[0]].buy if _veh_rows.has(main.VEH_KEYS[0]) else null,
		_shop_rows[main.UP_KEYS[0]].buy if _shop_rows.has(main.UP_KEYS[0]) else null,
		_cosm_rows[main.COSM_KEYS[0]].buy if _cosm_rows.has(main.COSM_KEYS[0]) else null,
	]
	var t: int = clampi(_shop_tabs.current_tab, 0, firsts.size() - 1)
	if firsts[t]:
		(firsts[t] as Control).call_deferred("grab_focus")

## Wire the static bits (Buy<->Sell on upgrade rows) then link the ACTIVE tab. The
## per-tab ring is rebuilt on open / tab-switch so focus never escapes into a hidden
## tab's clipped rows (which would make the cursor vanish past the last visible item).
func _wire_focus_chain() -> void:
	for key in main.UP_KEYS:
		var b: Button = _shop_rows[key].buy
		var s: Button = _shop_rows[key].sell
		s.focus_mode = Control.FOCUS_ALL
		b.focus_neighbor_left = b.get_path_to(s)
		s.focus_neighbor_right = s.get_path_to(b)
	_relink_active_chain()

## Build ONE wrapping focus ring from the visible tab's Buy buttons + the shared footer,
## so d-pad up/down cycles only currently-visible controls. Every entry is on screen, so
## walking past the last item wraps back to the top instead of dropping focus.
func _relink_active_chain() -> void:
	if _shop_tabs == null or _veh_rows.is_empty() or _shop_rows.is_empty() or _cosm_rows.is_empty():
		return   # rows not built yet (tab_changed can fire mid-construction)
	var chain: Array[Control] = []
	match _shop_tabs.current_tab:
		1:
			for key in main.UP_KEYS:
				chain.append(_shop_rows[key].buy)
		2:
			for ck in main.COSM_KEYS:
				chain.append(_cosm_rows[ck].buy)
		_:
			for vk in main.VEH_KEYS:
				chain.append(_veh_rows[vk].buy)
	chain.append(_restart_btn)
	chain.append(_reset_btn)
	if _money_btn:
		chain.append(_money_btn)
	_chain_focus(chain)

## Wire an ordered list of controls into a wrapping top/bottom focus ring.
func _chain_focus(chain: Array[Control]) -> void:
	var n := chain.size()
	for i in range(n):
		var cur: Control = chain[i]
		var nxt: Control = chain[(i + 1) % n]
		var prv: Control = chain[(i - 1 + n) % n]
		cur.focus_mode = Control.FOCUS_ALL
		cur.focus_neighbor_bottom = cur.get_path_to(nxt)
		cur.focus_neighbor_top = cur.get_path_to(prv)
		cur.focus_next = cur.get_path_to(nxt)
		cur.focus_previous = cur.get_path_to(prv)

## A rounded "keycap" chip (the boxed key/button icon) used by the nav legend.
func _key_chip(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", Color(0.95, 0.96, 1.0))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.19, 0.21, 0.27)
	sb.set_corner_radius_all(5)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.42, 0.46, 0.55)
	sb.content_margin_left = 8; sb.content_margin_right = 8
	sb.content_margin_top = 3; sb.content_margin_bottom = 3
	l.add_theme_stylebox_override("normal", sb)
	return l

## One legend entry: a keycap chip + a short caption of what it does.
func _nav_hint(parent: Node, keys: String, caption: String) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	h.add_child(_key_chip(keys))
	var cap := Label.new()
	cap.text = caption
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", Color(0.66, 0.7, 0.78))
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(cap)
	parent.add_child(h)

func _show_shop() -> void:
	_shop_header.text = "WRECKED!"
	var best_m := int(float(main._best.get(main._map, 0.0)))
	_shop_summary = "You reached %d m  —  earned +$%d this run\nBEST: %d m" % [int(main._car.get("distance")), main._last_earned, best_m]
	main._shop.visible = true
	_refresh_shop()
	# focus RETRY so a gamepad can just press A to go again (d-pad to browse upgrades)
	if _restart_btn:
		_restart_btn.call_deferred("grab_focus")

func _toggle_shop() -> void:
	if main._shop == null:
		return
	main._shop.visible = not main._shop.visible
	if main._shop.visible:
		_shop_header.text = "GARAGE"
		_shop_summary = ""
		if _shop_tabs:
			_shop_tabs.current_tab = 0
		_refresh_shop()
		_relink_active_chain()
		if _first_veh_btn:
			_first_veh_btn.call_deferred("grab_focus")

## Vehicle row button: select if owned, otherwise buy if affordable.
func _on_vehicle_button(vk: String) -> void:
	if main._audio:
		main._audio.call("play_click")
	if main._vehicle == vk:
		return
	if bool(main._owned.get(vk, false)):
		main._swap_vehicle(vk)
		return
	var price: int = int(main.VEHICLES[vk].price)
	if main.money < price:
		return
	main.money -= price
	main._owned[vk] = true
	if main._audio:
		main._audio.call("play_cash")
	main._swap_vehicle(vk)

## Fresh-start button: first press arms (asks to confirm), second press wipes.
func _on_reset_pressed() -> void:
	if not _reset_armed:
		_reset_armed = true
		_reset_btn.text = "⚠ CONFIRM — wipe EVERYTHING?"
		return
	_fresh_start()

## Wipe all persistent progress and rebuild as the starter Hot Rod.
func _fresh_start() -> void:
	_reset_armed = false
	main.money = 0
	main._last_earned = 0
	_shop_summary = ""
	main._best = {}
	main._init_levels()                                    # zero every vehicle's tree
	main._owned = {"minivan": true, "hotrod": false, "monster": false, "sports": false, "f1": false}
	for ck in main.COSM_KEYS:
		main._cosm_owned[ck] = false
		main._cosm_color[ck] = main.COSMETICS[ck].default
	main._body_kits = {}   # back to stock shells on every ride
	if main.save_enabled and FileAccess.file_exists(main.SAVE_PATH):
		DirAccess.remove_absolute(main.SAVE_PATH)   # wipe the on-disk save, not just memory
	main._swap_vehicle("minivan")                          # rebuild the car clean + re-apply zeros
	                                                   # (this also re-saves the blank state)
	if _reset_btn:
		_reset_btn.text = "🔄 NEW GAME  —  wipe ALL upgrades & money"
	_refresh_shop()

func _refresh_shop() -> void:
	# any other shop action cancels a pending fresh-start confirmation
	if _reset_armed and _reset_btn:
		_reset_armed = false
		_reset_btn.text = "🔄 NEW GAME  —  wipe ALL upgrades & money"
	var bank := "TOTAL MONEY:  $%d   (kept between tries)" % main.money
	_shop_money.text = (_shop_summary + "\n" + bank) if _shop_summary != "" else bank
	if _kit_lbl:
		_kit_lbl.text = "BODY KIT:  %s" % _kit_name(str(main._body_kits.get(main._vehicle, "")))
	_refresh_cosmetics()
	for vk in main.VEH_KEYS:
		var vrow: Dictionary = _veh_rows[vk]
		vrow.label.text = main.VEHICLES[vk].name
		var vbuy: Button = vrow.buy
		if main._vehicle == vk:
			vbuy.text = "DRIVING"
			vbuy.disabled = true
			vrow.label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.7))
		elif bool(main._owned.get(vk, false)):
			vbuy.text = "SELECT"
			vbuy.disabled = false
			vrow.label.add_theme_color_override("font_color", Color(1, 1, 1))
		else:
			var price: int = int(main.VEHICLES[vk].price)
			vbuy.text = "$%d" % price
			vbuy.disabled = main.money < price
			vrow.label.add_theme_color_override("font_color", Color(0.8, 0.82, 0.86))
	for key in main.UP_KEYS:
		var lvl: int = main._levels[key]
		var row: Dictionary = _shop_rows[key]
		var pips := "●".repeat(lvl) + "○".repeat(main.UP_MAX - lvl)
		row.label.text = "%s   %s" % [main.UP_NAME[key], pips]
		row.label.add_theme_color_override("font_color", Color(1, 1, 1))
		row.desc.text = main.UP_DESC.get(key, "")
		var buy: Button = row.buy
		if lvl >= main.UP_MAX:
			buy.text = "MAX"
			buy.disabled = true
		else:
			var c: int = main._cost(key)
			buy.text = "$%d" % c
			buy.disabled = main.money < c
		var sell: Button = row.sell
		if lvl > 0:
			sell.text = "+$%d" % int(main.UP_BASECOST[key] * pow(main.UP_COSTMULT, lvl - 1) * SELL_REFUND)
			sell.disabled = false
		else:
			sell.text = "sell"
			sell.disabled = true

func _buy(key: String) -> void:
	if main._audio:
		main._audio.call("play_click")
	if main._levels[key] >= main.UP_MAX:
		return
	var c: int = main._cost(key)
	if main.money < c:
		return
	main.money -= c
	main._levels[key] += 1
	if main._audio:
		main._audio.call("play_cash")
	main._apply_upgrades()
	main._save_game()
	_refresh_shop()

const SELL_REFUND := 0.7   # sell a level back for 70% of what that level cost

## Refund one level of an upgrade (70% of what the last level cost) if you regret it.
func _sell(key: String) -> void:
	if main._audio:
		main._audio.call("play_click")
	if main._levels[key] <= 0:
		return
	var paid: int = int(main.UP_BASECOST[key] * pow(main.UP_COSTMULT, main._levels[key] - 1))
	main.money += int(paid * SELL_REFUND)
	main._levels[key] -= 1
	main._apply_upgrades()
	main._save_game()
	_refresh_shop()

func _buy_cosmetic(key: String) -> void:
	if main._audio:
		main._audio.call("play_click")
	var c: Dictionary = main.COSMETICS[key]
	if main._cosm_owned[key] or main.money < int(c.cost):
		return
	main.money -= int(c.cost)
	main._cosm_owned[key] = true
	if main._audio:
		main._audio.call("play_cash")
	main._apply_cosmetics()
	main._save_game()
	_refresh_shop()

func _pick_cosmetic(key: String, col: Color) -> void:
	if not main._cosm_owned[key]:
		return
	main._cosm_color[key] = col
	if main._audio:
		main._audio.call("play_click")
	main._apply_cosmetics()
	main._save_game()   # persist the chosen colour, not just the unlock
	_refresh_swatch_selection(key)

## Ring the currently-selected swatch (and clear the others) so the chosen colour reads.
func _refresh_swatch_selection(key: String) -> void:
	var r: Dictionary = _cosm_rows.get(key, {})
	if r.is_empty():
		return
	var sel: Color = main._cosm_color[key]
	if r.has("preview"):
		(r.preview as StyleBoxFlat).bg_color = sel
	for e in r.swatch_btns:
		var sb: StyleBoxFlat = e.sb
		if (e.color as Color).is_equal_approx(sel):
			sb.set_border_width_all(3)
			sb.border_color = Color(1, 1, 1)
		else:
			sb.set_border_width_all(0)

## Live-preview the colour under the cursor/focus (before committing): fill the preview box
## with it and ring that swatch yellow, while the currently-SELECTED swatch keeps a white ring.
func _preview_cosmetic(key: String, col: Color) -> void:
	var r: Dictionary = _cosm_rows.get(key, {})
	if r.is_empty():
		return
	if r.has("preview"):
		(r.preview as StyleBoxFlat).bg_color = col
	var sel: Color = main._cosm_color[key]
	for e in r.swatch_btns:
		var sb: StyleBoxFlat = e.sb
		var is_hover: bool = (e.color as Color).is_equal_approx(col)
		var is_sel: bool = (e.color as Color).is_equal_approx(sel)
		sb.set_border_width_all(3 if (is_hover or is_sel) else 0)
		sb.border_color = Color(1.0, 0.9, 0.3) if is_hover else Color(1, 1, 1)

func _refresh_cosmetics() -> void:
	for ck in main.COSM_KEYS:
		var r: Dictionary = _cosm_rows.get(ck, {})
		if r.is_empty():
			continue
		var c: Dictionary = main.COSMETICS[ck]
		if main._cosm_owned[ck]:
			r.buy.text = "OWNED"
			r.buy.disabled = true
			r.swatches.visible = true
			_refresh_swatch_selection(ck)
		else:
			r.buy.text = "$%d" % int(c.cost)
			r.buy.disabled = main.money < int(c.cost)
			r.swatches.visible = false
