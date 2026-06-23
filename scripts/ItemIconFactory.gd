extends RefCounted
class_name ItemIconFactory

const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")

const SIZE := 48

var cache := {}
var palette := {}

func _init() -> void:
    setup_palette()

func setup_palette() -> void:
    palette["outline"] = Color(0.10, 0.11, 0.10, 0.86)
    palette["shadow"] = Color(0.03, 0.03, 0.03, 0.30)
    palette["wood"] = Color(0.68, 0.42, 0.20, 1.0)
    palette["wood_dark"] = Color(0.34, 0.18, 0.08, 1.0)
    palette["stone"] = Color(0.56, 0.60, 0.56, 1.0)
    palette["stone_dark"] = Color(0.30, 0.34, 0.32, 1.0)
    palette["dirt"] = Color(0.42, 0.28, 0.16, 1.0)
    palette["grass"] = Color(0.40, 0.70, 0.34, 1.0)
    palette["sand"] = Color(0.82, 0.70, 0.42, 1.0)
    palette["snow"] = Color(0.88, 0.92, 0.92, 1.0)
    palette["glass"] = Color(0.56, 0.88, 0.98, 0.70)
    palette["copper"] = Color(0.78, 0.42, 0.20, 1.0)
    palette["iron"] = Color(0.78, 0.84, 0.80, 1.0)
    palette["gold"] = Color(0.92, 0.70, 0.32, 1.0)
    palette["night"] = Color(0.22, 0.26, 0.72, 1.0)
    palette["ward"] = Color(0.34, 0.78, 0.94, 1.0)
    palette["rift"] = Color(0.78, 0.34, 0.96, 1.0)
    palette["leather"] = Color(0.52, 0.30, 0.16, 1.0)
    palette["cloth_red"] = Color(0.68, 0.20, 0.18, 1.0)
    palette["cloth_teal"] = Color(0.26, 0.46, 0.42, 1.0)
    palette["berry"] = Color(0.76, 0.16, 0.28, 1.0)
    palette["fish"] = Color(0.44, 0.74, 0.82, 1.0)
    palette["cooked"] = Color(0.72, 0.34, 0.18, 1.0)
    palette["herb"] = Color(0.48, 0.78, 0.44, 1.0)
    palette["frost"] = Color(0.72, 0.92, 0.96, 1.0)
    palette["flame"] = Color(1.0, 0.55, 0.16, 1.0)
    palette["string"] = Color(0.92, 0.82, 0.62, 1.0)

func icon_for(item_id: String) -> Texture2D:
    if cache.has(item_id):
        return cache[item_id]
    var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
    image.fill(Color(0, 0, 0, 0))
    draw_soft_backplate(image, material_for(item_id))
    draw_item(image, item_id)
    add_corner_spark(image, item_id)
    var texture := ImageTexture.create_from_image(image)
    cache[item_id] = texture
    return texture

func draw_item(image: Image, item_id: String) -> void:
    if item_id == "torch":
        draw_torch(image)
    elif item_id == "campfire":
        draw_campfire(image)
    elif item_id == "workbench":
        draw_workbench(image)
    elif item_id == "anvil":
        draw_anvil(image)
    elif item_id == "door":
        draw_door(image)
    elif item_id == "bed":
        draw_bed(image)
    elif item_id == "chest":
        draw_chest(image)
    elif item_id == "furnace":
        draw_furnace(image)
    elif item_id == "spikeTrap":
        draw_spike_trap(image)
    elif item_id in ["wardLantern", "sanctuaryBeacon", "riftAnchor"]:
        draw_ward_object(image, item_id)
    elif item_id == "hunterBow" or item_id == "ironCrossbow":
        draw_bow(image, item_id)
    elif item_id == "fishingRod":
        draw_fishing_rod(image)
    elif is_tool(item_id):
        draw_tool(image, item_id)
    elif item_id in ["hideVest", "stoneArmor", "copperArmor", "ironArmor", "wardArmor"]:
        draw_armor(image, item_id)
    elif item_id in ["trailPack", "expeditionPack"]:
        draw_pack(image, item_id)
    elif item_id in ["trailCharm", "wardAmulet", "compass", "surveyLens"]:
        draw_trinket(image, item_id)
    elif item_id.ends_with("Block") or item_id in ["glass", "cobblestonePath"]:
        draw_block(image, item_id)
    elif item_id in ["logs", "stones", "dirt", "sand", "grass", "mud", "snow"]:
        draw_basic_resource(image, item_id)
    elif item_id in ["berries", "cookedBerries", "aloe", "mirecap", "frostHerb"]:
        draw_forage(image, item_id)
    elif item_id in ["rawFish", "cookedFish", "rawMeat", "cookedMeat", "fieldRation", "hunterStew", "aloeSalve", "wardTonic"]:
        draw_food(image, item_id)
    elif item_id in ["copperOre", "ironOre", "copperVein", "ironVein", "copperIngot", "ironIngot", "nightShard", "relicFragment", "riftCore", "arrows"]:
        draw_crafting_resource(image, item_id)
    else:
        draw_basic_resource(image, item_id)

func draw_soft_backplate(image: Image, color: Color) -> void:
    var bg := color.darkened(0.58)
    bg.a = 0.26
    draw_rect(image, Rect2i(5, 5, 38, 38), bg)
    draw_rect(image, Rect2i(7, 7, 34, 34), Color(1, 1, 1, 0.045))

func draw_block(image: Image, item_id: String) -> void:
    var base: Color = material_for(item_id)
    var top: Color = base.lightened(0.22)
    if item_id == "dirtBlock":
        top = palette["grass"]
    if item_id == "glass":
        base = palette["glass"]
        top = palette["glass"].lightened(0.16)
    var left := base.darkened(0.12)
    var right := base.darkened(0.28)
    if item_id == "cobblestonePath":
        draw_cube(image, top, left, right, 9, 16, 30, 14)
        draw_line(image, Vector2i(14, 25), Vector2i(37, 23), palette["stone_dark"], 2)
        draw_line(image, Vector2i(24, 17), Vector2i(24, 34), palette["stone_dark"], 1)
        draw_line(image, Vector2i(12, 19), Vector2i(25, 25), Color(1, 1, 1, 0.22), 1)
        return
    draw_cube(image, top, left, right)
    draw_line(image, Vector2i(14, 16), Vector2i(25, 11), Color(1, 1, 1, 0.26), 1)
    draw_line(image, Vector2i(10, 22), Vector2i(23, 29), left.lightened(0.20), 1)
    draw_line(image, Vector2i(26, 30), Vector2i(39, 22), right.lightened(0.14), 1)
    if item_id == "woodBlock":
        draw_line(image, Vector2i(15, 17), Vector2i(15, 34), palette["wood_dark"], 2)
        draw_line(image, Vector2i(25, 12), Vector2i(25, 39), palette["wood_dark"], 1)
        draw_line(image, Vector2i(17, 20), Vector2i(22, 22), palette["gold"].darkened(0.18), 1)
    elif item_id == "stoneBlock":
        draw_line(image, Vector2i(11, 25), Vector2i(25, 32), palette["stone_dark"], 1)
        draw_line(image, Vector2i(25, 32), Vector2i(39, 24), palette["stone_dark"], 1)
    elif item_id == "glass":
        draw_line(image, Vector2i(15, 15), Vector2i(33, 33), Color(1, 1, 1, 0.62), 2)

func draw_cube(image: Image, top: Color, left: Color, right: Color, x := 8, y := 11, w := 32, h := 27) -> void:
    var p_top := [Vector2i(x + w / 2, y), Vector2i(x + w, y + 8), Vector2i(x + w / 2, y + 17), Vector2i(x, y + 8)]
    var p_left := [Vector2i(x, y + 8), Vector2i(x + w / 2, y + 17), Vector2i(x + w / 2, y + h), Vector2i(x, y + h - 8)]
    var p_right := [Vector2i(x + w, y + 8), Vector2i(x + w / 2, y + 17), Vector2i(x + w / 2, y + h), Vector2i(x + w, y + h - 8)]
    fill_poly(image, p_left, left)
    fill_poly(image, p_right, right)
    fill_poly(image, p_top, top)
    draw_poly_outline(image, p_top, palette["outline"], 1)
    draw_poly_outline(image, p_left, palette["outline"], 1)
    draw_poly_outline(image, p_right, palette["outline"], 1)

func draw_workbench(image: Image) -> void:
    draw_cube(image, palette["wood"].lightened(0.18), palette["wood"], palette["wood"].darkened(0.20), 8, 13, 32, 25)
    draw_line(image, Vector2i(12, 17), Vector2i(35, 29), palette["wood_dark"], 2)
    draw_line(image, Vector2i(22, 14), Vector2i(22, 39), palette["wood_dark"], 2)

func draw_anvil(image: Image) -> void:
    draw_shadow(image)
    draw_rect(image, Rect2i(12, 30, 24, 5), palette["stone_dark"])
    draw_rect(image, Rect2i(18, 22, 12, 10), palette["stone_dark"])
    draw_rect(image, Rect2i(10, 15, 28, 9), palette["iron"])
    draw_rect(image, Rect2i(34, 17, 5, 5), palette["iron"].darkened(0.12))
    draw_outline_rect(image, Rect2i(10, 15, 29, 20), palette["outline"])

func draw_door(image: Image) -> void:
    draw_shadow(image)
    draw_rect(image, Rect2i(15, 8, 18, 31), palette["wood_dark"])
    draw_rect(image, Rect2i(18, 11, 12, 11), palette["wood"])
    draw_rect(image, Rect2i(18, 25, 12, 11), palette["wood"].darkened(0.10))
    draw_circle(image, Vector2i(29, 24), 2, palette["gold"])
    draw_outline_rect(image, Rect2i(15, 8, 18, 31), palette["outline"])

func draw_bed(image: Image) -> void:
    draw_shadow(image)
    fill_poly(image, [Vector2i(9, 27), Vector2i(32, 17), Vector2i(39, 25), Vector2i(16, 37)], palette["wood_dark"])
    fill_poly(image, [Vector2i(12, 25), Vector2i(30, 17), Vector2i(37, 24), Vector2i(18, 34)], palette["cloth_red"])
    fill_poly(image, [Vector2i(11, 24), Vector2i(20, 20), Vector2i(26, 25), Vector2i(16, 29)], palette["snow"])
    draw_poly_outline(image, [Vector2i(9, 27), Vector2i(32, 17), Vector2i(39, 25), Vector2i(16, 37)], palette["outline"], 1)

func draw_chest(image: Image) -> void:
    draw_shadow(image)
    draw_rect(image, Rect2i(10, 17, 28, 18), palette["wood"])
    draw_rect(image, Rect2i(10, 14, 28, 8), palette["wood"].lightened(0.08))
    draw_rect(image, Rect2i(22, 21, 5, 6), palette["gold"])
    draw_line(image, Vector2i(10, 22), Vector2i(38, 22), palette["wood_dark"], 2)
    draw_outline_rect(image, Rect2i(10, 14, 28, 21), palette["outline"])

func draw_furnace(image: Image) -> void:
    draw_cube(image, palette["stone"].lightened(0.10), palette["stone"], palette["stone_dark"], 9, 12, 30, 27)
    draw_rect(image, Rect2i(17, 22, 14, 10), palette["stone_dark"])
    draw_rect(image, Rect2i(19, 27, 10, 3), palette["flame"])

func draw_campfire(image: Image) -> void:
    draw_shadow(image)
    draw_line(image, Vector2i(13, 31), Vector2i(35, 22), palette["wood_dark"], 5)
    draw_line(image, Vector2i(14, 22), Vector2i(36, 31), palette["wood"], 5)
    fill_poly(image, [Vector2i(24, 11), Vector2i(31, 26), Vector2i(24, 35), Vector2i(17, 26)], palette["flame"])
    fill_poly(image, [Vector2i(24, 17), Vector2i(28, 27), Vector2i(24, 32), Vector2i(20, 27)], palette["gold"])
    draw_poly_outline(image, [Vector2i(24, 11), Vector2i(31, 26), Vector2i(24, 35), Vector2i(17, 26)], palette["outline"], 1)

func draw_torch(image: Image) -> void:
    draw_line(image, Vector2i(22, 38), Vector2i(28, 15), palette["wood"], 5)
    draw_line(image, Vector2i(21, 39), Vector2i(27, 16), palette["outline"], 1)
    fill_poly(image, [Vector2i(25, 6), Vector2i(33, 18), Vector2i(25, 27), Vector2i(17, 18)], palette["flame"])
    fill_poly(image, [Vector2i(25, 11), Vector2i(29, 19), Vector2i(25, 24), Vector2i(21, 19)], palette["gold"])

func draw_spike_trap(image: Image) -> void:
    draw_rect(image, Rect2i(10, 31, 28, 5), palette["wood_dark"])
    for x in [15, 24, 33]:
        fill_poly(image, [Vector2i(x, 12), Vector2i(x + 5, 31), Vector2i(x - 5, 31)], palette["stone"])
        draw_poly_outline(image, [Vector2i(x, 12), Vector2i(x + 5, 31), Vector2i(x - 5, 31)], palette["outline"], 1)

func draw_ward_object(image: Image, item_id: String) -> void:
    var core: Color = palette["rift"] if item_id == "riftAnchor" else palette["ward"]
    draw_shadow(image)
    draw_circle(image, Vector2i(24, 22), 10, core)
    draw_circle(image, Vector2i(24, 22), 5, core.lightened(0.32))
    draw_line(image, Vector2i(15, 32), Vector2i(33, 14), palette["gold"], 3)
    draw_line(image, Vector2i(15, 14), Vector2i(33, 32), palette["gold"], 3)
    if item_id != "wardLantern":
        draw_rect(image, Rect2i(14, 34, 20, 5), palette["stone_dark"])
    draw_circle_outline(image, Vector2i(24, 22), 11, palette["outline"])

func draw_tool(image: Image, item_id: String) -> void:
    var head := material_for(item_id)
    if item_id.ends_with("Sword") or item_id == "nightBlade":
        draw_line(image, Vector2i(17, 37), Vector2i(28, 18), palette["wood_dark"], 5)
        draw_line(image, Vector2i(18, 25), Vector2i(32, 32), head, 4)
        draw_line(image, Vector2i(25, 18), Vector2i(33, 7), head, 6)
        if item_id == "nightBlade":
            draw_line(image, Vector2i(28, 18), Vector2i(34, 8), palette["ward"], 2)
        return
    draw_line(image, Vector2i(17, 38), Vector2i(30, 13), palette["wood_dark"], 5)
    if item_id.ends_with("Pickaxe"):
        draw_line(image, Vector2i(15, 14), Vector2i(37, 18), head, 6)
        draw_line(image, Vector2i(12, 16), Vector2i(17, 10), head, 4)
    elif item_id.ends_with("Shovel"):
        fill_poly(image, [Vector2i(27, 9), Vector2i(38, 18), Vector2i(29, 28), Vector2i(19, 18)], head)
        draw_poly_outline(image, [Vector2i(27, 9), Vector2i(38, 18), Vector2i(29, 28), Vector2i(19, 18)], palette["outline"], 1)
    else:
        fill_poly(image, [Vector2i(25, 9), Vector2i(39, 19), Vector2i(29, 30), Vector2i(19, 18)], head)
        draw_line(image, Vector2i(23, 11), Vector2i(31, 27), head.darkened(0.18), 3)

func draw_bow(image: Image, item_id: String) -> void:
    if item_id == "ironCrossbow":
        draw_line(image, Vector2i(8, 20), Vector2i(40, 20), palette["iron"], 5)
        draw_line(image, Vector2i(10, 18), Vector2i(38, 18), palette["iron"].lightened(0.22), 1)
        draw_line(image, Vector2i(24, 15), Vector2i(24, 38), palette["wood_dark"], 6)
        draw_line(image, Vector2i(26, 17), Vector2i(26, 34), palette["wood"].lightened(0.10), 1)
        draw_line(image, Vector2i(11, 17), Vector2i(37, 23), palette["string"], 1)
        draw_line(image, Vector2i(12, 24), Vector2i(36, 16), palette["string"], 1)
        draw_line(image, Vector2i(24, 20), Vector2i(40, 10), palette["stone"], 2)
        draw_circle(image, Vector2i(24, 20), 2, palette["gold"])
        return
    draw_arc_points(image, Vector2i(23, 24), 17, palette["wood"], true)
    draw_line(image, Vector2i(13, 9), Vector2i(13, 39), palette["string"], 2)
    draw_line(image, Vector2i(17, 24), Vector2i(35, 24), palette["string"], 2)
    fill_poly(image, [Vector2i(36, 24), Vector2i(30, 20), Vector2i(30, 28)], palette["stone"])

func draw_fishing_rod(image: Image) -> void:
    draw_line(image, Vector2i(14, 39), Vector2i(31, 8), palette["wood"], 4)
    draw_line(image, Vector2i(31, 9), Vector2i(37, 30), palette["string"], 1)
    draw_circle(image, Vector2i(37, 34), 3, palette["fish"])

func draw_armor(image: Image, item_id: String) -> void:
    var mat := material_for(item_id)
    fill_poly(image, [Vector2i(15, 10), Vector2i(33, 10), Vector2i(38, 21), Vector2i(33, 39), Vector2i(15, 39), Vector2i(10, 21)], mat)
    draw_rect(image, Rect2i(19, 18, 10, 18), mat.lightened(0.12))
    draw_line(image, Vector2i(15, 24), Vector2i(33, 24), mat.darkened(0.22), 2)
    draw_poly_outline(image, [Vector2i(15, 10), Vector2i(33, 10), Vector2i(38, 21), Vector2i(33, 39), Vector2i(15, 39), Vector2i(10, 21)], palette["outline"], 1)

func draw_pack(image: Image, item_id: String) -> void:
    var mat: Color = palette["cloth_teal"] if item_id == "expeditionPack" else palette["leather"]
    draw_rect(image, Rect2i(14, 12, 20, 27), mat)
    draw_rect(image, Rect2i(17, 22, 14, 10), mat.lightened(0.12))
    draw_line(image, Vector2i(17, 10), Vector2i(11, 28), palette["wood_dark"], 3)
    draw_line(image, Vector2i(31, 10), Vector2i(37, 28), palette["wood_dark"], 3)
    draw_outline_rect(image, Rect2i(14, 12, 20, 27), palette["outline"])

func draw_trinket(image: Image, item_id: String) -> void:
    if item_id == "compass":
        draw_circle(image, Vector2i(24, 24), 14, palette["gold"])
        draw_circle(image, Vector2i(24, 24), 10, palette["stone_dark"])
        fill_poly(image, [Vector2i(24, 13), Vector2i(28, 25), Vector2i(22, 23)], palette["ward"])
        fill_poly(image, [Vector2i(24, 35), Vector2i(20, 23), Vector2i(26, 25)], palette["cloth_red"])
        return
    if item_id == "surveyLens":
        draw_circle(image, Vector2i(22, 21), 12, palette["glass"])
        draw_circle_outline(image, Vector2i(22, 21), 13, palette["copper"])
        draw_line(image, Vector2i(31, 31), Vector2i(39, 39), palette["copper"], 5)
        return
    draw_circle(image, Vector2i(24, 25), 10, material_for(item_id))
    draw_line(image, Vector2i(14, 13), Vector2i(34, 13), palette["string"], 2)
    draw_line(image, Vector2i(14, 13), Vector2i(24, 25), palette["string"], 2)
    draw_line(image, Vector2i(34, 13), Vector2i(24, 25), palette["string"], 2)

func draw_basic_resource(image: Image, item_id: String) -> void:
    if item_id == "logs":
        draw_log(image, Vector2i(13, 19), Vector2i(34, 14))
        draw_log(image, Vector2i(14, 29), Vector2i(35, 24))
    elif item_id == "stones":
        draw_rock(image, Vector2i(18, 25), palette["stone"], 8)
        draw_rock(image, Vector2i(30, 28), palette["stone_dark"], 7)
    else:
        draw_block(image, item_id)

func draw_forage(image: Image, item_id: String) -> void:
    if item_id == "berries" or item_id == "cookedBerries":
        for pos in [Vector2i(20, 20), Vector2i(28, 19), Vector2i(18, 29), Vector2i(29, 29)]:
            draw_circle(image, pos, 5, material_for(item_id))
        draw_line(image, Vector2i(21, 15), Vector2i(29, 32), palette["herb"], 2)
    elif item_id == "aloe":
        for angle in [-12, 0, 12]:
            draw_line(image, Vector2i(24, 36), Vector2i(24 + angle, 12), palette["herb"], 5)
    elif item_id == "mirecap":
        draw_line(image, Vector2i(24, 34), Vector2i(24, 23), palette["snow"], 5)
        fill_poly(image, [Vector2i(13, 23), Vector2i(24, 12), Vector2i(35, 23)], palette["cloth_red"])
        draw_line(image, Vector2i(14, 23), Vector2i(34, 23), palette["cloth_red"], 7)
    else:
        draw_line(image, Vector2i(24, 36), Vector2i(24, 12), palette["frost"], 4)
        draw_line(image, Vector2i(24, 24), Vector2i(14, 18), palette["herb"], 3)
        draw_line(image, Vector2i(24, 26), Vector2i(34, 19), palette["herb"], 3)

func draw_food(image: Image, item_id: String) -> void:
    if item_id in ["rawFish", "cookedFish"]:
        var mat := material_for(item_id)
        draw_circle(image, Vector2i(23, 24), 10, mat)
        fill_poly(image, [Vector2i(33, 24), Vector2i(42, 17), Vector2i(42, 31)], mat.darkened(0.12))
        draw_circle(image, Vector2i(19, 21), 1, palette["outline"])
    elif item_id in ["rawMeat", "cookedMeat", "fieldRation"]:
        draw_circle(image, Vector2i(23, 25), 12, material_for(item_id))
        draw_circle(image, Vector2i(16, 19), 5, material_for(item_id).lightened(0.10))
        draw_line(image, Vector2i(30, 29), Vector2i(38, 36), palette["snow"], 4)
    elif item_id == "hunterStew":
        draw_rect(image, Rect2i(13, 24, 22, 10), palette["stone_dark"])
        draw_circle(image, Vector2i(24, 23), 11, palette["cooked"])
        draw_line(image, Vector2i(13, 24), Vector2i(35, 24), palette["gold"], 2)
    else:
        var mat := material_for(item_id)
        draw_rect(image, Rect2i(18, 15, 12, 22), mat)
        draw_rect(image, Rect2i(16, 12, 16, 5), palette["gold"])
        draw_rect(image, Rect2i(19, 20, 10, 9), mat.lightened(0.20))
        draw_outline_rect(image, Rect2i(18, 15, 12, 22), palette["outline"])

func draw_crafting_resource(image: Image, item_id: String) -> void:
    if item_id == "arrows":
        for y in [18, 26, 34]:
            draw_line(image, Vector2i(11, y), Vector2i(35, y - 7), palette["string"], 2)
            fill_poly(image, [Vector2i(36, y - 7), Vector2i(31, y - 11), Vector2i(32, y - 4)], palette["stone"])
    elif item_id.ends_with("Ingot"):
        fill_poly(image, [Vector2i(12, 28), Vector2i(20, 18), Vector2i(38, 18), Vector2i(30, 32)], material_for(item_id))
        draw_poly_outline(image, [Vector2i(12, 28), Vector2i(20, 18), Vector2i(38, 18), Vector2i(30, 32)], palette["outline"], 1)
        draw_line(image, Vector2i(20, 21), Vector2i(34, 21), Color(1, 1, 1, 0.32), 2)
    elif item_id in ["nightShard", "relicFragment", "riftCore"]:
        var mat := material_for(item_id)
        fill_poly(image, [Vector2i(24, 7), Vector2i(36, 22), Vector2i(27, 41), Vector2i(14, 24)], mat)
        fill_poly(image, [Vector2i(24, 12), Vector2i(30, 23), Vector2i(25, 34), Vector2i(19, 24)], mat.lightened(0.25))
        draw_poly_outline(image, [Vector2i(24, 7), Vector2i(36, 22), Vector2i(27, 41), Vector2i(14, 24)], palette["outline"], 1)
    else:
        draw_rock(image, Vector2i(24, 25), material_for(item_id), 12)
        draw_circle(image, Vector2i(28, 21), 3, material_for(item_id).lightened(0.28))

func draw_log(image: Image, start: Vector2i, end: Vector2i) -> void:
    draw_line(image, start, end, palette["outline"], 8)
    draw_line(image, start, end, palette["wood"], 6)
    draw_circle(image, end, 4, palette["wood"].lightened(0.18))
    draw_circle_outline(image, end, 4, palette["wood_dark"])

func draw_rock(image: Image, center: Vector2i, color: Color, radius: int) -> void:
    fill_poly(image, [
        center + Vector2i(-radius, -2),
        center + Vector2i(-radius / 2, -radius),
        center + Vector2i(radius / 2, -radius + 1),
        center + Vector2i(radius, -1),
        center + Vector2i(radius / 2, radius),
        center + Vector2i(-radius / 2, radius - 1)
    ], color)
    draw_poly_outline(image, [
        center + Vector2i(-radius, -2),
        center + Vector2i(-radius / 2, -radius),
        center + Vector2i(radius / 2, -radius + 1),
        center + Vector2i(radius, -1),
        center + Vector2i(radius / 2, radius),
        center + Vector2i(-radius / 2, radius - 1)
    ], palette["outline"], 1)

func draw_shadow(image: Image) -> void:
    draw_rect(image, Rect2i(10, 36, 28, 4), palette["shadow"])

func add_corner_spark(image: Image, item_id: String) -> void:
    if item_id.find("ward") >= 0 or item_id.find("night") >= 0 or item_id == "riftCore" or item_id == "riftAnchor" or item_id == "surveyLens":
        var color := material_for(item_id).lightened(0.35)
        draw_line(image, Vector2i(38, 8), Vector2i(38, 14), color, 1)
        draw_line(image, Vector2i(35, 11), Vector2i(41, 11), color, 1)

func is_tool(item_id: String) -> bool:
    return item_id.ends_with("Axe") or item_id.ends_with("Pickaxe") or item_id.ends_with("Shovel") or item_id.ends_with("Sword") or item_id == "nightBlade"

func material_for(item_id: String) -> Color:
    if item_id == "nightBlade" or item_id == "nightShard":
        return palette["night"]
    if item_id == "riftCore" or item_id == "riftAnchor":
        return palette["rift"]
    if item_id.find("ward") >= 0 or item_id == "sanctuaryBeacon" or item_id == "surveyLens":
        return palette["ward"]
    if item_id.find("iron") >= 0:
        return palette["iron"]
    if item_id.find("copper") >= 0:
        return palette["copper"]
    if item_id.find("stone") >= 0 or item_id in ["stones", "cobblestonePath", "furnace", "anvil", "relicFragment"]:
        return palette["stone"]
    if item_id.find("wood") >= 0 or item_id in ["logs", "workbench", "door", "chest", "campfire", "torch", "hunterBow", "fishingRod"]:
        return palette["wood"]
    if item_id in ["dirt", "dirtBlock", "mud"]:
        return palette["dirt"]
    if item_id == "sand":
        return palette["sand"]
    if item_id == "snow":
        return palette["snow"]
    if item_id == "glass":
        return palette["glass"]
    if item_id in ["grass", "aloe"]:
        return palette["herb"]
    if item_id in ["berries", "cookedBerries"]:
        return palette["berry"]
    if item_id == "mirecap":
        return palette["cloth_red"]
    if item_id == "frostHerb":
        return palette["frost"]
    if item_id == "rawFish":
        return palette["fish"]
    if item_id in ["cookedFish", "cookedMeat", "hunterStew", "fieldRation"]:
        return palette["cooked"]
    if item_id == "rawMeat":
        return palette["cloth_red"]
    if item_id in ["hide", "hideVest", "trailPack", "trailCharm"]:
        return palette["leather"]
    if item_id == "expeditionPack":
        return palette["cloth_teal"]
    if item_id in ["compass", "wardAmulet", "aloeSalve", "wardTonic"]:
        return palette["gold"]
    return palette["stone"]

func draw_rect(image: Image, rect: Rect2i, color: Color) -> void:
    var start_x: int = clampi(rect.position.x, 0, SIZE - 1)
    var start_y: int = clampi(rect.position.y, 0, SIZE - 1)
    var end_x: int = clampi(rect.position.x + rect.size.x - 1, 0, SIZE - 1)
    var end_y: int = clampi(rect.position.y + rect.size.y - 1, 0, SIZE - 1)
    for y in range(start_y, end_y + 1):
        for x in range(start_x, end_x + 1):
            blend_pixel(image, x, y, color)

func draw_outline_rect(image: Image, rect: Rect2i, color: Color) -> void:
    draw_line(image, rect.position, rect.position + Vector2i(rect.size.x, 0), color, 1)
    draw_line(image, rect.position, rect.position + Vector2i(0, rect.size.y), color, 1)
    draw_line(image, rect.position + Vector2i(0, rect.size.y), rect.position + rect.size, color, 1)
    draw_line(image, rect.position + Vector2i(rect.size.x, 0), rect.position + rect.size, color, 1)

func draw_circle(image: Image, center: Vector2i, radius: int, color: Color) -> void:
    for y in range(center.y - radius, center.y + radius + 1):
        for x in range(center.x - radius, center.x + radius + 1):
            var dx := x - center.x
            var dy := y - center.y
            if dx * dx + dy * dy <= radius * radius:
                blend_pixel(image, x, y, color)

func draw_circle_outline(image: Image, center: Vector2i, radius: int, color: Color) -> void:
    for i in range(32):
        var a := TAU * float(i) / 32.0
        blend_pixel(image, center.x + roundi(cos(a) * radius), center.y + roundi(sin(a) * radius), color)

func draw_line(image: Image, start: Vector2i, end: Vector2i, color: Color, thickness := 1) -> void:
    var steps: int = max(abs(end.x - start.x), abs(end.y - start.y))
    if steps <= 0:
        draw_circle(image, start, max(1, thickness / 2), color)
        return
    var radius: int = max(0, thickness / 2)
    for i in range(steps + 1):
        var t := float(i) / float(steps)
        var x := roundi(lerpf(float(start.x), float(end.x), t))
        var y := roundi(lerpf(float(start.y), float(end.y), t))
        if thickness <= 1:
            blend_pixel(image, x, y, color)
        else:
            draw_circle(image, Vector2i(x, y), radius, color)

func draw_arc_points(image: Image, center: Vector2i, radius: int, color: Color, right_side := true) -> void:
    var x_offset := 7 if right_side else -7
    for i in range(-14, 15):
        var y := center.y + i
        var curve := int(round(sqrt(maxf(0.0, float(radius * radius - i * i))) * 0.55))
        var x := center.x + x_offset + curve if right_side else center.x + x_offset - curve
        draw_circle(image, Vector2i(x, y), 2, color)

func fill_poly(image: Image, points: Array, color: Color) -> void:
    if points.size() < 3:
        return
    var min_y := SIZE - 1
    var max_y := 0
    for p in points:
        var point := p as Vector2i
        min_y = mini(min_y, point.y)
        max_y = maxi(max_y, point.y)
    min_y = clampi(min_y, 0, SIZE - 1)
    max_y = clampi(max_y, 0, SIZE - 1)
    for y in range(min_y, max_y + 1):
        var intersections := []
        for i in range(points.size()):
            var a := points[i] as Vector2i
            var b := points[(i + 1) % points.size()] as Vector2i
            if (a.y <= y and b.y > y) or (b.y <= y and a.y > y):
                var t := float(y - a.y) / float(b.y - a.y)
                intersections.append(roundi(lerpf(float(a.x), float(b.x), t)))
        intersections.sort()
        for i in range(0, intersections.size(), 2):
            if i + 1 >= intersections.size():
                break
            var start_x: int = clampi(int(intersections[i]), 0, SIZE - 1)
            var end_x: int = clampi(int(intersections[i + 1]), 0, SIZE - 1)
            for x in range(start_x, end_x + 1):
                blend_pixel(image, x, y, color)

func draw_poly_outline(image: Image, points: Array, color: Color, thickness := 1) -> void:
    for i in range(points.size()):
        draw_line(image, points[i] as Vector2i, points[(i + 1) % points.size()] as Vector2i, color, thickness)

func blend_pixel(image: Image, x: int, y: int, color: Color) -> void:
    if x < 0 or y < 0 or x >= SIZE or y >= SIZE:
        return
    if color.a >= 0.99:
        image.set_pixel(x, y, color)
        return
    var under := image.get_pixel(x, y)
    var alpha := color.a
    var out := Color(
        lerpf(under.r, color.r, alpha),
        lerpf(under.g, color.g, alpha),
        lerpf(under.b, color.b, alpha),
        clampf(under.a + alpha * (1.0 - under.a), 0.0, 1.0)
    )
    image.set_pixel(x, y, out)
