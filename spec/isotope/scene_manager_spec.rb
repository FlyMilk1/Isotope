# frozen_string_literal: true

require 'tempfile'

RSpec.describe Isotope::SceneManager do
  subject(:manager) { described_class.new }

  describe '#create_scene, #get_scene, #list_scenes, and #delete_scene' do
    it 'creates multiple scenes with auto-assigned and custom IDs' do
      id1, scene1 = manager.create_scene
      id2, scene2 = manager.create_scene(id: 'arena_1')
      id3, scene3 = manager.create_scene(id: 10, scene_data: {
        'rigid_bodies' => [{ 'mass' => 2.0, 'position' => { 'x' => 1, 'y' => 2 }, 'rotation' => 0.0 }]
      })

      expect(id1).to eq(1)
      expect(id2).to eq('arena_1')
      expect(id3).to eq(10)

      expect(manager.get_scene(1)).to equal(scene1)
      expect(manager.get_scene('1')).to equal(scene1)
      expect(manager.get_scene('arena_1')).to equal(scene2)
      expect(manager.get_scene(10)).to equal(scene3)

      expect(manager.scene_ids).to contain_exactly(1, 'arena_1', 10)
      listed = manager.list_scenes
      expect(listed.keys).to contain_exactly('1', 'arena_1', '10')
      expect(listed['10']['rigid_bodies']['1']['mass']).to eq(2.0)

      manager.delete_scene('arena_1')
      expect(manager.scene?('arena_1')).to be(false)
      expect { manager.get_scene('arena_1') }.to raise_error(Isotope::SceneNotFoundError)
    end

    it 'raises SceneNotFoundError for unknown scenes' do
      expect { manager.get_scene(999) }.to raise_error(Isotope::SceneNotFoundError)
      expect { manager.delete_scene('missing') }.to raise_error(Isotope::SceneNotFoundError)
    end
  end

  describe 'scene management methods per scene ID' do
    it 'supports create_rigidbody, get_rigidbody, add_linear_force, update_scene, and remove_rigidbody' do
      scene1_id, = manager.create_scene(id: 'alpha')
      scene2_id, = manager.create_scene(id: 'beta')

      body1_id, = manager.create_rigidbody(scene1_id, {
        'mass' => 2.0,
        'position' => { 'x' => 0.0, 'y' => 0.0 },
        'rotation' => 0.0
      })
      body2_id, = manager.create_rigidbody(scene2_id, {
        'mass' => 1.0,
        'position' => { 'x' => 10.0, 'y' => 20.0 },
        'rotation' => 0.0
      })

      manager.add_linear_force(scene1_id, body1_id, { 'x' => 4.0, 'y' => -19.6 })
      manager.update_scene(scene1_id, 0.5)

      _, b1 = manager.get_rigidbody(scene1_id, body1_id)
      _, b2 = manager.get_rigidbody(scene2_id, body2_id)

      # Scene 1 stepped forward: accel = (2.0, -9.8), dt = 0.5 => vel = (1.0, -4.9), pos = (0.5, -2.45)
      expect(b1.velocity.x).to be_within(1e-9).of(1.0)
      expect(b1.velocity.y).to be_within(1e-9).of(-4.9)
      expect(b1.position.x).to be_within(1e-9).of(0.5)
      expect(b1.position.y).to be_within(1e-9).of(-2.45)

      # Scene 2 remained completely isolated
      expect(b2.position).to eq(Rubidium::Vector2.new(10.0, 20.0))
      expect(b2.velocity).to eq(Rubidium::Vector2.new(0, 0))

      removed = manager.remove_rigidbody(scene1_id, body1_id)
      expect(removed).to equal(b1)
      expect { manager.get_rigidbody(scene1_id, body1_id) }.to raise_error(Isotope::RigidBodyNotFoundError)
      expect { manager.remove_rigidbody(scene1_id, body1_id) }.to raise_error(Isotope::RigidBodyNotFoundError)
    end

    it 'updates all scenes at once with #update_all' do
      s1, = manager.create_scene
      s2, = manager.create_scene
      b1, = manager.create_rigidbody(s1, { 'velocity' => { 'x' => 2.0, 'y' => 0.0 } })
      b2, = manager.create_rigidbody(s2, { 'velocity' => { 'x' => 0.0, 'y' => -4.0 } })

      manager.update_all(0.5)

      expect(manager.get_rigidbody(s1, b1).last.position.x).to be_within(1e-9).of(1.0)
      expect(manager.get_rigidbody(s2, b2).last.position.y).to be_within(1e-9).of(-2.0)
    end

    it 'saves and loads scenes via Rubidium::Scene2D save/load' do
      scene_id, = manager.create_scene(id: 'persisted')
      body_id, = manager.create_rigidbody(scene_id, {
        'mass' => 3.0,
        'position' => { 'x' => 7.0, 'y' => 8.0 },
        'collider' => { 'type' => 'CircleCollider', 'radius' => 1.2 }
      })

      Tempfile.create(['isotope_scene', '.json']) do |file|
        manager.save_scene(scene_id, file.path)

        # Load into a brand new scene ID
        loaded_id, loaded_scene = manager.load_scene('restored', file.path)
        expect(loaded_id).to eq('restored')
        restored_body = loaded_scene.get_rigidbody(body_id)
        expect(restored_body.mass).to eq(3.0)
        expect(restored_body.position).to eq(Rubidium::Vector2.new(7.0, 8.0))
        expect(restored_body.collider).to be_a(Rubidium::Collision::CircleCollider)

        # Load with nil ID allocates a new scene ID
        auto_id, auto_scene = manager.load_scene(nil, file.path)
        expect(auto_id).to be_a(Integer)
        expect(auto_scene.get_rigidbody(body_id).mass).to eq(3.0)

        # Load into an existing scene replaces its rigid bodies in-place
        manager.create_rigidbody('restored', { 'mass' => 99.0 })
        expect(manager.get_scene('restored').rigid_bodies.size).to eq(2)
        manager.load_scene('restored', file.path)
        expect(manager.get_scene('restored').rigid_bodies.size).to eq(1)
      end
    end

    it 'validates invalid time steps and file paths' do
      scene_id, = manager.create_scene
      expect { manager.update_scene(scene_id, 0) }.to raise_error(ArgumentError)
      expect { manager.update_scene(scene_id, -0.1) }.to raise_error(ArgumentError)
      expect { manager.update_scene(scene_id, 'fast') }.to raise_error(ArgumentError)
      expect { manager.save_scene(scene_id, '') }.to raise_error(ArgumentError)
      expect { manager.load_scene(scene_id, nil) }.to raise_error(ArgumentError)
    end
  end
end
