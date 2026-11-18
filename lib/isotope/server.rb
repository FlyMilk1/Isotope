# frozen_string_literal: true

require 'agoo'
require_relative 'scene_manager'
require_relative 'handlers/websocket_handler'
require_relative 'handlers/scene_http_handler'

module Isotope
  # Configures and runs the Agoo HTTP and WebSocket server for Isotope scenes.
  class Server
    attr_reader :port, :root, :scene_manager, :ws_handler, :http_handler

    def initialize(port: 6464, root: './public', thread_count: 1, scene_manager: SceneManager.new, log_console: false)
      @port = port
      @root = root
      @thread_count = thread_count
      @scene_manager = scene_manager
      @log_console = log_console
      @ws_handler = Handlers::WebSocketHandler.new(@scene_manager)
      @http_handler = Handlers::SceneHttpHandler.new(@scene_manager, ws_handler: @ws_handler)
      @started = false
    end

    def start
      return self if @started

      Agoo::Log.configure(
        dir: '',
        console: @log_console,
        classic: true,
        colorize: true,
        states: {
          INFO: @log_console,
          DEBUG: false,
          connect: @log_console,
          request: @log_console,
          response: @log_console,
          eval: @log_console,
          push: @log_console
        }
      )

      Agoo::Server.init(@port, @root, thread_count: @thread_count)
      register_routes
      Agoo::Server.start
      @started = true
      self
    end

    def stop
      return unless @started

      Agoo::Server.shutdown
      @started = false
    end

    def started?
      @started
    end

    private

    def register_routes
      Agoo::Server.handle(:GET, '/ws', @ws_handler)
      Agoo::Server.handle(:GET, '/health', @http_handler)
      Agoo::Server.handle(:GET, '/scenes', @http_handler)
      Agoo::Server.handle(:POST, '/scenes', @http_handler)
      Agoo::Server.handle(:GET, '/scenes/*', @http_handler)
      Agoo::Server.handle(:GET, '/scenes/**', @http_handler)
      Agoo::Server.handle(:POST, '/scenes/**', @http_handler)
      Agoo::Server.handle(:DELETE, '/scenes/**', @http_handler)
    end
  end
end
