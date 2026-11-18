# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('lib', __dir__))
require 'isotope'

port = ENV.fetch('PORT', 6464).to_i
root = File.expand_path('public', __dir__)

server = Isotope::Server.new(
  port: port,
  root: root,
  thread_count: ENV.fetch('THREADS', 1).to_i,
  log_console: ENV.fetch('ISOTOPE_LOG', 'true') == 'true'
)

server.start

puts "Isotope server listening on http://localhost:#{port}"
puts "  WebSocket endpoint: ws://localhost:#{port}/ws"
puts "  HTTP API endpoint:  http://localhost:#{port}/scenes"

stop_requested = false
%w[INT TERM].each do |sig|
  Signal.trap(sig) { stop_requested = true }
end

sleep 0.2 until stop_requested
server.stop
