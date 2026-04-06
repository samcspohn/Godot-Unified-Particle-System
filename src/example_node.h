#ifndef EXAMPLE_NODE_H
#define EXAMPLE_NODE_H

#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

class ExampleNode : public Node3D {
	GDCLASS(ExampleNode, Node3D)

private:
	double amplitude;
	double speed;
	double time_passed;

protected:
	static void _bind_methods();

public:
	ExampleNode();
	~ExampleNode();

	void _ready() override;
	void _process(double delta) override;

	void set_amplitude(double p_amplitude);
	double get_amplitude() const;

	void set_speed(double p_speed);
	double get_speed() const;

	double get_time_passed() const;
};

#endif // EXAMPLE_NODE_H