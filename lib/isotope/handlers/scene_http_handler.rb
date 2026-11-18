# frozen_string_literal: true

require 'oj'
require 'uri'
require_relative '../serializer'

module Isotope
  module Handlers
    # Handles HTTP JSON API requests for creating and managing scenes via Agoo.
    class SceneHttpHandler
      JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze

      def initialize(scene_manager, ws_handler: nil)
        @scene_manager = scene_manager
        @ws_handler = ws_handler
      end

      def call(env)
        method = env['REQUEST_METHOD']
        path = (env['PATH_INFO'] || '/').sub(%r{/+\z}, '')
        path = '/' if path.empty?

        route(method, path, env)
      rescue SceneNotFoundError, RigidBodyNotFoundError => e
        json_response(404, { 'status' => 'error', 'error' => e.message })
      rescue Oj::ParseError => e
        json_response(400, { 'status' => 'error', 'error' => "Invalid JSON: #{e.message}" })
      rescue ArgumentError => e
        json_response(400, { 'status' => 'error', 'error' => e.message })
      rescue StandardError => e
        json_response(500, { 'status' => 'error', 'error' => e.message })
      end

      private

      def route(method, path, env)
        return json_response(200, { 'status' => 'ok' }) if method == 'GET' && path == '/health'

        if path == '/scenes'
          case method
          when 'GET'
            return json_response(
              200,
              {
                'status' => 'ok',
                'scene_ids' => @scene_manager.scene_ids,
                'scenes' => @scene_manager.list_scenes
              }
            )
          when 'POST'
            payload = parse_json_body(env)
            scene_data = payload['scene'] || (payload['rigid_bodies'] ? { 'rigid_bodies' => payload['rigid_bodies'] } : nil)
            scene_id, scene = @scene_manager.create_scene(id: payload['scene_id'] || payload['id'], scene_data: scene_data)
            return json_response(
              201,
              {
                'status' => 'ok',
                'scene_id' => scene_id,
                'scene' => Serializer.serialize_scene(scene)
              }
            )
          end
        end

        segments = path.split('/').reject(&:empty?).map { |s| URI.decode_www_form_component(s) }
        return not_found unless segments[0] == 'scenes' && segments.size >= 2

        scene_id = @scene_manager.normalize_id(segments[1])

        case [method, segments.size, segments[2], segments[4]]
        in ['GET', 2, nil, nil]
          scene = @scene_manager.get_scene(scene_id)
          json_response(200, { 'status' => 'ok', 'scene_id' => scene_id, 'scene' => Serializer.serialize_scene(scene) })
        in ['DELETE', 2, nil, nil]
          @scene_manager.delete_scene(scene_id)
          @ws_handler&.clear_scene_subscriptions(scene_id)
          json_response(200, { 'status' => 'ok', 'scene_id' => scene_id })
        in ['POST', 3, 'update', nil]
          payload = parse_json_body(env)
          dt = if payload.key?('time_step')
                 payload['time_step'].nil? ? SceneManager::DEFAULT_TIME_STEP : payload['time_step']
               elsif payload.key?('dt')
                 payload['dt'].nil? ? SceneManager::DEFAULT_TIME_STEP : payload['dt']
               else
                 SceneManager::DEFAULT_TIME_STEP
               end
          scene = @scene_manager.update_scene(scene_id, dt)
          serialized = Serializer.serialize_scene(scene)
          @ws_handler&.broadcast(scene_id, { 'event' => 'scene_updated', 'scene_id' => scene_id, 'scene' => serialized })
          json_response(200, { 'status' => 'ok', 'scene_id' => scene_id, 'scene' => serialized })
        in ['POST', 3, 'save', nil]
          payload = parse_json_body(env)
          file_path = payload['file_path'] || payload['path']
          saved_path = @scene_manager.save_scene(scene_id, file_path)
          json_response(200, { 'status' => 'ok', 'scene_id' => scene_id, 'file_path' => saved_path })
        in ['POST', 3, 'load', nil]
          payload = parse_json_body(env)
          file_path = payload['file_path'] || payload['path']
          loaded_id, scene = @scene_manager.load_scene(scene_id, file_path)
          json_response(200, { 'status' => 'ok', 'scene_id' => loaded_id, 'scene' => Serializer.serialize_scene(scene) })
        in ['POST', 3, 'rigid_bodies', nil]
          payload = parse_json_body(env)
          body_data = payload['rigid_body'] || payload['body'] || payload
          body_id, body = @scene_manager.create_rigidbody(scene_id, body_data)
          serialized_body = Serializer.serialize_rigidbody(body, id: body_id)
          @ws_handler&.broadcast(
            scene_id,
            {
              'event' => 'rigidbody_created',
              'scene_id' => scene_id,
              'rigidbody_id' => body_id,
              'rigid_body' => serialized_body
            }
          )
          json_response(
            201,
            {
              'status' => 'ok',
              'scene_id' => scene_id,
              'rigidbody_id' => body_id,
              'rigid_body' => serialized_body
            }
          )
        in ['GET', 4, 'rigid_bodies', nil]
          body_id, body = @scene_manager.get_rigidbody(scene_id, segments[3])
          json_response(
            200,
            {
              'status' => 'ok',
              'scene_id' => scene_id,
              'rigidbody_id' => body_id,
              'rigid_body' => Serializer.serialize_rigidbody(body, id: body_id)
            }
          )
        in ['DELETE', 4, 'rigid_bodies', nil]
          norm_body_id = @scene_manager.normalize_id(segments[3])
          @scene_manager.remove_rigidbody(scene_id, norm_body_id)
          @ws_handler&.broadcast(
            scene_id,
            {
              'event' => 'rigidbody_removed',
              'scene_id' => scene_id,
              'rigidbody_id' => norm_body_id
            }
          )
          json_response(200, { 'status' => 'ok', 'scene_id' => scene_id, 'rigidbody_id' => norm_body_id })
        in ['POST', 5, 'rigid_bodies', 'force']
          payload = parse_json_body(env)
          norm_body_id = @scene_manager.normalize_id(segments[3])
          force = payload['force'] || (payload.key?('x') && payload.key?('y') ? payload : nil)
          raise ArgumentError, 'Missing required parameter: force' if force.nil?

          body = @scene_manager.add_linear_force(scene_id, norm_body_id, force)
          json_response(
            200,
            {
              'status' => 'ok',
              'scene_id' => scene_id,
              'rigidbody_id' => norm_body_id,
              'rigid_body' => Serializer.serialize_rigidbody(body, id: norm_body_id)
            }
          )
        else
          not_found
        end
      end

      def parse_json_body(env)
        input = env['rack.input']
        return {} if input.nil?

        raw = input.read
        return {} if raw.nil? || raw.strip.empty?

        parsed = Oj.load(raw, mode: :strict)
        raise ArgumentError, 'Request body must be a JSON object' unless parsed.is_a?(Hash)

        parsed
      end

      def not_found
        json_response(404, { 'status' => 'error', 'error' => 'Not found' })
      end

      def json_response(status, payload)
        [status, JSON_HEADERS.dup, [Oj.dump(payload, mode: :strict)]]
      end
    end
  end
end
