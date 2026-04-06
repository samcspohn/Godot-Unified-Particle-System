#include "example_node.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

void ExampleNode::_bind_methods() {
    // Bind properties
    ClassDB::bind_method(D_METHOD("get_amplitude"), &ExampleNode::get_amplitude);
    ClassDB::bind_method(D_METHOD("set_amplitude", "p_amplitude"), &ExampleNode::set_amplitude);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "amplitude"), "set_amplitude", "get_amplitude");

    ClassDB::bind_method(D_METHOD("get_speed"), &ExampleNode::get_speed);
    ClassDB::bind_method(D_METHOD("set_speed", "p_speed"), &ExampleNode::set_speed);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "speed"), "set_speed", "get_speed");

    // Bind custom methods
    ClassDB::bind_method(D_METHOD("get_time_passed"), &ExampleNode::get_time_passed);

    // Signals
    ADD_SIGNAL(MethodInfo("position_changed", PropertyInfo(Variant::OBJECT, "node"), PropertyInfo(Variant::VECTOR3, "new_pos")));
}

ExampleNode::ExampleNode() {
    amplitude = 10.0;
    speed = 1.0;
    time_passed = 0.0;
}

ExampleNode::~ExampleNode() {
}

void ExampleNode::_process(double delta) {
    time_passed += delta * speed;

    Vector3 new_position = Vector3(
        amplitude * sin(time_passed * 2.0),
        amplitude * sin(time_passed * 1.5),
        0.0
    );

    set_position(new_position);

    emit_signal("position_changed", this, new_position);
}

void ExampleNode::_ready() {
    UtilityFunctions::print("ExampleNode is ready! Amplitude: ", amplitude, " Speed: ", speed);
}

double ExampleNode::get_amplitude() const {
    return amplitude;
}

void ExampleNode::set_amplitude(const double p_amplitude) {
    amplitude = p_amplitude;
}

double ExampleNode::get_speed() const {
    return speed;
}

void ExampleNode::set_speed(const double p_speed) {
    speed = p_speed;
}

double ExampleNode::get_time_passed() const {
    return time_passed;
}