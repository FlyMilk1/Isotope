# frozen_string_literal: true

require 'oj'
require 'rubidium'

module Isotope
  # Translates between JSON/Hash payloads and Rubidium physics objects.
  module Serializer
    module_function

    # Serializes a Rubidium::Scene2D into a JSON-compatible Ruby Hash.
    def serialize_scene(scene)
      Oj.load(Rubidium::SceneSaver.to_json(scene), mode: :strict)
    end

    # Serializes a single Rubidium::RigidBody2d into a JSON-compatible Hash.
    def serialize_rigidbody(body, id: nil)
      temp_scene = Rubidium::Scene2D.new({ 1 => body })
      data = serialize_scene(temp_scene)['rigid_bodies']['1']
      data['id'] = id unless id.nil?
      data
    end

    # Builds a Rubidium::Scene2D from nil, a Scene2D, a JSON string, or a Hash.
    def build_scene(data = nil)
      return Rubidium::Scene2D.new if data.nil?
      return data if data.is_a?(Rubidium::Scene2D)

      parsed = data.is_a?(String) ? Oj.load(data, mode: :strict) : data
      raise ArgumentError, "Expected scene data to be a Hash or JSON object" unless parsed.is_a?(Hash)
      return Rubidium::Scene2D.new if parsed.empty?

      normalized = normalize_scene_hash(parsed)
      json = Oj.dump(normalized, mode: :strict)
      Rubidium::SceneLoader.from_json(json)
    end

    # Builds a Rubidium::RigidBody2d from a RigidBody2d, a JSON string, or a Hash.
    def build_rigidbody(data)
      return data if data.is_a?(Rubidium::RigidBody2d)

      parsed = data.is_a?(String) ? Oj.load(data, mode: :strict) : data
      raise ArgumentError, "Expected rigid body data to be a Hash or JSON object" unless parsed.is_a?(Hash)

      normalized = normalize_rigidbody_hash(parsed)
      payload = {
        'type' => 'Scene2D',
        'rigid_bodies' => { '1' => normalized }
      }
      scene = Rubidium::SceneLoader.from_json(Oj.dump(payload, mode: :strict))
      scene.get_rigidbody(1)
    end

    # Builds a Rubidium::Vector2 from a Vector2, [x, y] Array, or {x, y} Hash.
    def build_vector2(data)
      return Rubidium::Vector2.new(data.x, data.y) if data.is_a?(Rubidium::Vector2)

      if data.is_a?(Array)
        raise ArgumentError, "Vector2 array must have 2 elements" unless data.size == 2

        return Rubidium::Vector2.new(Float(data[0]), Float(data[1]))
      end

      if data.is_a?(Hash)
        hash = stringify_keys(data)
        raise ArgumentError, "Vector2 hash must contain 'x' and 'y'" unless hash.key?('x') && hash.key?('y')

        return Rubidium::Vector2.new(Float(hash['x']), Float(hash['y']))
      end

      raise ArgumentError, "Unsupported Vector2 format: #{data.inspect}"
    end

    def normalize_scene_hash(raw)
      hash = stringify_keys(raw)
      scene_type = hash['type'] || 'Scene2D'
      raw_bodies = hash['rigid_bodies']

      normalized_bodies = case raw_bodies
                          when nil
                            {}
                          when Hash
                            raw_bodies.each_with_object({}) do |(id, entry), acc|
                              acc[id.to_s] = normalize_rigidbody_hash(entry)
                            end
                          when Array
                            raw_bodies.map { |entry| normalize_rigidbody_hash(entry) }
                          else
                            raise ArgumentError, "Expected 'rigid_bodies' to be a Hash or Array"
                          end

      {
        'type' => scene_type,
        'rigid_bodies' => normalized_bodies
      }
    end
    private_class_method :normalize_scene_hash

    def normalize_rigidbody_hash(raw)
      raise ArgumentError, "Expected rigid body entry to be a Hash" unless raw.is_a?(Hash)

      hash = stringify_keys(raw)
      result = {
        'type' => hash['type'] || 'RigidBody2d',
        'mass' => serialize_number_input(hash.key?('mass') ? hash['mass'] : 1.0),
        'position' => normalize_vector_hash(hash['position'] || { 'x' => 0.0, 'y' => 0.0 }),
        'rotation' => serialize_number_input(hash.key?('rotation') ? hash['rotation'] : 0.0),
        'drag' => serialize_number_input(hash.key?('drag') ? hash['drag'] : 0.0),
        'static' => hash['static'] ? true : false
      }

      result['velocity'] = normalize_vector_hash(hash['velocity']) if hash.key?('velocity') && !hash['velocity'].nil?
      result['acceleration'] = normalize_vector_hash(hash['acceleration']) if hash.key?('acceleration') && !hash['acceleration'].nil?
      result['angular_velocity'] = serialize_number_input(hash['angular_velocity']) if hash.key?('angular_velocity') && !hash['angular_velocity'].nil?
      result['angular_acceleration'] = serialize_number_input(hash['angular_acceleration']) if hash.key?('angular_acceleration') && !hash['angular_acceleration'].nil?
      result['collider'] = normalize_collider_hash(hash['collider']) if hash.key?('collider')
      result
    end
    private_class_method :normalize_rigidbody_hash

    def normalize_vector_hash(raw)
      case raw
      when Rubidium::Vector2
        { 'x' => serialize_number_input(raw.x), 'y' => serialize_number_input(raw.y) }
      when Array
        raise ArgumentError, "Vector array must have 2 elements" unless raw.size == 2

        { 'x' => serialize_number_input(raw[0]), 'y' => serialize_number_input(raw[1]) }
      when Hash
        hash = stringify_keys(raw)
        raise ArgumentError, "Vector hash must contain 'x' and 'y'" unless hash.key?('x') && hash.key?('y')

        { 'x' => serialize_number_input(hash['x']), 'y' => serialize_number_input(hash['y']) }
      else
        raise ArgumentError, "Unsupported vector format: #{raw.inspect}"
      end
    end
    private_class_method :normalize_vector_hash

    def normalize_collider_hash(raw)
      return nil if raw.nil?

      case raw
      when Rubidium::Collision::CircleCollider
        { 'type' => 'CircleCollider', 'radius' => serialize_number_input(raw.radius) }
      when Rubidium::Collision::RectangleCollider
        {
          'type' => 'RectangleCollider',
          'width' => serialize_number_input(raw.width),
          'height' => serialize_number_input(raw.height)
        }
      when Hash
        hash = stringify_keys(raw)
        case hash['type']
        when 'CircleCollider'
          { 'type' => 'CircleCollider', 'radius' => serialize_number_input(hash['radius']) }
        when 'RectangleCollider'
          {
            'type' => 'RectangleCollider',
            'width' => serialize_number_input(hash['width']),
            'height' => serialize_number_input(hash['height'])
          }
        else
          hash
        end
      else
        raise ArgumentError, "Unsupported collider format: #{raw.inspect}"
      end
    end
    private_class_method :normalize_collider_hash

    def serialize_number_input(value)
      return value unless value.is_a?(Float)
      return 'Infinity' if value == Float::INFINITY
      return '-Infinity' if value == -Float::INFINITY
      return 'NaN' if value.nan?

      value
    end
    private_class_method :serialize_number_input

    def stringify_keys(hash)
      hash.each_with_object({}) do |(k, v), acc|
        acc[k.to_s] = v
      end
    end
    private_class_method :stringify_keys
  end
end
