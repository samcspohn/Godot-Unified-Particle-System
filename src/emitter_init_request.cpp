#include "emitter_init_request.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void EmitterInitRequest::_bind_methods() {
	// Bind init method
	ClassDB::bind_method(D_METHOD("init", "id", "template_id", "size_multiplier",
								  "emit_rate", "speed_scale", "velocity_boost", "position"),
						 &EmitterInitRequest::init);

	// Bind getters
	ClassDB::bind_method(D_METHOD("get_id"), &EmitterInitRequest::get_id);
	ClassDB::bind_method(D_METHOD("get_template_id"), &EmitterInitRequest::get_template_id);
	ClassDB::bind_method(D_METHOD("get_size_multiplier"), &EmitterInitRequest::get_size_multiplier);
	ClassDB::bind_method(D_METHOD("get_emit_rate"), &EmitterInitRequest::get_emit_rate);
	ClassDB::bind_method(D_METHOD("get_speed_scale"), &EmitterInitRequest::get_speed_scale);
	ClassDB::bind_method(D_METHOD("get_velocity_boost"), &EmitterInitRequest::get_velocity_boost);
	ClassDB::bind_method(D_METHOD("get_position"), &EmitterInitRequest::get_position);

	// Bind setters
	ClassDB::bind_method(D_METHOD("set_id", "id"), &EmitterInitRequest::set_id);
	ClassDB::bind_method(D_METHOD("set_template_id", "template_id"), &EmitterInitRequest::set_template_id);
	ClassDB::bind_method(D_METHOD("set_size_multiplier", "size_multiplier"), &EmitterInitRequest::set_size_multiplier);
	ClassDB::bind_method(D_METHOD("set_emit_rate", "emit_rate"), &EmitterInitRequest::set_emit_rate);
	ClassDB::bind_method(D_METHOD("set_speed_scale", "speed_scale"), &EmitterInitRequest::set_speed_scale);
	ClassDB::bind_method(D_METHOD("set_velocity_boost", "velocity_boost"), &EmitterInitRequest::set_velocity_boost);
	ClassDB::bind_method(D_METHOD("set_position", "position"), &EmitterInitRequest::set_position);

	// Bind properties
	ADD_PROPERTY(PropertyInfo(Variant::INT, "id"), "set_id", "get_id");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "template_id"), "set_template_id", "get_template_id");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "size_multiplier"), "set_size_multiplier", "get_size_multiplier");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "emit_rate"), "set_emit_rate", "get_emit_rate");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "speed_scale"), "set_speed_scale", "get_speed_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "velocity_boost"), "set_velocity_boost", "get_velocity_boost");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "position"), "set_position", "get_position");
}

EmitterInitRequest::EmitterInitRequest() {
	id = 0;
	template_id = 0;
	size_multiplier = 1.0;
	emit_rate = 0.05;
	speed_scale = 1.0;
	velocity_boost = 0.0;
	position = Vector3();
}

EmitterInitRequest::~EmitterInitRequest() {
}

void EmitterInitRequest::init(int p_id, int p_template_id, double p_size_multiplier,
							  double p_emit_rate, double p_speed_scale, double p_velocity_boost,
							  const Vector3 &p_position) {
	id = p_id;
	template_id = p_template_id;
	size_multiplier = p_size_multiplier;
	emit_rate = p_emit_rate;
	speed_scale = p_speed_scale;
	velocity_boost = p_velocity_boost;
	position = p_position;
}

// Getters
int EmitterInitRequest::get_id() const {
	return id;
}

int EmitterInitRequest::get_template_id() const {
	return template_id;
}

double EmitterInitRequest::get_size_multiplier() const {
	return size_multiplier;
}

double EmitterInitRequest::get_emit_rate() const {
	return emit_rate;
}

double EmitterInitRequest::get_speed_scale() const {
	return speed_scale;
}

double EmitterInitRequest::get_velocity_boost() const {
	return velocity_boost;
}

Vector3 EmitterInitRequest::get_position() const {
	return position;
}

// Setters
void EmitterInitRequest::set_id(int p_id) {
	id = p_id;
}

void EmitterInitRequest::set_template_id(int p_template_id) {
	template_id = p_template_id;
}

void EmitterInitRequest::set_size_multiplier(double p_size_multiplier) {
	size_multiplier = p_size_multiplier;
}

void EmitterInitRequest::set_emit_rate(double p_emit_rate) {
	emit_rate = p_emit_rate;
}

void EmitterInitRequest::set_speed_scale(double p_speed_scale) {
	speed_scale = p_speed_scale;
}

void EmitterInitRequest::set_velocity_boost(double p_velocity_boost) {
	velocity_boost = p_velocity_boost;
}

void EmitterInitRequest::set_position(const Vector3 &p_position) {
	position = p_position;
}