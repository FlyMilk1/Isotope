# frozen_string_literal: true

RSpec.describe Isotope::Serializer do
  describe '.build_scene and .serialize_scene' do
    it 'builds an empty Scene2D when given nil or an empty hash' do
      expect(described_class.build_scene(nil)).to be_a(Rubidium::Scene2D)
      expect(described_class.build_scene(nil).rigid_bodies).to eq({})
      expect(described_class.build_scene({}).rigid_bodies).to eq({})
    end

    it 'returns an existing Rubidium::Scene2D instance as-is' do
      scene = Rubidium::Scene2D.new
      expect(described_class.build_scene(scene)).to equal(scene)
    end

    it 'builds and serializes a scene with bodies, colliders, and infinity mass' do
      scene_payload = {
        'rigid_bodies' => {
          '1' => {
            'mass' => Float::INFINITY,
            'position' => { 'x' => 0, 'y' => -10 },
            'rotation' => 0.0,
            'static' => true,
            'collider' => { 'type' => 'RectangleCollider', 'width' => 20, 'height' => 2 }
          },
          '2' => {
            mass: 2.5,
            position: [1.5, 4.0],
            velocity: { x: 3.0, y: -1.0 },
            acceleration: { x: 0.0, y: -9.8 },
            rotation: 0.25,
            drag: 0.1,
            angular_velocity: 0.5,
            angular_acceleration: 0.02,
            collider: { type: 'CircleCollider', radius: 0.75 }
          }
        }
      }

      scene = described_class.build_scene(scene_payload)
      expect(scene).to be_a(Rubidium::Scene2D)
      expect(scene.rigid_bodies.size).to eq(2)

      ground = scene.get_rigidbody(1)
      expect(ground.mass).to eq(Float::INFINITY)
      expect(ground.static).to be(true)
      expect(ground.collider).to be_a(Rubidium::Collision::RectangleCollider)
      expect(ground.collider.width).to eq(20)
      expect(ground.collider.height).to eq(2)

      ball = scene.get_rigidbody(2)
      expect(ball.mass).to eq(2.5)
      expect(ball.position).to eq(Rubidium::Vector2.new(1.5, 4.0))
      expect(ball.velocity).to eq(Rubidium::Vector2.new(3.0, -1.0))
      expect(ball.acceleration).to eq(Rubidium::Vector2.new(0.0, -9.8))
      expect(ball.drag).to eq(0.1)
      expect(ball.collider).to be_a(Rubidium::Collision::CircleCollider)
      expect(ball.collider.radius).to eq(0.75)

      serialized = described_class.serialize_scene(scene)
      expect(serialized['type']).to eq('Scene2D')
      expect(serialized['rigid_bodies']['1']['mass']).to eq('Infinity')
      expect(serialized['rigid_bodies']['1']['collider']).to eq('type' => 'RectangleCollider', 'width' => 20, 'height' => 2)
      expect(serialized['rigid_bodies']['2']['collider']).to eq('type' => 'CircleCollider', 'radius' => 0.75)
    end

    it 'builds a scene from a JSON string' do
      json = Oj.dump(
        {
          'type' => 'Scene2D',
          'rigid_bodies' => [
            { 'mass' => 1.0, 'position' => { 'x' => 2.0, 'y' => 3.0 }, 'rotation' => 0.0 }
          ]
        },
        mode: :strict
      )

      scene = described_class.build_scene(json)
      body = scene.get_rigidbody(1)
      expect(body.position).to eq(Rubidium::Vector2.new(2.0, 3.0))
    end
  end

  describe '.build_rigidbody and .serialize_rigidbody' do
    it 'builds a rigid body with defaults and serializes it with optional id' do
      body = described_class.build_rigidbody({ position: { x: 4, y: 5 }, collider: { type: 'CircleCollider', radius: 1.5 } })
      expect(body).to be_a(Rubidium::RigidBody2d)
      expect(body.mass).to eq(1.0)
      expect(body.position).to eq(Rubidium::Vector2.new(4, 5))
      expect(body.collider).to be_a(Rubidium::Collision::CircleCollider)
      expect(body.collider.radius).to eq(1.5)

      serialized = described_class.serialize_rigidbody(body, id: 7)
      expect(serialized['id']).to eq(7)
      expect(serialized['position']).to eq('x' => 4, 'y' => 5)
      expect(serialized['collider']).to eq('type' => 'CircleCollider', 'radius' => 1.5)
    end
  end

  describe '.build_vector2' do
    it 'builds Vector2 from Vector2, Array, and Hash' do
      expect(described_class.build_vector2(Rubidium::Vector2.new(1, 2))).to eq(Rubidium::Vector2.new(1, 2))
      expect(described_class.build_vector2([3, 4])).to eq(Rubidium::Vector2.new(3.0, 4.0))
      expect(described_class.build_vector2(x: 5, y: 6)).to eq(Rubidium::Vector2.new(5.0, 6.0))
      expect(described_class.build_vector2('x' => -1.5, 'y' => 2.5)).to eq(Rubidium::Vector2.new(-1.5, 2.5))
    end

    it 'raises ArgumentError for invalid Vector2 inputs' do
      expect { described_class.build_vector2([1]) }.to raise_error(ArgumentError)
      expect { described_class.build_vector2({ 'x' => 1 }) }.to raise_error(ArgumentError)
      expect { described_class.build_vector2('bad') }.to raise_error(ArgumentError)
    end
  end
end
