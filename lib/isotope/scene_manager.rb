# frozen_string_literal: true

require 'rubidium'
require_relative 'serializer'

module Isotope
  class SceneNotFoundError < KeyError; end
  class RigidBodyNotFoundError < KeyError; end

  # Thread-safe registry managing multiple independent Rubidium::Scene2D instances by ID.
  class SceneManager
    DEFAULT_TIME_STEP = 1.0 / 60.0

    def initialize
      @scenes = {}
      @next_id = 1
      @mutex = Mutex.new
    end

    # Normalizes an integer or string ID (numeric strings become Integers).
    def normalize_id(id)
      case id
      when Integer
        id
      when String
        raise ArgumentError, 'ID cannot be empty' if id.empty?

        id.match?(/\A-?\d+\z/) ? id.to_i : id
      when Symbol
        normalize_id(id.to_s)
      else
        raise ArgumentError, "Invalid ID: #{id.inspect}"
      end
    end

    # Creates a new Rubidium::Scene2D (optionally with an explicit ID and initial state).
    # Returns [scene_id, scene].
    def create_scene(id: nil, scene_data: nil)
      scene = Serializer.build_scene(scene_data)
      @mutex.synchronize do
        scene_id = id.nil? ? allocate_id : normalize_id(id)
        @scenes[scene_id] = scene
        [scene_id, scene]
      end
    end

    # Retrieves a scene by ID or raises SceneNotFoundError.
    def get_scene(scene_id)
      norm_id = normalize_id(scene_id)
      @mutex.synchronize { fetch_scene(norm_id) }
    end

    # Returns true if a scene with +scene_id+ exists.
    def scene?(scene_id)
      norm_id = normalize_id(scene_id)
      @mutex.synchronize { @scenes.key?(norm_id) }
    end

    # Deletes and returns the scene with +scene_id+, or raises SceneNotFoundError.
    def delete_scene(scene_id)
      norm_id = normalize_id(scene_id)
      @mutex.synchronize do
        scene = @scenes.delete(norm_id)
        raise SceneNotFoundError, "Scene not found: #{scene_id}" if scene.nil?

        scene
      end
    end

    # Returns a hash mapping stringified scene IDs to serialized scene states.
    def list_scenes
      @mutex.synchronize do
        @scenes.each_with_object({}) do |(id, scene), acc|
          acc[id.to_s] = Serializer.serialize_scene(scene)
        end
      end
    end

    # Returns all active scene IDs.
    def scene_ids
      @mutex.synchronize { @scenes.keys }
    end

    # Removes all scenes and resets the ID sequence.
    def clear
      @mutex.synchronize do
        @scenes.clear
        @next_id = 1
      end
    end

    # Creates a rigid body inside the scene identified by +scene_id+.
    # Returns [body_id, body].
    def create_rigidbody(scene_id, body_data = {})
      norm_scene_id = normalize_id(scene_id)
      body = Serializer.build_rigidbody(body_data)
      @mutex.synchronize do
        scene = fetch_scene(norm_scene_id)
        body_id = scene.create_rigidbody(body)
        [body_id, body]
      end
    end

    # Retrieves a rigid body from +scene_id+ by +body_id+.
    # Returns [norm_body_id, body].
    def get_rigidbody(scene_id, body_id)
      norm_scene_id = normalize_id(scene_id)
      norm_body_id = normalize_id(body_id)
      @mutex.synchronize do
        scene = fetch_scene(norm_scene_id)
        [norm_body_id, fetch_rigidbody(scene, norm_scene_id, norm_body_id)]
      end
    end

    # Removes a rigid body from +scene_id+ by +body_id+ and returns it.
    def remove_rigidbody(scene_id, body_id)
      norm_scene_id = normalize_id(scene_id)
      norm_body_id = normalize_id(body_id)
      @mutex.synchronize do
        scene = fetch_scene(norm_scene_id)
        body = scene.rigid_bodies.delete(norm_body_id)
        raise RigidBodyNotFoundError, "RigidBody #{body_id} not found in scene #{scene_id}" if body.nil?

        body
      end
    end

    # Applies a linear force vector to a rigid body in +scene_id+.
    def add_linear_force(scene_id, body_id, force_data)
      norm_scene_id = normalize_id(scene_id)
      norm_body_id = normalize_id(body_id)
      force = Serializer.build_vector2(force_data)
      @mutex.synchronize do
        scene = fetch_scene(norm_scene_id)
        body = fetch_rigidbody(scene, norm_scene_id, norm_body_id)
        body.add_linear_force(force)
        body
      end
    end

    # Steps +scene_id+ forward by +time_step+ seconds and returns the scene.
    def update_scene(scene_id, time_step = DEFAULT_TIME_STEP)
      norm_scene_id = normalize_id(scene_id)
      dt = parse_time_step(time_step)
      @mutex.synchronize do
        scene = fetch_scene(norm_scene_id)
        scene.update(dt)
        scene
      end
    end

    # Steps all registered scenes forward by +time_step+ seconds.
    def update_all(time_step = DEFAULT_TIME_STEP)
      dt = parse_time_step(time_step)
      @mutex.synchronize do
        @scenes.each_value { |scene| scene.update(dt) }
        @scenes.dup
      end
    end

    # Saves the scene identified by +scene_id+ to +file_path+.
    def save_scene(scene_id, file_path)
      validate_file_path!(file_path)
      norm_scene_id = normalize_id(scene_id)
      @mutex.synchronize do
        scene = fetch_scene(norm_scene_id)
        scene.save(file_path)
        file_path
      end
    end

    # Loads a scene from +file_path+ into +scene_id+ (or allocates a new ID if nil).
    # Returns [scene_id, scene].
    def load_scene(scene_id, file_path)
      validate_file_path!(file_path)
      @mutex.synchronize do
        if scene_id.nil?
          scene = Rubidium::Scene2D.load(file_path)
          new_id = allocate_id
          @scenes[new_id] = scene
          [new_id, scene]
        else
          norm_id = normalize_id(scene_id)
          scene = @scenes[norm_id]
          if scene
            scene.load(file_path)
          else
            scene = Rubidium::Scene2D.load(file_path)
            @scenes[norm_id] = scene
          end
          [norm_id, scene]
        end
      end
    end

    # Executes a block with serialized access to a scene and returns the serialized snapshot.
    def serialize(scene_id)
      norm_id = normalize_id(scene_id)
      @mutex.synchronize do
        Serializer.serialize_scene(fetch_scene(norm_id))
      end
    end

    private

    def allocate_id
      @next_id += 1 while @scenes.key?(@next_id)
      id = @next_id
      @next_id += 1
      id
    end

    def fetch_scene(norm_id)
      scene = @scenes[norm_id]
      raise SceneNotFoundError, "Scene not found: #{norm_id}" if scene.nil?

      scene
    end

    def fetch_rigidbody(scene, norm_scene_id, norm_body_id)
      body = scene.get_rigidbody(norm_body_id)
      raise RigidBodyNotFoundError, "RigidBody #{norm_body_id} not found in scene #{norm_scene_id}" if body.nil?

      body
    end

    def parse_time_step(time_step)
      return DEFAULT_TIME_STEP if time_step.nil?

      raise ArgumentError, "time_step must be numeric, got #{time_step.inspect}" unless time_step.is_a?(Numeric)

      dt = time_step.to_f
      raise ArgumentError, "time_step must be positive, got #{time_step.inspect}" unless dt.finite? && dt.positive?

      dt
    end

    def validate_file_path!(file_path)
      raise ArgumentError, 'file_path cannot be nil or empty' if file_path.nil? || file_path.to_s.strip.empty?
    end
  end
end
