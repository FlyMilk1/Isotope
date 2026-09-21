# test_agoo.rb
#
# Minimal smoke test for an Agoo install. Verifies:
#   1. Agoo loads and the C extension is built correctly
#   2. Plain HTTP routing works
#   3. WebSocket upgrade + echo works
#
# Run:
#   bundle exec ruby test_agoo.rb
#
# Then:
#   curl http://localhost:6464/hello
#   -> open public/test.html in a browser, or use the Ruby/JS client below

require 'agoo'

PORT = 6464

Agoo::Log.configure(
  dir: '',
  console: true,
  classic: true,
  colorize: true,
  states: { INFO: true, DEBUG: false, connect: true, request: true, response: true }
)

# --- Plain HTTP handler ----------------------------------------------------

class HelloHandler
  def call(env)
    [200, { 'Content-Type' => 'text/plain' }, ["Agoo is alive on port #{PORT}"]]
  end
end

# --- WebSocket echo handler --------------------------------------------------

class EchoHandler
  def call(env)
    if env['rack.upgrade?'] == :websocket
      env['rack.upgrade'] = self
      [200, {}, []]
    else
      [400, { 'Content-Type' => 'text/plain' }, ['websocket upgrade required']]
    end
  end

  def on_open(client)
    puts "[ws] client connected"
    client.write("welcome")
  end

  def on_message(client, data)
    puts "[ws] received: #{data}"
    client.write("echo: #{data}")
  end

  def on_close(client)
    puts "[ws] client disconnected"
  end
end

# --- Boot --------------------------------------------------------------------

Agoo::Server.init(PORT, '.', thread_count: 1)
Agoo::Server.handle(:GET, '/hello', HelloHandler.new)
Agoo::Server.handle(:GET, '/ws', EchoHandler.new)
Agoo::Server.start

puts "Isotope/Agoo test server running on http://localhost:#{PORT}"
puts "  HTTP test:      curl http://localhost:#{PORT}/hello"
puts "  WebSocket test: connect to ws://localhost:#{PORT}/ws"
puts "Press Ctrl+C to stop."

sleep