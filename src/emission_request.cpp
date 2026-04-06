#include "emission_request.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void EmissionRequest::_bind_methods() {
	// Bind init method
	ClassDB::bind_method(D_METHOD("init", "position", "direction", "template_id",
								  "size_multiplier", "count", "speed_mod", "random_seed"),
						 &EmissionRequest::init);

	// Bind getters
	ClassDB::bind_method(D_METHOD("get_position"), &EmissionRequest::get_position);
	ClassDB::bind_method(D_METHOD("get_direction"), &EmissionRequest::get_direction);
	ClassDB::bind_method(D_METHOD("get_template_id"), &EmissionRequest::get_template_id);
	ClassDB::bind_method(D_METHOD("get_size_multiplier"), &EmissionRequest::get_size_multiplier);
	ClassDB::bind_method(D_METHOD("get_count"), &EmissionRequest::get_count);
	ClassDB::bind_method(D_METHOD("get_speed_mod"), &EmissionRequest::get_speed_mod);
	ClassDB::bind_method(D_METHOD("get_random_seed"), &EmissionRequest::get_random_seed);
	ClassDB::bind_method(D_METHOD("get_prefix_offset"), &EmissionRequest::get_prefix_offset);

	// Bind setters
	ClassDB::bind_method(D_METHOD("set_position", "position"), &EmissionRequest::set_position);
	ClassDB::bind_method(D_METHOD("set_direction", "direction"), &EmissionRequest::set_direction);
	ClassDB::bind_method(D_METHOD("set_template_id", "template_id"), &EmissionRequest::set_template_id);
	ClassDB::bind_method(D_METHOD("set_size_multiplier", "size_multiplier"), &EmissionRequest::set_size_multiplier);
	ClassDB::bind_method(D_METHOD("set_count", "count"), &EmissionRequest::set_count);
	ClassDB::bind_method(D_METHOD("set_speed_mod", "speed_mod"), &EmissionRequest::set_speed_mod);
	ClassDB::bind_method(D_METHOD("set_random_seed", "random_seed"), &EmissionRequest::set_random_seed);
	ClassDB::bind_method(D_METHOD("set_prefix_offset", "prefix_offset"), &EmissionRequest::set_prefix_offset);

	// Bind properties
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "position"), "set_position", "get_position");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "direction"), "set_direction", "get_direction");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "template_id"), "set_template_id", "get_template_id");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "size_multiplier"), "set_size_multiplier", "get_size_multiplier");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "count"), "set_count", "get_count");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "speed_mod"), "set_speed_mod", "get_speed_mod");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "random_seed"), "set_random_seed", "get_random_seed");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "prefix_offset"), "set_prefix_offset", "get_prefix_offset");
}

EmissionRequest::EmissionRequest() {
	position = Vector3();
	direction = Vector3();
	template_id = 0;
	size_multiplier = 1.0;
	count = 0;
	speed_mod = 1.0;
	random_seed = 0;
	prefix_offset = 0;
}

EmissionRequest::~EmissionRequest() {
}

void EmissionRequest::init(const Vector3 &p_position, const Vector3 &p_direction, int p_template_id,
						   double p_size_multiplier, int p_count, double p_speed_mod, int p_random_seed) {
	position = p_position;
	direction = p_direction;
	template_id = p_template_id;
	size_multiplier = p_size_multiplier;
	count = p_count;
	speed_mod = p_speed_mod;
	random_seed = p_random_seed;
	prefix_offset = 0;
}

// Getters
Vector3 EmissionRequest::get_position() const {
	return position;
}

Vector3 EmissionRequest::get_direction() const {
	return direction;
}

int EmissionRequest::get_template_id() const {
	return template_id;
}

double EmissionRequest::get_size_multiplier() const {
	return size_multiplier;
}

int EmissionRequest::get_count() const {
	return count;
}

double EmissionRequest::get_speed_mod() const {
	return speed_mod;
}

int EmissionRequest::get_random_seed() const {
	return random_seed;
}

int EmissionRequest::get_prefix_offset() const {
	return prefix_offset;
}

// Setters
void EmissionRequest::set_position(const Vector3 &p_position) {
	position = p_position;
}

void EmissionRequest::set_direction(const Vector3 &p_direction) {
	direction = p_direction;
}

void EmissionRequest::set_template_id(int p_template_id) {
	template_id = p_template_id;
}

void EmissionRequest::set_size_multiplier(double p_size_multiplier) {
	size_multiplier = p_size_multiplier;
}

void EmissionRequest::set_count(int p_count) {
	count = p_count;
}

void EmissionRequest::set_speed_mod(double p_speed_mod) {
	speed_mod = p_speed_mod;
}

void EmissionRequest::set_random_seed(int p_random_seed) {
	random_seed = p_random_seed;
}

void EmissionRequest::set_prefix_offset(int p_prefix_offset) {
	prefix_offset = p_prefix_offset;
}