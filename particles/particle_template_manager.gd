extends Node
class_name ParticleTemplateManager

## Singleton that manages particle templates and encodes them into GPU-readable textures
## Registers templates and assigns unique IDs

const MAX_TEMPLATES = 16

# Template registry
var templates: Array[ParticleTemplate] = []
var template_by_name: Dictionary = {}
var next_template_id: int = 0

# Encoded texture data
var template_properties_texture: ImageTexture
var color_ramp_atlas: ImageTexture
var scale_curve_atlas: ImageTexture
var emission_curve_atlas: ImageTexture
var velocity_curve_atlas: ImageTexture
var texture_array: Texture2DArray

# Texture dimensions
const CURVE_RESOLUTION = 256
const PROPERTIES_HEIGHT = 11  # Number of property rows per template (row 10 = base color)

signal templates_updated()

func _init() -> void:
	templates.resize(MAX_TEMPLATES)
	_initialize_textures()

func register_template(template: ParticleTemplate) -> int:
	if template == null:
		push_error("ParticleTemplateManager: Cannot register null template")
		return -1

	if next_template_id >= MAX_TEMPLATES:
		push_error("ParticleTemplateManager: Maximum templates (%d) reached" % MAX_TEMPLATES)
		return -1

	var id = next_template_id
	template.template_id = id
	templates[id] = template

	if template.template_name != "":
		template_by_name[template.template_name] = template

	next_template_id += 1

	print("ParticleTemplateManager: Registered template '%s' with ID %d" % [template.template_name, id])

	# Encode this template into textures
	_encode_template(template, id)

	templates_updated.emit()

	return id

func get_template_by_id(id: int) -> ParticleTemplate:
	if id < 0 or id >= templates.size():
		return null
	return templates[id]

func get_template_by_name(_name: String) -> ParticleTemplate:
	return template_by_name.get(_name, null)

func get_template_id(_name: String) -> int:
	"""Get template ID by name. Returns -1 if not found."""
	var template = template_by_name.get(_name, null)
	if template:
		return template.template_id
	return -1

func _initialize_textures() -> void:
	# Properties texture: stores scalar properties for each template
	# Width = MAX_TEMPLATES, Height = PROPERTIES_HEIGHT
	var props_image = Image.create(MAX_TEMPLATES, PROPERTIES_HEIGHT, false, Image.FORMAT_RGBAF)
	props_image.fill(Color(0, 0, 0, 0))
	template_properties_texture = ImageTexture.create_from_image(props_image)

	# Color ramp atlas: stores color gradients
	# Width = CURVE_RESOLUTION, Height = MAX_TEMPLATES
	var color_image = Image.create(CURVE_RESOLUTION, MAX_TEMPLATES, false, Image.FORMAT_RGBA8)
	color_image.fill(Color(1, 1, 1, 1))
	color_ramp_atlas = ImageTexture.create_from_image(color_image)

	# Scale curve atlas: stores scale curves
	var scale_image = Image.create(CURVE_RESOLUTION, MAX_TEMPLATES, false, Image.FORMAT_RF)
	scale_image.fill(Color(1, 1, 1, 1))
	scale_curve_atlas = ImageTexture.create_from_image(scale_image)

	# Emission curve atlas: stores emission curves
	var emission_image = Image.create(CURVE_RESOLUTION, MAX_TEMPLATES, false, Image.FORMAT_RF)
	emission_image.fill(Color(0, 0, 0, 1))
	emission_curve_atlas = ImageTexture.create_from_image(emission_image)

	# Velocity curve atlas: stores velocity curves (XYZ)
	var velocity_image = Image.create(CURVE_RESOLUTION, MAX_TEMPLATES, false, Image.FORMAT_RGBF)
	velocity_image.fill(Color(0, 0, 0, 0))
	velocity_curve_atlas = ImageTexture.create_from_image(velocity_image)

	print("ParticleTemplateManager: Textures initialized")

func _encode_template(template: ParticleTemplate, id: int) -> void:
	if template == null:
		return

	# Encode properties
	_encode_properties(template, id)

	# Encode color ramp
	_encode_color_ramp(template, id)

	# Encode scale curve
	_encode_scale_curve(template, id)

	# Encode emission curve
	_encode_emission_curve(template, id)

	# Encode velocity curve
	_encode_velocity_curve(template, id)

	print("ParticleTemplateManager: Encoded template %d" % id)

func _encode_properties(template: ParticleTemplate, id: int) -> void:
	var image = template_properties_texture.get_image()

	# Row 0: initial velocity, lifetime
	image.set_pixel(id, 0, Color(
		template.initial_velocity_min,
		template.initial_velocity_max,
		template.lifetime_min,
		template.lifetime_max
	))

	# Row 1: damping, linear accel
	image.set_pixel(id, 1, Color(
		template.damping_min,
		template.damping_max,
		template.linear_accel_min,
		template.linear_accel_max
	))

	# Row 2: direction, spread
	image.set_pixel(id, 2, Color(
		template.direction.x,
		template.direction.y,
		template.direction.z,
		template.spread
	))

	# Row 3: gravity, emission shape
	image.set_pixel(id, 3, Color(
		template.gravity.x,
		template.gravity.y,
		template.gravity.z,
		float(template.emission_shape)
	))

	# Row 4: radial/tangent accel, emission sphere radius
	image.set_pixel(id, 4, Color(
		template.radial_accel_min,
		template.radial_accel_max,
		template.tangent_accel_min,
		template.tangent_accel_max
	))

	# Row 5: emission box extents
	image.set_pixel(id, 5, Color(
		template.emission_sphere_radius,
		template.emission_box_extents.x,
		template.emission_box_extents.y,
		template.emission_box_extents.z
	))

	# Row 6: angular velocity, initial angle
	image.set_pixel(id, 6, Color(
		template.angular_velocity_min,
		template.angular_velocity_max,
		template.initial_angle_min,
		template.initial_angle_max
	))

	# Row 7: scale X (min/max), scale Y (min/max)
	image.set_pixel(id, 7, Color(
		template.scale_min.x,
		template.scale_max.x,
		template.scale_min.y,
		template.scale_max.y
	))

	# Row 8: emission color (RGB), emission energy (A)
	image.set_pixel(id, 8, Color(
		template.emission_color.r,
		template.emission_color.g,
		template.emission_color.b,
		template.emission_energy
	))

	# Row 9: alignment mode, velocity_stretch, is_trail, hue_variation_max
	image.set_pixel(id, 9, Color(
		1.0 if template.align_to_velocity else 0.0,
		template.velocity_stretch,
		1.0 if template.is_trail else 0.0,
		template.hue_variation_max
	))

	# Row 10: base color (RGBA)
	image.set_pixel(id, 10, template.color)

	template_properties_texture.update(image)

func _encode_color_ramp(template: ParticleTemplate, id: int) -> void:
	if template.color_over_life == null:
		return

	var image = color_ramp_atlas.get_image()
	var gradient = template.color_over_life.gradient

	if gradient == null:
		return

	# Sample the gradient and store in row 'id'
	for x in range(CURVE_RESOLUTION):
		var t = float(x) / float(CURVE_RESOLUTION - 1)
		var color = gradient.sample(t)
		image.set_pixel(x, id, color)

	color_ramp_atlas.update(image)

func _encode_scale_curve(template: ParticleTemplate, id: int) -> void:
	if template.scale_over_life == null:
		return

	var image = scale_curve_atlas.get_image()
	var curve = template.scale_over_life.curve

	if curve == null:
		return

	# Sample the curve and store in row 'id'
	for x in range(CURVE_RESOLUTION):
		var t = float(x) / float(CURVE_RESOLUTION - 1)
		var value = curve.sample(t)
		image.set_pixel(x, id, Color(value, value, value, 1.0))

	scale_curve_atlas.update(image)

func _encode_emission_curve(template: ParticleTemplate, id: int) -> void:
	if template.emission_over_life == null:
		return

	var image = emission_curve_atlas.get_image()
	var curve = template.emission_over_life.curve

	if curve == null:
		return

	# Sample the curve and store in row 'id'
	for x in range(CURVE_RESOLUTION):
		var t = float(x) / float(CURVE_RESOLUTION - 1)
		var value = curve.sample(t)
		image.set_pixel(x, id, Color(value, value, value, 1.0))

	emission_curve_atlas.update(image)

func _encode_velocity_curve(template: ParticleTemplate, id: int) -> void:
	if template.velocity_over_life == null:
		return

	var image = velocity_curve_atlas.get_image()
	var curve_x = template.velocity_over_life.curve_x
	var curve_y = template.velocity_over_life.curve_y
	var curve_z = template.velocity_over_life.curve_z

	# Sample the curves and store in row 'id'
	for x in range(CURVE_RESOLUTION):
		var t = float(x) / float(CURVE_RESOLUTION - 1)
		var vel_x = curve_x.sample(t) if curve_x != null else 0.0
		var vel_y = curve_y.sample(t) if curve_y != null else 0.0
		var vel_z = curve_z.sample(t) if curve_z != null else 0.0
		image.set_pixel(x, id, Color(vel_x, vel_y, vel_z, 1.0))

	velocity_curve_atlas.update(image)

func build_texture_array() -> Texture2DArray:
	# Build texture array from all registered template textures
	var textures: Array[Texture2D] = []

	for i in range(MAX_TEMPLATES):
		var template = templates[i]
		if template != null and template.texture != null:
			textures.append(template.texture)
		else:
			# Create a white 1x1 placeholder
			var img = Image.create(1, 1, false, Image.FORMAT_RGBA8)
			img.fill(Color.WHITE)
			textures.append(ImageTexture.create_from_image(img))

	# Create Texture2DArray
	if textures.size() > 0:
		var first_texture = textures[0]
		var width = first_texture.get_width()
		var height = first_texture.get_height()

		# var array_image = Image.create(width, height, false, Image.FORMAT_RGBA8)
		var layers: Array[Image] = []

		for tex in textures:
			var img = tex.get_image()

			# Decompress if compressed
			if img.is_compressed():
				img.decompress()

			# Convert to RGBA8 format if needed
			if img.get_format() != Image.FORMAT_RGBA8:
				img.convert(Image.FORMAT_RGBA8)

			# Resize if dimensions don't match
			if img.get_width() != width or img.get_height() != height:
				img.resize(width, height)

			# Ensure no mipmaps - create fresh image and copy pixel data
			if img.has_mipmaps():
				var new_img = Image.create(img.get_width(), img.get_height(), false, img.get_format())
				new_img.blit_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i(0, 0))
				img = new_img

			layers.append(img)

		var tex_array = Texture2DArray.new()
		tex_array.create_from_images(layers)
		texture_array = tex_array

		print("ParticleTemplateManager: Built texture array with %d layers" % textures.size())
		return tex_array

	return null

func get_shader_uniforms() -> Dictionary:
	# Build texture array on-demand
	if texture_array == null:
		build_texture_array()

	return {
		"template_properties": template_properties_texture,
		"color_ramp_atlas": color_ramp_atlas,
		"scale_curve_atlas": scale_curve_atlas,
		"emission_curve_atlas": emission_curve_atlas,
		"velocity_curve_atlas": velocity_curve_atlas,
		"texture_atlas": texture_array,
		"max_templates": MAX_TEMPLATES
	}

func clear_templates() -> void:
	templates.clear()
	templates.resize(MAX_TEMPLATES)
	template_by_name.clear()
	next_template_id = 0
	_initialize_textures()
	templates_updated.emit()
	print("ParticleTemplateManager: Cleared all templates")
