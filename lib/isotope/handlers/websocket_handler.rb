# frozen_string_literal: true

require 'set'
require 'oj'
require_relative '../serializer'

module Isotope
  module Handlers
    # Handles Agoo WebSocket upgrades and dispatches JSON scene-management commands.
    class WebSocketHandler
      def initialize(scene_manager)
        @scene_manager = scene_manager
        @clients = Set.new
        @subscriptions = Hash.new { |h, k| h[k] = Set.new }
        @mutex = Mutex.new
      end

      def call(env)
        if env['rack.upgrade?'] == :websocket || env['rack.upgrade?'] == :sse
          env['rack.upgrade'] = self
          [200, {}, []]
        else
          body = Oj.dump({ 'status' => 'error', 'error' => 'WebSocket upgrade required' }, mode: :strict)
          [400, { 'Content-Type' => 'application/json' }, [body]]
        end
      end

      def on_open(client)
        @mutex.synchronize do
          @clients.add(client)
        end
      end

      def on_close(client)
        @mutex.synchronize do
          @clients.delete(client)
          @subscriptions.each_value { |set| set.delete(client) }
        end
      end

      def on_message(client, raw_data)
        msg = nil
        action = nil
        request_id = nil

        msg = Oj.load(raw_data, mode: :strict)
        raise ArgumentError, 'Message must be a JSON object' unless msg.is_a?(Hash)

        request_id = msg['request_id'] if msg.key?('request_id')
        action = msg['action'] || msg['method'] || msg['type']
        raise ArgumentError, 'Missing action' if action.nil? || action.to_s.empty?

        response = dispatch_action(client, action.to_s, msg)
        response['request_id'] = request_id unless request_id.nil?
        send_json(client, response)
      rescue Oj::ParseError => e
        send_error(client, "Invalid JSON: #{e.message}", action: action, request_id: request_id)
      rescue SceneNotFoundError, RigidBodyNotFoundError, ArgumentError => e
        send_error(client, e.message, action: action, request_id: request_id)
      rescue StandardError => e
        send_error(client, e.message, action: action, request_id: request_id)
      end

      # Broadcasts an event payload to all clients subscribed to +scene_id+.
      def broadcast(scene_id, payload, exclude: nil)
        norm_id = @scene_manager.normalize_id(scene_id)
        targets = @mutex.synchronize do
          subscribers = @subscriptions[norm_id]
          subscribers ? subscribers.reject { |c| exclude && c.equal?(exclude) } : []
        end
        return if targets.empty?

        json = Oj.dump(payload, mode: :strict)
        targets.each do |target|
          send_raw(target, json)
        end
      end

      def client_count
        @mutex.synchronize { @clients.size }
      end

      def clear_scene_subscriptions(scene_id)
        norm_id = @scene_manager.normalize_id(scene_id)
        @mutex.synchronize { @subscriptions.delete(norm_id) }
      end

      private

      def dispatch_action(client, action, msg)
        case action
        when 'ping'
          { 'status' => 'ok', 'action' => 'ping', 'message' => 'pong' }
        when 'create_scene'
          handle_create_scene(client, msg)
        when 'get_scene'
          raw_id = require_param(msg, 'scene_id', 'id')
          norm_id = @scene_manager.normalize_id(raw_id)
          scene = @scene_manager.get_scene(norm_id)
          { 'status' => 'ok', 'action' => 'get_scene', 'scene_id' => norm_id, 'scene' => Serializer.serialize_scene(scene) }
        when 'list_scenes'
          scenes = @scene_manager.list_scenes
          { 'status' => 'ok', 'action' => 'list_scenes', 'scene_ids' => @scene_manager.scene_ids, 'scenes' => scenes }
        when 'delete_scene'
          raw_id = require_param(msg, 'scene_id', 'id')
          norm_id = @scene_manager.normalize_id(raw_id)
          @scene_manager.delete_scene(norm_id)
          @mutex.synchronize { @subscriptions.delete(norm_id) }
          { 'status' => 'ok', 'action' => 'delete_scene', 'scene_id' => norm_id }
        when 'create_rigidbody'
          handle_create_rigidbody(client, msg)
        when 'get_rigidbody'
          handle_get_rigidbody(msg)
        when 'remove_rigidbody'
          handle_remove_rigidbody(client, msg)
        when 'add_linear_force'
          handle_add_linear_force(msg)
        when 'update', 'update_scene', 'step'
          handle_update_scene(client, action, msg)
        when 'update_all'
          handle_update_all(client, msg)
        when 'save', 'save_scene'
          raw_id = require_param(msg, 'scene_id', 'id')
          norm_id = @scene_manager.normalize_id(raw_id)
          file_path = require_param(msg, 'file_path', 'path')
          saved_path = @scene_manager.save_scene(norm_id, file_path)
          { 'status' => 'ok', 'action' => action, 'scene_id' => norm_id, 'file_path' => saved_path }
        when 'load', 'load_scene'
          raw_id = msg['scene_id'] || msg['id']
          file_path = require_param(msg, 'file_path', 'path')
          loaded_id, scene = @scene_manager.load_scene(raw_id, file_path)
          { 'status' => 'ok', 'action' => action, 'scene_id' => loaded_id, 'scene' => Serializer.serialize_scene(scene) }
        when 'subscribe'
          raw_id = require_param(msg, 'scene_id', 'id')
          norm_id = @scene_manager.normalize_id(raw_id)
          @scene_manager.get_scene(norm_id)
          subscribe_client(client, norm_id)
          { 'status' => 'ok', 'action' => 'subscribe', 'scene_id' => norm_id }
        when 'unsubscribe'
          raw_id = require_param(msg, 'scene_id', 'id')
          norm_id = @scene_manager.normalize_id(raw_id)
          unsubscribe_client(client, norm_id)
          { 'status' => 'ok', 'action' => 'unsubscribe', 'scene_id' => norm_id }
        else
          raise ArgumentError, "Unknown action: #{action}"
        end
      end

      def handle_create_scene(client, msg)
        scene_data = msg['scene'] || (msg['rigid_bodies'] ? { 'rigid_bodies' => msg['rigid_bodies'] } : nil)
        scene_id, scene = @scene_manager.create_scene(id: msg['scene_id'] || msg['id'], scene_data: scene_data)
        subscribe_client(client, scene_id) unless msg['subscribe'] == false
        {
          'status' => 'ok',
          'action' => 'create_scene',
          'scene_id' => scene_id,
          'scene' => Serializer.serialize_scene(scene)
        }
      end

      def handle_create_rigidbody(client, msg)
        norm_scene_id = @scene_manager.normalize_id(require_param(msg, 'scene_id'))
        body_data = msg['rigid_body'] || msg['body'] || {}
        body_id, body = @scene_manager.create_rigidbody(norm_scene_id, body_data)
        serialized_body = Serializer.serialize_rigidbody(body, id: body_id)

        broadcast(
          norm_scene_id,
          {
            'event' => 'rigidbody_created',
            'scene_id' => norm_scene_id,
            'rigidbody_id' => body_id,
            'rigid_body' => serialized_body
          },
          exclude: client
        )

        {
          'status' => 'ok',
          'action' => 'create_rigidbody',
          'scene_id' => norm_scene_id,
          'rigidbody_id' => body_id,
          'rigid_body' => serialized_body
        }
      end

      def handle_get_rigidbody(msg)
        norm_scene_id = @scene_manager.normalize_id(require_param(msg, 'scene_id'))
        raw_body_id = require_param(msg, 'rigidbody_id', 'body_id', 'id')
        body_id, body = @scene_manager.get_rigidbody(norm_scene_id, raw_body_id)
        {
          'status' => 'ok',
          'action' => 'get_rigidbody',
          'scene_id' => norm_scene_id,
          'rigidbody_id' => body_id,
          'rigid_body' => Serializer.serialize_rigidbody(body, id: body_id)
        }
      end

      def handle_remove_rigidbody(client, msg)
        norm_scene_id = @scene_manager.normalize_id(require_param(msg, 'scene_id'))
        norm_body_id = @scene_manager.normalize_id(require_param(msg, 'rigidbody_id', 'body_id', 'id'))
        @scene_manager.remove_rigidbody(norm_scene_id, norm_body_id)

        broadcast(
          norm_scene_id,
          {
            'event' => 'rigidbody_removed',
            'scene_id' => norm_scene_id,
            'rigidbody_id' => norm_body_id
          },
          exclude: client
        )

        {
          'status' => 'ok',
          'action' => 'remove_rigidbody',
          'scene_id' => norm_scene_id,
          'rigidbody_id' => norm_body_id
        }
      end

      def handle_add_linear_force(msg)
        norm_scene_id = @scene_manager.normalize_id(require_param(msg, 'scene_id'))
        norm_body_id = @scene_manager.normalize_id(require_param(msg, 'rigidbody_id', 'body_id', 'id'))
        force = require_param(msg, 'force')
        body = @scene_manager.add_linear_force(norm_scene_id, norm_body_id, force)
        {
          'status' => 'ok',
          'action' => 'add_linear_force',
          'scene_id' => norm_scene_id,
          'rigidbody_id' => norm_body_id,
          'rigid_body' => Serializer.serialize_rigidbody(body, id: norm_body_id)
        }
      end

      def handle_update_scene(client, action, msg)
        norm_scene_id = @scene_manager.normalize_id(require_param(msg, 'scene_id', 'id'))
        dt = extract_time_step(msg)
        scene = @scene_manager.update_scene(norm_scene_id, dt)
        serialized_scene = Serializer.serialize_scene(scene)

        broadcast(
          norm_scene_id,
          {
            'event' => 'scene_updated',
            'scene_id' => norm_scene_id,
            'scene' => serialized_scene
          },
          exclude: client
        )

        {
          'status' => 'ok',
          'action' => action,
          'scene_id' => norm_scene_id,
          'scene' => serialized_scene
        }
      end

      def handle_update_all(client, msg)
        dt = extract_time_step(msg)
        @scene_manager.update_all(dt)
        scenes = @scene_manager.list_scenes

        scenes.each do |sid, serialized|
          norm_id = @scene_manager.normalize_id(sid)
          broadcast(
            norm_id,
            {
              'event' => 'scene_updated',
              'scene_id' => norm_id,
              'scene' => serialized
            },
            exclude: client
          )
        end

        {
          'status' => 'ok',
          'action' => 'update_all',
          'scenes' => scenes
        }
      end

      def extract_time_step(msg)
        if msg.key?('time_step')
          msg['time_step'].nil? ? SceneManager::DEFAULT_TIME_STEP : msg['time_step']
        elsif msg.key?('dt')
          msg['dt'].nil? ? SceneManager::DEFAULT_TIME_STEP : msg['dt']
        else
          SceneManager::DEFAULT_TIME_STEP
        end
      end

      def subscribe_client(client, norm_scene_id)
        @mutex.synchronize do
          @subscriptions[norm_scene_id].add(client)
        end
      end

      def unsubscribe_client(client, norm_scene_id)
        @mutex.synchronize do
          @subscriptions[norm_scene_id]&.delete(client)
        end
      end

      def require_param(msg, *keys)
        keys.each do |key|
          return msg[key] if msg.key?(key) && !msg[key].nil?
        end
        raise ArgumentError, "Missing required parameter: #{keys.join(' or ')}"
      end

      def send_json(client, payload)
        send_raw(client, Oj.dump(payload, mode: :strict))
      end

      def send_error(client, message, action: nil, request_id: nil)
        payload = { 'status' => 'error', 'error' => message }
        payload['action'] = action unless action.nil?
        payload['request_id'] = request_id unless request_id.nil?
        send_json(client, payload)
      end

      def send_raw(client, json)
        return unless client.open?

        client.write(json)
      rescue StandardError
        # Ignore write errors on closing/disconnected sockets
      end
    end
  end
end
