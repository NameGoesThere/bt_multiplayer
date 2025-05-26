extends "res://addons/ModLoader/mod_node.gd"

var setting_join_game = Setting.new(self, "Join Game", Setting.SETTING_BUTTON, join_game)
var setting_host_game = Setting.new(self, "Host Game", Setting.SETTING_BUTTON, host_game)
var setting_leave_game = Setting.new(
	self, "Leave Game / Stop Hosting", Setting.SETTING_BUTTON, leave_game
)
var setting_ip_address = Setting.new(self, "IP Address", Setting.SETTING_TEXT_INPUT, "127.0.0.1")
var setting_port = Setting.new(self, "Port", Setting.SETTING_TEXT_INPUT, "1818")
var separator_server_settings = Setting.new(
	self, "↓ Server Settings ↓", Setting.SETTING_BUTTON, null
)
var setting_max_players = Setting.new(
	self, "Max Player Count", Setting.SETTING_INT, 3, Vector2(2, 16)
)
var setting_pvp = Setting.new(self, "Combat Enabled", Setting.SETTING_BOOL, true)
var setting_update_server_settings = Setting.new(
	self, "Update Server Settings", Setting.SETTING_BUTTON, update_server_settings
)

var hosting: bool = false
var playing: bool = false
var ip_address: String = ""
var port: String = ""

var peer

var players = {}

var last_scene

const PLAYER_HEIGHT = 4
const PLAYER_CROUCH_HEIGHT = 2
const PLAYER_ATTACK_DAMAGE = 1
const PLAYER_ATTACK_RANGE = 3.5
const PLAYER_PARRY_DAMAGE = 1

const COMPRESSION_MODE = ENetConnection.COMPRESS_ZLIB

var server_settings = {"pvp_enabled": null, "max_players": null}


func init():
	ModLoader.mod_log(name_pretty + " mod loaded")

	settings = {
		"settings_page_name": name_pretty,
		"settings_list":
		[
			setting_update_server_settings,
			setting_pvp,
			setting_max_players,
			separator_server_settings,
			setting_leave_game,
			setting_join_game,
			setting_host_game,
			setting_ip_address,
			setting_port
		]
	}

	multiplayer.peer_connected.connect(peer_connected)
	multiplayer.peer_disconnected.connect(peer_disconnected)
	multiplayer.connected_to_server.connect(connected_to_server)
	multiplayer.connection_failed.connect(connection_failed)
	multiplayer.server_disconnected.connect(server_disconnected)


func _process(_delta):
	if last_scene != GameManager.get_tree_root():
		scene_changed(GameManager.get_tree_root().scene_file_path)
	last_scene = GameManager.get_tree_root()


func _physics_process(_delta):
	if is_instance_valid(GameManager.player):
		if hosting || playing:
			send_ingame_info.rpc(
				multiplayer.get_unique_id(),
				GameManager.player.last_tick_global_position,
				GameManager.player.current_state_name,
				GameManager.player.pivot.rotation.x,
				GameManager.player.rotation.y
			)

			for i in players:
				if players[i].id != multiplayer.get_unique_id():
					if !has_node("PLAYER " + str(players[i].id)):
						var cylinder = MeshInstance3D.new()
						cylinder.name = "PLAYER " + str(players[i].id)

						var mesh = CylinderMesh.new()
						mesh.top_radius = 0.5
						mesh.bottom_radius = 0.5
						mesh.height = PLAYER_HEIGHT
						mesh.radial_segments = 2

						cylinder.mesh = mesh

						var username_label = Label3D.new()
						username_label.name = "USERNAME"
						username_label.text = players[i].name
						username_label.position = Vector3(0, 2.5, 0)
						username_label.font_size = 64
						username_label.outline_size = 32
						username_label.scale = Vector3(0.125, 0.125, 0.125)
						username_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
						username_label.fixed_size = true
						username_label.no_depth_test = true

						cylinder.add_child(username_label)
						add_child(cylinder)
					else:
						var player_model = get_node("PLAYER " + str(players[i].id))
						player_model.position = players[i].position + Vector3(0, 2, 0)
						if players[i].state == "Crouch" || players[i].state == "Slide":
							player_model.mesh.height = PLAYER_CROUCH_HEIGHT
							player_model.position -= Vector3(0, 1, 0)
						else:
							player_model.mesh.height = PLAYER_HEIGHT
						player_model.rotation = Vector3(0, players[i].yaw, 0)
			if GameManager.player.attack_button_just_pressed:
				do_attack.rpc(multiplayer.get_unique_id())


func host_game():
	if playing:
		ModLoader.mod_log("You can't host a server if you are connected to somebody elses!")
		return

	if hosting:
		ModLoader.mod_log("You are already hosting a server!")
		return

	ip_address = setting_ip_address.value
	port = setting_port.value
	ModLoader.mod_log("Hosting with IP address: " + ip_address + ":" + port)
	hosting = true

	peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port.to_int(), setting_max_players.value)
	if error:
		ModLoader.mod_log("Hosting failed with error: " + error)
		hosting = false
		return

	update_server_settings(false)

	ModLoader.mod_log(server_settings)

	# Compress all packets (uses less bandwith)
	peer.get_host().compress(COMPRESSION_MODE)

	multiplayer.set_multiplayer_peer(peer)

	send_player_info(SteamService.get_persona_name(), multiplayer.get_unique_id())


func update_server_settings(send = true):
	if hosting:
		server_settings["pvp_enabled"] = setting_pvp.value
		server_settings["max_players"] = setting_max_players.value
		if send:
			send_server_settings.rpc(server_settings)


func join_game():
	if hosting:
		ModLoader.mod_log("You can't join a server if you are hosting!")
		return

	if playing:
		ModLoader.mod_log("You are already connected to a server!")
		return

	ip_address = setting_ip_address.value
	port = setting_port.value
	ModLoader.mod_log("Joining server with IP address: " + ip_address + ":" + port)
	playing = true

	peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(ip_address, port.to_int())
	if error:
		ModLoader.mod_log("Joining failed with error: " + error)
		playing = false
		return

	# Compress all packets (uses less bandwith)
	peer.get_host().compress(COMPRESSION_MODE)

	multiplayer.set_multiplayer_peer(peer)


func leave_game():
	if hosting:
		hosting = false
		multiplayer.multiplayer_peer.close()
		multiplayer.set_multiplayer_peer(null)
	elif playing:
		multiplayer.multiplayer_peer.disconnect_from_host()
		multiplayer.set_multiplayer_peer(null)
		playing = false
	else:
		ModLoader.mod_log("You aren't hosting or playing!")


# Called on server + clients
func peer_connected(id):
	ModLoader.mod_log("Player connected with id: " + str(id))
	if hosting:
		send_server_settings.rpc_id(id, server_settings)


# Called on server + clients
func peer_disconnected(id):
	ModLoader.mod_log("Player disconnected with id: " + str(id))
	players.erase(id)
	if has_node("PLAYER " + str(id)):
		get_node("PLAYER " + str(id)).queue_free()

	if id == 1:
		ModLoader.mod_log("Host has left! Disabling multiplayer.")
		playing = false


# Called on clients
func connected_to_server():
	ModLoader.mod_log("Connection successful!")
	send_player_info.rpc_id(1, SteamService.get_persona_name(), multiplayer.get_unique_id())
	players = {}


# Called on clients
func connection_failed():
	ModLoader.mod_log("Connection failed!")
	playing = false


# Called on clients
func server_disconnected():
	ModLoader.mod_log("Server disconnected!")
	playing = false
	players = {}


func scene_changed(s):
	if hosting:
		switch_scene.rpc(s)
	for i in players:
		if has_node("PLAYER " + players[i].id):
			get_node("PLAYER " + players[i].id).queue_free()
	players = {}


@rpc("authority")
func switch_scene(s):
	GameManager.change_level_scene(s)


@rpc("authority")
func send_server_settings(settings_dict):
	server_settings = settings_dict


@rpc("any_peer")
func send_player_info(name, id):
	if !players.has(id):
		players[id] = {
			"name": name,
			"id": id,
			"position": Vector3(0, 0, 0),
			"state": "",
			"pitch": 0.0,
			"yaw": 0.0,
		}

	if multiplayer.is_server():
		for i in players:
			send_player_info.rpc(players[i].name, i)


@rpc("any_peer")
func send_ingame_info(id, position, state_string, pitch, yaw):
	if players[id]:
		players[id].position = position
		players[id].state = state_string
		players[id].pitch = pitch
		players[id].yaw = yaw


@rpc("any_peer")
func do_attack(id):
	if server_settings["pvp_enabled"]:
		if players[id]:
			if GameManager.player.position.distance_to(players[id].position) <= PLAYER_ATTACK_RANGE:
				var attack = Attack.new()
				attack.damage = PLAYER_ATTACK_DAMAGE
				attack.is_parryable = true
				if GameManager.player.hurt_and_collide_component.get_hit(attack).was_parried:
					GameManager.player.play_parry_effects()
					parry_attack.rpc_id(id, multiplayer.get_unique_id())


@rpc("any_peer")
func parry_attack(id):
	if server_settings["pvp_enabled"]:
		var attack = Attack.new()
		attack.damage = PLAYER_PARRY_DAMAGE
		attack.is_parryable = false
		GameManager.player.hurt_and_collide_component.get_hit(attack)
