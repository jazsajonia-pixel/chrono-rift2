extends Node3D

# CHRONO RIFT - 3D MOBA map integration experiment.
# The supplied MLBB map FBX is now the actual battlefield.
const MAP_FBX := "res://assets/source/map mlbb 2022_fbx_Scene.fbx"
const HERO_SPEED := 8.0
const CAMERA_OFFSET := Vector3(-13.0, 19.5, 13.0)
const CAMERA_FOV := 48.0
const SKILL_RANGES := [18.0, 28.0, 22.0]
const SKILL_UNLOCK_LEVEL := [1, 1, 3]

var map_root: Node3D
var player: CharacterBody3D
var camera: Camera3D
var player_floor_y := 0.0
var map_floor_y := 0.0
var game_time := 0.0
var attack_cd := 0.0
var level := 1
var exp := 0.0
var next_exp := 140.0
var upgrade_points := 0
var skill_levels := [1, 0, 0]
var moving := Vector2.ZERO
var joystick_touch := -1
var skill_touch := -1
var aiming_skill := -1
var aim_vector := Vector2(0, -1)
var aim_origin := Vector2.ZERO
var aim_indicator: Node3D
var menu: Control
var hud: CanvasLayer
var info_label: Label
var level_label: Label
var target_label: Label
var skill_buttons: Array[Button] = []
var upgrade_buttons: Array[Button] = []
var game_started := false
var hero_name := "Karrie"
var hero_color := Color("35d5ff")
var hero_role := "MARKSMAN"
var hero_spawn_marker: Node3D
var map_bounds := AABB(Vector3(-150, -10, -150), Vector3(300, 30, 300))
var joystick_base: Panel
var joystick_knob: Panel
var joystick_center := Vector2(113.0, 605.0)
const JOYSTICK_RADIUS := 66.0
const JOYSTICK_KNOB_RADIUS := 34.0

func _ready() -> void:
    _build_environment()
    _load_supplied_map()
    _build_interface()
    _show_menu()

func _build_environment() -> void:
    var env := WorldEnvironment.new()
    var e := Environment.new()
    e.background_mode = Environment.BG_COLOR
    e.background_color = Color("081018")
    e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    e.ambient_light_color = Color(0.72, 0.78, 0.84)
    e.ambient_light_energy = 0.28
    e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    env.environment = e
    add_child(env)

    var sun := DirectionalLight3D.new()
    sun.name = "MapSun"
    # High, mostly overhead light so the imported map keeps its detail
    # without the washed-out look from the previous experiment.
    sun.position = Vector3(0.0, 80.0, 0.0)
    sun.rotation_degrees = Vector3(-62.0, -35.0, 0.0)
    sun.light_energy = 0.24
    sun.shadow_enabled = true
    add_child(sun)

func _load_supplied_map() -> void:
    if not ResourceLoader.exists(MAP_FBX):
        push_error("Map FBX not found: " + MAP_FBX)
        return

    var packed := load(MAP_FBX) as PackedScene
    if packed == null:
        push_error("Godot could not import the supplied FBX as a PackedScene.")
        return

    # If the FBX is already instantiated in main.tscn, reuse that editor-visible instance.
    var existing_map: Node3D = _find_editor_map_instance()
    if existing_map != null:
        map_root = existing_map
    else:
        map_root = packed.instantiate() as Node3D
    if map_root == null:
        push_error("The supplied FBX did not produce a Node3D scene.")
        return
    if map_root.get_parent() == null:
        map_root.name = "MLBB_Map_2022"
        add_child(map_root)
    else:
        map_root.name = "MLBB_Map_2022"
    _tune_imported_map_visuals()
    _build_named_map_collisions()

    # The FBX contains named base/tower objects. Use the blue base as the
    # player's spawn reference instead of recreating the map geometry.
    hero_spawn_marker = _find_named_node(map_root, ["ML_5v5_jidi_blue", "ML_5v5_bluejidi_01", "bluejidi"])
    if hero_spawn_marker == null:
        hero_spawn_marker = _find_named_node(map_root, ["bluehomeTowernew_049_add"])

    map_bounds = _calculate_map_bounds(map_root)
    if hero_spawn_marker != null:
        map_floor_y = hero_spawn_marker.global_position.y
    else:
        map_floor_y = map_bounds.position.y

    # Collision is generated only from the FBX's explicitly named wall/tower
    # geometry. We do NOT create a blanket invisible floor or walls across the map.

func _find_editor_map_instance() -> Node3D:
    for child in get_children():
        if child is Node3D:
            var n := child.name.to_lower()
            if "map mlbb" in n or "mlbb_map" in n:
                return child as Node3D
    return null

func _build_named_map_collisions() -> void:
    # Build collision only from map objects that are clearly intended to be
    # solid in the supplied source FBX. The source contains explicit names
    # such as waiweiqiang/jidiwaiqiang/jiqiwaiqiang/weiqiang for walls and
    # outsidestone_01..37 for the stone obstacles.
    #
    # Towers are handled separately with a small cylinder around their main
    # tower objects. We intentionally do NOT collide every object containing
    # the word "tower", because the FBX has many decorative tower sub-meshes
    # whose imported bounds can create the "invisible wall near turret" bug.
    var old: Node = get_node_or_null("MapWallCollisions")
    if old != null:
        old.queue_free()

    var body: StaticBody3D = StaticBody3D.new()
    body.name = "MapWallCollisions"
    body.collision_layer = 1
    body.collision_mask = 1
    add_child(body)

    var wall_count := 0
    var tower_count := 0
    var stack: Array[Node] = [map_root]
    while not stack.is_empty():
        var n: Node = stack.pop_back()
        if n is MeshInstance3D:
            var mesh_node: MeshInstance3D = n as MeshInstance3D
            var node_name := mesh_node.name
            if _is_named_wall_mesh(node_name):
                var mesh: Mesh = mesh_node.mesh
                if mesh != null:
                    var faces: PackedVector3Array = mesh.get_faces()
                    if faces.size() >= 3:
                        var xform: Transform3D = global_transform.affine_inverse() * mesh_node.global_transform
                        for i in faces.size():
                            faces[i] = xform * faces[i]
                        var shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
                        shape.set_faces(faces)
                        var collision := CollisionShape3D.new()
                        collision.name = "WallCollision_%d" % wall_count
                        collision.shape = shape
                        body.add_child(collision)
                        wall_count += 1
            elif _is_main_tower_mesh(node_name):
                _add_tower_collision(body, mesh_node, tower_count)
                tower_count += 1
        for child in n.get_children():
            stack.append(child)

    print("Generated map wall collisions: ", wall_count, " | tower blockers: ", tower_count)

func _is_named_wall_mesh(node_name: String) -> bool:
    var s := node_name.to_lower()
    return ("waiweiqiang" in s) or ("jidiwaiqiang" in s) or ("jiqiwaiqiang" in s) or ("weiqiang" in s) or ("outsidestone" in s)

func _is_main_tower_mesh(node_name: String) -> bool:
    var s := node_name.to_lower()
    return s.begins_with("red_tower_") or s.begins_with("blue_tower_") or s.begins_with("redtower_049_add") or s.begins_with("bluetower_049_add") or s.begins_with("redhometowernew_049_add") or s.begins_with("bluehometowernew_049_add")

func _add_tower_collision(body: StaticBody3D, mesh_node: MeshInstance3D, index: int) -> void:
    var a := mesh_node.get_aabb()
    var center_local := a.get_center()
    var center_world := mesh_node.global_transform * center_local
    var sx: float = max(a.size.x * mesh_node.global_transform.basis.x.length(), a.size.x * 0.5)
    var sz: float = max(a.size.z * mesh_node.global_transform.basis.z.length(), a.size.z * 0.5)
    var radius: float = clamp(max(sx, sz) * 0.35, 0.8, 2.2)
    var height: float = clamp(a.size.y * 0.55, 1.0, 5.0)
    var shape := CylinderShape3D.new()
    shape.radius = radius
    shape.height = height
    var collision := CollisionShape3D.new()
    collision.name = "TowerCollision_%d" % index
    collision.shape = shape
    collision.global_position = Vector3(center_world.x, center_world.y + height * 0.15, center_world.z)
    body.add_child(collision)

func _tune_imported_map_visuals() -> void:
    # The source FBX is intentionally very bright in Godot with the default
    # lighting. Keep its original textures, but slightly reduce their
    # albedo so terrain, grass, walls and structures retain detail.
    var stack: Array[Node] = [map_root]
    while not stack.is_empty():
        var n: Node = stack.pop_back()
        if n is MeshInstance3D:
            var mesh_node: MeshInstance3D = n as MeshInstance3D
            var mesh: Mesh = mesh_node.mesh
            if mesh != null:
                for surface in mesh.get_surface_count():
                    var mat: Material = mesh.surface_get_material(surface)
                    if mat is StandardMaterial3D:
                        var tuned: StandardMaterial3D = (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
                        tuned.albedo_color = tuned.albedo_color * Color(0.70, 0.70, 0.70, 1.0)
                        mesh_node.set_surface_override_material(surface, tuned)
        for child in n.get_children():
            stack.append(child)

func _find_named_node(root: Node, wanted: Array[String]) -> Node3D:
    var wanted_lower: Array[String] = []
    for s in wanted:
        wanted_lower.append(s.to_lower())
    var stack: Array[Node] = [root]
    while not stack.is_empty():
        var n: Node = stack.pop_back()
        var node_name := n.name.to_lower()
        for key in wanted_lower:
            if key in node_name and n is Node3D:
                return n as Node3D
        for child in n.get_children():
            stack.append(child)
    return null

func _calculate_map_bounds(root: Node3D) -> AABB:
    var first := true
    var result := AABB()
    var stack: Array[Node] = [root]
    while not stack.is_empty():
        var n: Node = stack.pop_back()
        if n is MeshInstance3D:
            var mesh_node: MeshInstance3D = n as MeshInstance3D
            var a := mesh_node.get_aabb()
            var t := mesh_node.global_transform
            var corners := [
                Vector3(a.position.x, a.position.y, a.position.z),
                Vector3(a.end.x, a.position.y, a.position.z),
                Vector3(a.position.x, a.end.y, a.position.z),
                Vector3(a.position.x, a.position.y, a.end.z),
                Vector3(a.end.x, a.end.y, a.position.z),
                Vector3(a.end.x, a.position.y, a.end.z),
                Vector3(a.position.x, a.end.y, a.end.z),
                Vector3(a.end.x, a.end.y, a.end.z)
            ]
            for c in corners:
                var wp: Vector3 = t * Vector3(c)
                if first:
                    result = AABB(wp, Vector3.ZERO)
                    first = false
                else:
                    result = result.expand(wp)
        for child in n.get_children():
            stack.append(child)
    return result if not first else AABB(Vector3(-150, -10, -150), Vector3(300, 30, 300))

func _spawn_player() -> void:
    if is_instance_valid(player):
        player.queue_free()
        player = null

    player = CharacterBody3D.new()
    player.name = "Player"
    player.collision_layer = 1
    player.collision_mask = 1
    add_child(player)

    var spawn := Vector3(0.0, map_floor_y, 0.0)
    if hero_spawn_marker != null:
        spawn = hero_spawn_marker.global_position
    player.position = spawn
    player_floor_y = spawn.y

    var collision := CollisionShape3D.new()
    var capsule_shape := CapsuleShape3D.new()
    capsule_shape.radius = 0.50
    capsule_shape.height = 2.2
    collision.shape = capsule_shape
    collision.position.y = 1.1
    player.add_child(collision)

    # Simple temporary hero representation. This is intentionally the only
    # character spawned for this experiment.
    var body := MeshInstance3D.new()
    var capsule := CapsuleMesh.new()
    capsule.radius = 0.58
    capsule.height = 2.2
    body.mesh = capsule
    body.material_override = _mat(hero_color)
    body.position.y = 1.1
    player.add_child(body)

    var marker := MeshInstance3D.new()
    var ring := TorusMesh.new()
    ring.inner_radius = 0.9
    ring.outer_radius = 1.05
    marker.mesh = ring
    marker.material_override = _mat(Color(0.2, 0.85, 1.0, 0.8))
    marker.position.y = 0.08
    player.add_child(marker)

    if camera == null:
        camera = Camera3D.new()
        camera.current = true
        camera.fov = CAMERA_FOV
        add_child(camera)
    _update_camera()

func _mat(c: Color) -> StandardMaterial3D:
    var m := StandardMaterial3D.new()
    m.albedo_color = c
    m.roughness = 0.72
    return m

func _build_interface() -> void:
    menu = Control.new()
    menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    add_child(menu)
    _build_menu_contents()

func _panel_style(color: Color) -> StyleBoxFlat:
    var s := StyleBoxFlat.new()
    s.bg_color = color
    s.corner_radius_top_left = 18
    s.corner_radius_top_right = 18
    s.corner_radius_bottom_left = 18
    s.corner_radius_bottom_right = 18
    s.border_width_left = 2
    s.border_width_right = 2
    s.border_width_top = 2
    s.border_width_bottom = 2
    s.border_color = Color(1, 1, 1, 0.15)
    return s

func _build_menu_contents() -> void:
    var bg := ColorRect.new()
    bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    bg.color = Color("08121c")
    menu.add_child(bg)
    var title := Label.new()
    title.text = "CHRONO RIFT"
    title.position = Vector2(0, 80)
    title.size = Vector2(1280, 70)
    title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    title.add_theme_font_size_override("font_size", 52)
    menu.add_child(title)
    var sub := Label.new()
    sub.text = "3D MOBILE MOBA • IMPORTED MAP TEST"
    sub.position = Vector2(0, 145)
    sub.size = Vector2(1280, 35)
    sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    sub.add_theme_font_size_override("font_size", 18)
    menu.add_child(sub)
    var play := Button.new()
    play.text = "PLAY"
    play.position = Vector2(520, 270)
    play.size = Vector2(240, 90)
    play.add_theme_font_size_override("font_size", 32)
    play.pressed.connect(_start_game)
    menu.add_child(play)
    var heroes := Button.new()
    heroes.text = "HEROES"
    heroes.position = Vector2(545, 500)
    heroes.size = Vector2(190, 60)
    heroes.pressed.connect(_show_heroes)
    menu.add_child(heroes)
    var hint := Label.new()
    hint.text = "IMPORTED 3D MAP • WALK TEST • FLOOR SKILL INDICATORS"
    hint.position = Vector2(0, 610)
    hint.size = Vector2(1280, 30)
    hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    hint.modulate = Color(0.7, 0.8, 0.85, 1)
    menu.add_child(hint)

func _show_menu() -> void:
    menu.visible = true

func _start_game() -> void:
    menu.visible = false
    game_started = true
    _spawn_player()
    _build_hud()

func _show_heroes() -> void:
    var p := Panel.new()
    p.position = Vector2(330, 150)
    p.size = Vector2(620, 430)
    p.add_theme_stylebox_override("panel", _panel_style(Color("101e2b")))
    menu.add_child(p)
    var l := Label.new()
    l.text = "HEROES"
    l.position = Vector2(30, 20)
    l.add_theme_font_size_override("font_size", 30)
    p.add_child(l)
    var names := ["FANNY", "KARRIE", "FRANCO", "LAYLA", "TIGREAL"]
    var roles := ["ASSASSIN", "MARKSMAN", "TANK", "MARKSMAN", "TANK"]
    for i in names.size():
        var b := Button.new()
        b.text = names[i] + "\n" + roles[i]
        b.position = Vector2(25 + (i % 3) * 195, 80 + (i / 3) * 125)
        b.size = Vector2(175, 95)
        b.pressed.connect(_select_hero.bind(names[i], p))
        p.add_child(b)
    var close := Button.new()
    close.text = "CLOSE"
    close.position = Vector2(245, 350)
    close.size = Vector2(130, 45)
    close.pressed.connect(p.queue_free)
    p.add_child(close)

func _select_hero(n: String, panel: Panel) -> void:
    hero_name = n
    hero_role = {"FANNY":"ASSASSIN", "KARRIE":"MARKSMAN", "FRANCO":"TANK", "LAYLA":"MARKSMAN", "TIGREAL":"TANK"}.get(n, "MARKSMAN")
    hero_color = {"FANNY":Color("9c7cff"), "KARRIE":Color("35d5ff"), "FRANCO":Color("f1a43b"), "LAYLA":Color("ffd34e"), "TIGREAL":Color("7cb9ff")}.get(n, Color.WHITE)
    panel.queue_free()

func _circle_style(color: Color, radius: int) -> StyleBoxFlat:
    var s := StyleBoxFlat.new()
    s.bg_color = color
    s.corner_radius_top_left = radius
    s.corner_radius_top_right = radius
    s.corner_radius_bottom_left = radius
    s.corner_radius_bottom_right = radius
    return s

func _build_hud() -> void:
    if hud:
        hud.queue_free()
    hud = CanvasLayer.new()
    add_child(hud)

    var top := ColorRect.new()
    top.position = Vector2(0, 0)
    top.size = Vector2(1280, 74)
    top.color = Color(0.02, 0.05, 0.08, 0.88)
    hud.add_child(top)
    info_label = Label.new()
    info_label.position = Vector2(410, 12)
    info_label.size = Vector2(460, 28)
    info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    info_label.add_theme_font_size_override("font_size", 20)
    hud.add_child(info_label)
    level_label = Label.new()
    level_label.position = Vector2(465, 40)
    level_label.size = Vector2(350, 24)
    level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    level_label.add_theme_font_size_override("font_size", 14)
    hud.add_child(level_label)

    var map_label := Label.new()
    map_label.text = "MAP: MLBB 2022 FBX"
    map_label.position = Vector2(18, 15)
    map_label.add_theme_font_size_override("font_size", 15)
    hud.add_child(map_label)

    target_label = Label.new()
    target_label.text = "PLAYER ONLY"
    target_label.position = Vector2(1000, 15)
    target_label.size = Vector2(250, 30)
    target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
    hud.add_child(target_label)

    # Functional movement wheel. The base and knob are separate so the knob
    # follows the player's finger and snaps back when released.
    joystick_base = Panel.new()
    joystick_base.position = joystick_center - Vector2(85, 85)
    joystick_base.size = Vector2(170, 170)
    joystick_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
    joystick_base.add_theme_stylebox_override("panel", _circle_style(Color(0.04, 0.08, 0.11, 0.78), 85))
    hud.add_child(joystick_base)

    var joystick_inner := Panel.new()
    joystick_inner.position = joystick_center - Vector2(67, 67)
    joystick_inner.size = Vector2(134, 134)
    joystick_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
    joystick_inner.add_theme_stylebox_override("panel", _circle_style(Color(0.10, 0.18, 0.23, 0.82), 67))
    hud.add_child(joystick_inner)

    joystick_knob = Panel.new()
    joystick_knob.size = Vector2(68, 68)
    joystick_knob.position = joystick_center - Vector2(34, 34)
    joystick_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
    joystick_knob.add_theme_stylebox_override("panel", _circle_style(Color(0.12, 0.72, 0.95, 0.88), 34))
    hud.add_child(joystick_knob)

    var attack := Button.new()
    attack.text = "⚔\nATTACK"
    attack.position = Vector2(1090, 545)
    attack.size = Vector2(145, 145)
    attack.add_theme_font_size_override("font_size", 20)
    attack.disabled = true
    hud.add_child(attack)

    var centers := [Vector2(875, 575), Vector2(950, 475), Vector2(1060, 455)]
    for i in 3:
        var b := Button.new()
        b.text = ["S1", "S2", "ULT"][i]
        b.position = centers[i] - Vector2(34, 34)
        b.size = Vector2(68, 68)
        b.add_theme_font_size_override("font_size", 18)
        b.button_down.connect(_skill_down.bind(i))
        b.button_up.connect(_skill_up.bind(i))
        hud.add_child(b)
        skill_buttons.append(b)
        var up := Button.new()
        up.text = "+"
        up.position = centers[i] - Vector2(18, 68)
        up.size = Vector2(36, 36)
        up.add_theme_font_size_override("font_size", 22)
        up.pressed.connect(_upgrade_skill.bind(i))
        hud.add_child(up)
        upgrade_buttons.append(up)
    _update_upgrade_buttons()

func _process(delta: float) -> void:
    if not game_started or not is_instance_valid(player):
        return
    game_time += delta
    attack_cd = max(0.0, attack_cd - delta)
    _move_player(delta)
    _update_camera()
    _update_hud()

func _move_player(delta: float) -> void:
    if moving.length() <= 0.1 or not is_instance_valid(player):
        player.velocity = Vector3.ZERO
        return
    var input_dir := moving
    if input_dir.length() > 1.0:
        input_dir = input_dir.normalized()
    var dir := Vector3(input_dir.x, 0.0, input_dir.y).normalized()
    player.velocity = dir * HERO_SPEED
    player.velocity.y = 0.0
    player.move_and_slide()

    # Keep the character on the imported battlefield and at its walk height.
    var margin := 3.0
    var pos := player.global_position
    pos.x = clamp(pos.x, map_bounds.position.x + margin, map_bounds.end.x - margin)
    pos.z = clamp(pos.z, map_bounds.position.z + margin, map_bounds.end.z - margin)
    pos.y = player_floor_y
    player.global_position = pos
    player.rotation.y = lerp_angle(player.rotation.y, atan2(dir.x, dir.z), 0.2)


func _update_camera() -> void:
    if not is_instance_valid(player) or not is_instance_valid(camera):
        return
    camera.position = player.global_position + CAMERA_OFFSET
    camera.look_at(player.global_position, Vector3.UP)

func _skill_down(i: int) -> void:
    if level < SKILL_UNLOCK_LEVEL[i] or skill_levels[i] <= 0:
        return
    skill_touch = 0
    aiming_skill = i
    aim_origin = Vector2.ZERO
    aim_vector = Vector2(0, -1)
    _create_indicator(i)

func _skill_up(i: int) -> void:
    if aiming_skill != i or not is_instance_valid(player):
        return
    _clear_indicator()
    aiming_skill = -1
    skill_touch = -1

func _upgrade_skill(i: int) -> void:
    if upgrade_points <= 0:
        return
    var maxv := 3 if i == 2 else 6
    if level < SKILL_UNLOCK_LEVEL[i] or skill_levels[i] >= maxv:
        return
    skill_levels[i] += 1
    upgrade_points -= 1
    _update_upgrade_buttons()

func _update_upgrade_buttons() -> void:
    if upgrade_buttons.is_empty():
        return
    for i in 3:
        var maxv := 3 if i == 2 else 6
        upgrade_buttons[i].visible = upgrade_points > 0 and level >= SKILL_UNLOCK_LEVEL[i] and skill_levels[i] < maxv

func _create_indicator(i: int) -> void:
    _clear_indicator()
    if not is_instance_valid(player):
        return
    aim_indicator = Node3D.new()
    aim_indicator.name = "SkillIndicatorOnMapFloor"
    add_child(aim_indicator)
    var radius: float = SKILL_RANGES[i]
    var disc := MeshInstance3D.new()
    var cylinder := CylinderMesh.new()
    cylinder.top_radius = radius
    cylinder.bottom_radius = radius
    cylinder.height = 0.04
    disc.mesh = cylinder
    disc.material_override = _mat(Color(0.1, 0.75, 1.0, 0.22))
    disc.position.y = 0.02
    aim_indicator.add_child(disc)
    var ring := MeshInstance3D.new()
    var torus := TorusMesh.new()
    torus.inner_radius = max(radius - 0.08, 0.05)
    torus.outer_radius = radius + 0.08
    ring.mesh = torus
    ring.material_override = _mat(Color(0.2, 0.9, 1.0, 0.8))
    ring.position.y = 0.06
    aim_indicator.add_child(ring)
    aim_indicator.global_position = Vector3(player.global_position.x, player_floor_y + 0.08, player.global_position.z)

func _update_indicator() -> void:
    if not is_instance_valid(aim_indicator) or not is_instance_valid(player):
        return
    aim_indicator.global_position = Vector3(player.global_position.x, player_floor_y + 0.08, player.global_position.z)
    aim_indicator.rotation.y = -atan2(aim_vector.x, aim_vector.y)

func _clear_indicator() -> void:
    if is_instance_valid(aim_indicator):
        aim_indicator.queue_free()
        aim_indicator = null

func _update_hud() -> void:
    if not is_instance_valid(info_label):
        return
    info_label.text = "%02d:%02d" % [int(game_time) / 60, int(game_time) % 60]
    level_label.text = "LV %d   EXP %.0f / %.0f   POINTS %d   %s" % [level, exp, next_exp, upgrade_points, hero_name]

func _input(event: InputEvent) -> void:
    if not game_started:
        return
    if event is InputEventScreenTouch:
        if event.pressed:
            if event.position.x < 230 and event.position.y > 500:
                joystick_touch = event.index
                _set_move(event.position)
            elif event.position.x > 820 and event.position.y > 380:
                var idx := _skill_at(event.position)
                if idx >= 0:
                    skill_touch = event.index
                    aiming_skill = idx
                    aim_origin = event.position
                    aim_vector = Vector2(0, -1)
                    _create_indicator(idx)
        else:
            if event.index == joystick_touch:
                joystick_touch = -1
                _reset_joystick()
            if event.index == skill_touch and aiming_skill >= 0:
                _skill_up(aiming_skill)
    elif event is InputEventScreenDrag:
        if event.index == joystick_touch:
            _set_move(event.position)
        elif event.index == skill_touch and aiming_skill >= 0:
            var d: Vector2 = event.position - aim_origin
            if d.length() > 8.0:
                aim_vector = d.normalized()
                _update_indicator()
    elif event is InputEventKey and event.pressed:
        if event.keycode == KEY_W:
            moving.y = -1
        elif event.keycode == KEY_S:
            moving.y = 1
        elif event.keycode == KEY_A:
            moving.x = -1
        elif event.keycode == KEY_D:
            moving.x = 1

func _skill_at(p: Vector2) -> int:
    var centers := [Vector2(875, 575), Vector2(950, 475), Vector2(1060, 455)]
    for i in 3:
        if p.distance_to(centers[i]) < 48.0:
            return i
    return -1

func _set_move(p: Vector2) -> void:
    var offset := p - joystick_center
    if offset.length() > JOYSTICK_RADIUS:
        offset = offset.normalized() * JOYSTICK_RADIUS
    moving = offset / JOYSTICK_RADIUS
    moving = Vector2(clamp(moving.x, -1.0, 1.0), clamp(moving.y, -1.0, 1.0))
    if is_instance_valid(joystick_knob):
        joystick_knob.position = joystick_center + offset - Vector2(JOYSTICK_KNOB_RADIUS, JOYSTICK_KNOB_RADIUS)

func _reset_joystick() -> void:
    moving = Vector2.ZERO
    if is_instance_valid(joystick_knob):
        joystick_knob.position = joystick_center - Vector2(JOYSTICK_KNOB_RADIUS, JOYSTICK_KNOB_RADIUS)
