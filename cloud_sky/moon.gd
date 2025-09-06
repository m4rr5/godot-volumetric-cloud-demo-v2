@tool
extends DirectionalLight3D

var cloud_sky := load(get_script().resource_path.get_base_dir() + "/clouds_sky.tres")

func _ready():
	call_deferred("delayed_init")

# Needs to be called after cloud_sky is fully initialized
func delayed_init():
	cloud_sky.moon = self
