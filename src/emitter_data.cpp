#include "emitter_data.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void EmitterData::_bind_methods() {
	// Bind init method
	ClassDB::bind_method(D_METHOD("init", "active", "position", "template_id", "size_multiplier", 
								  "emit_rate", "speed_scale", "velocity_boost"), 
						 &EmitterData::init,
						 DEFVAL(false), DEFVAL(Vector3()), DEFVAL(-1), DEFVAL(1.0),
						 DEFVAL(0.05), DEFVAL(1.0), DEFVAL(0.0));

	// Bind getters
	ClassDB::bind_method(D_METHOD("get_active"), &EmitterData::get_active);
	ClassDB::bind_method(D_METHOD("get_position"), &EmitterData::get_position);
	ClassDB::bind_method(D_METHOD("get_template_id"), &EmitterData::get_template_id);
	ClassDB::bind_method(D_METHOD("get_size_multiplier"), &EmitterData::get_size_multiplier);
	ClassDB::bind_method(D_METHOD("get_emit_rate"), &EmitterData::get_emit_rate);
	ClassDB::bind_method(D_METHOD("get_speed_scale"), &EmitterData::get_speed_scale);
	ClassDB::bind_method(D_METHOD("get_velocity_boost"), &EmitterData::get_velocity_boost);

	// Bind setters
	ClassDB::bind_method(D_METHOD("set_active", "active"), &EmitterData::set_active);
	ClassDB::bind_method(D_METHOD("set_position", "position"), &EmitterData::set_position);
	ClassDB::bind_method(D_METHOD("set_template_id", "template_id"), &EmitterData::set_template_id);
	ClassDB::bind_method(D_METHOD("set_size_multiplier", "size_multiplier"), &EmitterData::set_size_multiplier);
	ClassDB::bind_method(D_METHOD("set_emit_rate", "emit_rate"), &EmitterData::set_emit_rate);
	ClassDB::bind_method(D_METHOD("set_speed_scale", "speed_scale"), &EmitterData::set_speed_scale);
	ClassDB::bind_method(D_METHOD("set_velocity_boost", "velocity_boost"), &EmitterData::set_velocity_boost);

	// Bind properties
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "active"), "set_active", "get_active");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "position"), "set_position", "get_position");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "template_id"), "set_template_id", "get_template_id");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "size_multiplier"), "set_size_multiplier", "get_size_multiplier");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "emit_rate"), "set_emit_rate", "get_emit_rate");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "speed_scale"), "set_speed_scale", "get_speed_scale");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "velocity_boost"), "set_velocity_boost", "get_velocity_boost");
}

EmitterData::EmitterData() {
	active = false;
	position = Vector3();
	template_id = -1;
	size_multiplier = 1.0;
	emit_rate = 0.05;
	speed_scale = 1.0;
	velocity_boost = 0.0;
}

EmitterData::~EmitterData() {
}

void EmitterData::init(bool p_active, const Vector3 &p_position,
					   int p_template_id, double p_size_multiplier,
					   double p_emit_rate, double p_speed_scale,
					   double p_velocity_boost) {
	active = p_active;
	position = p_position;
	template_id = p_template_id;
	size_multiplier = p_size_multiplier;
	emit_rate = p_emit_rate;
	speed_scale = p_speed_scale;
	velocity_boost = p_velocity_boost;
}

// Getters
bool EmitterData::get_active() const {
	return active;
}

Vector3 EmitterData::get_position() const {
	return position;
}

int EmitterData::get_template_id() const {
	return template_id;
}

double EmitterData::get_size_multiplier() const {
	return size_multiplier;
}

double EmitterData::get_emit_rate() const {
	return emit_rate;
}

double EmitterData::get_speed_scale() const {
	return speed_scale;
}

double EmitterData::get_velocity_boost() const {
	return velocity_boost;
}

// Setters
void EmitterData::set_active(bool p_active) {
	active = p_active;
}

void EmitterData::set_position(const Vector3 &p_position) {
	position = p_position;
}

void EmitterData::set_template_id(int p_template_id) {
	template_id = p_template_id;
}

void EmitterData::set_size_multiplier(double p_size_multiplier) {
	size_multiplier = p_size_multiplier;
}

void EmitterData::set_emit_rate(double p_emit_rate) {
	emit_rate = p_emit_rate;
}

void EmitterData::set_speed_scale(double p_speed_scale) {
	speed_scale = p_speed_scale;
}

void EmitterData::set_velocity_boost(double p_velocity_boost) {
	velocity_boost = p_velocity_boost;
}