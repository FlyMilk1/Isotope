# frozen_string_literal: true

require 'digest/sha1'
require 'net/http'
require 'securerandom'
require 'socket'
require 'tempfile'
require 'timeout'

# Minimal RFC 6455 WebSocket client for testing Agoo WebSocket endpoints end-to-end.
class WebSocketTestClient
  WS_MAGIC_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

  def initialize(host, port, path = '/ws')
    @socket = TCPSocket.new(host, port)
    @read_buffer = +''.b
    perform_handshake(host, port, path)
  end

  def send_text(text)
    payload = text.to_s.b
    frame = encode_frame(0x1, payload)
    @socket.write(frame)
    @socket.flush
  end

  def send_json(hash)
    send_text(Oj.dump(hash, mode: :strict))
  end

  def recv_text(timeout: 5.0)
    deadline = Time.now + timeout
    loop do
      b0, b1 = read_exact(2, deadline).unpack('CC')
      opcode = b0 & 0x0F
      masked = (b1 & 0x80) != 0
      len = b1 & 0x7F

      if len == 126
        len = read_exact(2, deadline).unpack1('n')
      elsif len == 127
        len = read_exact(8, deadline).unpack1('Q>')
      end

      mask_key = masked ? read_exact(4, deadline).bytes : nil
      payload = len.positive? ? read_exact(len, deadline) : +''.b
      payload = unmask(payload, mask_key) if masked

      case opcode
      when 0x8 # Close
        return nil
      when 0x9 # Ping -> respond with Pong
        @socket.write(encode_frame(0xA, payload))
        @socket.flush
      when 0xA # Pong -> ignore and read next frame
        next
      else
        return payload.force_encoding('UTF-8')
      end
    end
  end

  def recv_json(timeout: 5.0)
    raw = recv_text(timeout: timeout)
    raise EOFError, 'WebSocket closed before frame arrived' if raw.nil?

    Oj.load(raw, mode: :strict)
  end

  def request(hash, timeout: 5.0)
    send_json(hash)
    recv_json(timeout: timeout)
  end

  def close
    return if @socket.closed?

    @socket.write(encode_frame(0x8, +''.b))
    @socket.flush
  rescue StandardError
    nil
  ensure
    @socket.close unless @socket.closed?
  end

  private

  def perform_handshake(host, port, path)
    key = [SecureRandom.random_bytes(16)].pack('m0')
    req = [
      "GET #{path} HTTP/1.1",
      "Host: #{host}:#{port}",
      'Upgrade: websocket',
      'Connection: Upgrade',
      "Sec-WebSocket-Key: #{key}",
      'Sec-WebSocket-Version: 13',
      '',
      ''
    ].join("\r\n")

    @socket.write(req)
    @socket.flush

    deadline = Time.now + 5.0
    until @read_buffer.include?("\r\n\r\n")
      fill_buffer(deadline)
    end

    header_end = @read_buffer.index("\r\n\r\n") + 4
    headers_raw = @read_buffer.slice!(0, header_end)
    lines = headers_raw.split("\r\n")

    raise "WebSocket handshake failed: #{lines.first}" unless lines.first&.include?('101')

    expected_accept = [Digest::SHA1.digest("#{key}#{WS_MAGIC_GUID}")].pack('m0')
    accept_header = lines.find { |l| l.downcase.start_with?('sec-websocket-accept:') }
    actual_accept = accept_header&.split(':', 2)&.last&.strip
    raise "Invalid Sec-WebSocket-Accept: expected #{expected_accept}, got #{actual_accept}" unless actual_accept == expected_accept
  end

  def encode_frame(opcode, payload)
    len = payload.bytesize
    header = [0x80 | opcode].pack('C')
    header << if len <= 125
                [0x80 | len].pack('C')
              elsif len <= 0xFFFF
                [0x80 | 126, len].pack('Cn')
              else
                [0x80 | 127, len].pack('CQ>')
              end

    mask_key = SecureRandom.random_bytes(4).bytes
    masked_bytes = payload.bytes.each_with_index.map { |byte, idx| byte ^ mask_key[idx % 4] }
    header + mask_key.pack('C4') + masked_bytes.pack('C*')
  end

  def unmask(payload, mask_key)
    payload.bytes.each_with_index.map { |byte, idx| byte ^ mask_key[idx % 4] }.pack('C*')
  end

  def read_exact(count, deadline)
    while @read_buffer.bytesize < count
      fill_buffer(deadline)
    end
    @read_buffer.slice!(0, count)
  end

  def fill_buffer(deadline)
    remaining = deadline - Time.now
    raise Timeout::Error, 'Timed out waiting for WebSocket data' if remaining <= 0

    ready = IO.select([@socket], nil, nil, remaining)
    raise Timeout::Error, 'Timed out waiting for WebSocket data' if ready.nil?

    chunk = @socket.readpartial(4096)
    @read_buffer << chunk
  end
end

RSpec.describe Isotope::Server do
  let(:port) { @port }

  before(:all) do
    tcp = TCPServer.new('127.0.0.1', 0)
    @port = tcp.addr[1]
    tcp.close

    @server = described_class.new(
      port: @port,
      root: File.expand_path('../../public', __dir__),
      thread_count: 1,
      log_console: false
    )
    @server.start

    deadline = Time.now + 3.0
    loop do
      res = Net::HTTP.get_response(URI("http://127.0.0.1:#{@port}/health"))
      break if res.code == '200'
    rescue StandardError
      raise 'Isotope::Server did not become ready in time' if Time.now > deadline

      sleep 0.02
    end
  end

  after(:all) do
    @server&.stop
  end

  before(:each) do
    @server.scene_manager.clear
  end

  def open_ws
    WebSocketTestClient.new('127.0.0.1', port, '/ws')
  end

  def http_request(method, path, body = nil)
    uri = URI("http://127.0.0.1:#{port}#{path}")
    klass = case method
            when :get then Net::HTTP::Get
            when :post then Net::HTTP::Post
            when :delete then Net::HTTP::Delete
            else raise ArgumentError, "Unsupported method: #{method}"
            end
    req = klass.new(uri)
    if body
      req['Content-Type'] = 'application/json'
      req.body = Oj.dump(body, mode: :strict)
    end
    res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
    parsed = res.body && !res.body.empty? ? Oj.load(res.body, mode: :strict) : nil
    [res.code.to_i, parsed]
  end

  describe 'WebSocket API (/ws)' do
    it 'responds to ping and rejects non-upgrade HTTP requests to /ws' do
      code, payload = http_request(:get, '/ws')
      expect(code).to eq(400)
      expect(payload['status']).to eq('error')

      ws = open_ws
      res = ws.request({ 'action' => 'ping', 'request_id' => 'p-1' })
      expect(res).to eq('status' => 'ok', 'action' => 'ping', 'message' => 'pong', 'request_id' => 'p-1')
    ensure
      ws&.close
    end

    it 'creates multiple scenes by ID and keeps their simulation state isolated' do
      ws = open_ws

      s1 = ws.request({ 'action' => 'create_scene', 'request_id' => 1 })
      expect(s1['status']).to eq('ok')
      expect(s1['scene_id']).to eq(1)
      expect(s1['request_id']).to eq(1)

      s2 = ws.request({
        'action' => 'create_scene',
        'scene_id' => 'arena_2',
        'scene' => {
          'rigid_bodies' => {
            '1' => {
              'mass' => 1.0,
              'position' => { 'x' => 10.0, 'y' => 20.0 },
              'rotation' => 0.0
            }
          }
        }
      })
      expect(s2['status']).to eq('ok')
      expect(s2['scene_id']).to eq('arena_2')

      # Add a rigid body to scene 1, apply force, and step scene 1
      created_body = ws.request({
        'action' => 'create_rigidbody',
        'scene_id' => 1,
        'rigid_body' => {
          'mass' => 2.0,
          'position' => { 'x' => 0.0, 'y' => 0.0 },
          'rotation' => 0.0,
          'collider' => { 'type' => 'CircleCollider', 'radius' => 0.5 }
        }
      })
      expect(created_body['status']).to eq('ok')
      body_id = created_body['rigidbody_id']
      expect(body_id).to eq(1)
      expect(created_body['rigid_body']['collider']).to eq('type' => 'CircleCollider', 'radius' => 0.5)

      forced = ws.request({
        'action' => 'add_linear_force',
        'scene_id' => 1,
        'rigidbody_id' => body_id,
        'force' => { 'x' => 4.0, 'y' => -19.6 }
      })
      expect(forced['status']).to eq('ok')
      expect(forced['rigid_body']['acceleration']).to eq('x' => 2.0, 'y' => -9.8)

      stepped = ws.request({
        'action' => 'update',
        'scene_id' => 1,
        'time_step' => 0.5
      })
      expect(stepped['status']).to eq('ok')
      b1_state = stepped['scene']['rigid_bodies'][body_id.to_s]
      expect(b1_state['velocity']['x']).to be_within(1e-9).of(1.0)
      expect(b1_state['velocity']['y']).to be_within(1e-9).of(-4.9)
      expect(b1_state['position']['x']).to be_within(1e-9).of(0.5)
      expect(b1_state['position']['y']).to be_within(1e-9).of(-2.45)

      # Verify get_rigidbody matches
      fetched_body = ws.request({ 'action' => 'get_rigidbody', 'scene_id' => 1, 'rigidbody_id' => body_id })
      expect(fetched_body['rigid_body']['position']['y']).to be_within(1e-9).of(-2.45)

      # Verify scene 'arena_2' did NOT move
      scene2_state = ws.request({ 'action' => 'get_scene', 'scene_id' => 'arena_2' })
      expect(scene2_state['scene']['rigid_bodies']['1']['position']).to eq('x' => 10.0, 'y' => 20.0)

      # List scenes shows both
      listed = ws.request({ 'action' => 'list_scenes' })
      expect(listed['scenes'].keys).to contain_exactly('1', 'arena_2')

      # Remove rigid body and delete scene
      removed = ws.request({ 'action' => 'remove_rigidbody', 'scene_id' => 1, 'rigidbody_id' => body_id })
      expect(removed['status']).to eq('ok')
      expect(ws.request({ 'action' => 'get_rigidbody', 'scene_id' => 1, 'rigidbody_id' => body_id })['status']).to eq('error')

      deleted = ws.request({ 'action' => 'delete_scene', 'scene_id' => 'arena_2' })
      expect(deleted['status']).to eq('ok')
      expect(ws.request({ 'action' => 'get_scene', 'scene_id' => 'arena_2' })['status']).to eq('error')
    ensure
      ws&.close
    end

    it 'supports save, load, and update_all over WebSocket' do
      ws = open_ws
      ws.request({ 'action' => 'create_scene', 'scene_id' => 's1' })
      ws.request({ 'action' => 'create_scene', 'scene_id' => 's2' })
      ws.request({ 'action' => 'create_rigidbody', 'scene_id' => 's1', 'rigid_body' => { 'velocity' => { 'x' => 2.0, 'y' => 0.0 } } })
      ws.request({ 'action' => 'create_rigidbody', 'scene_id' => 's2', 'rigid_body' => { 'velocity' => { 'x' => 0.0, 'y' => 4.0 } } })

      all_updated = ws.request({ 'action' => 'update_all', 'time_step' => 0.5 })
      expect(all_updated['status']).to eq('ok')
      expect(all_updated['scenes']['s1']['rigid_bodies']['1']['position']['x']).to be_within(1e-9).of(1.0)
      expect(all_updated['scenes']['s2']['rigid_bodies']['1']['position']['y']).to be_within(1e-9).of(2.0)

      Tempfile.create(['ws_scene', '.json']) do |file|
        saved = ws.request({ 'action' => 'save', 'scene_id' => 's1', 'file_path' => file.path })
        expect(saved['status']).to eq('ok')

        loaded = ws.request({ 'action' => 'load', 'scene_id' => 's1_copy', 'file_path' => file.path })
        expect(loaded['status']).to eq('ok')
        expect(loaded['scene_id']).to eq('s1_copy')
        expect(loaded['scene']['rigid_bodies']['1']['position']['x']).to be_within(1e-9).of(1.0)
      end
    ensure
      ws&.close
    end

    it 'broadcasts scene updates and body changes to subscribed WebSocket clients' do
      client_a = open_ws
      client_b = open_ws

      created = client_a.request({ 'action' => 'create_scene', 'scene_id' => 'shared_world' })
      expect(created['status']).to eq('ok')

      sub = client_b.request({ 'action' => 'subscribe', 'scene_id' => 'shared_world' })
      expect(sub['status']).to eq('ok')

      body_res = client_a.request({
        'action' => 'create_rigidbody',
        'scene_id' => 'shared_world',
        'rigid_body' => { 'mass' => 1.0, 'velocity' => { 'x' => 4.0, 'y' => 0.0 } }
      })
      expect(body_res['status']).to eq('ok')

      event1 = client_b.recv_json
      expect(event1['event']).to eq('rigidbody_created')
      expect(event1['scene_id']).to eq('shared_world')
      expect(event1['rigidbody_id']).to eq(body_res['rigidbody_id'])

      step_res = client_a.request({ 'action' => 'update', 'scene_id' => 'shared_world', 'time_step' => 0.25 })
      expect(step_res['status']).to eq('ok')

      event2 = client_b.recv_json
      expect(event2['event']).to eq('scene_updated')
      expect(event2['scene_id']).to eq('shared_world')
      expect(event2['scene']['rigid_bodies']['1']['position']['x']).to be_within(1e-9).of(1.0)

      unsub = client_b.request({ 'action' => 'unsubscribe', 'scene_id' => 'shared_world' })
      expect(unsub['status']).to eq('ok')
    ensure
      client_a&.close
      client_b&.close
    end

    it 'returns structured JSON error responses for invalid messages and missing targets' do
      ws = open_ws

      ws.send_text('{not valid json')
      err1 = ws.recv_json
      expect(err1['status']).to eq('error')
      expect(err1['error']).to include('Invalid JSON')

      err2 = ws.request({ 'action' => 'does_not_exist', 'request_id' => 'bad-1' })
      expect(err2['status']).to eq('error')
      expect(err2['action']).to eq('does_not_exist')
      expect(err2['request_id']).to eq('bad-1')
      expect(err2['error']).to include('Unknown action')

      err3 = ws.request({ 'action' => 'get_scene', 'scene_id' => 'nonexistent', 'request_id' => 'bad-2' })
      expect(err3['status']).to eq('error')
      expect(err3['request_id']).to eq('bad-2')
      expect(err3['error']).to include('Scene not found')
    ensure
      ws&.close
    end
  end

  describe 'HTTP REST API' do
    it 'exposes /health and full CRUD/simulation routes under /scenes' do
      code, health = http_request(:get, '/health')
      expect(code).to eq(200)
      expect(health).to eq('status' => 'ok')

      code, created = http_request(:post, '/scenes', { 'scene_id' => 'http_scene' })
      expect(code).to eq(201)
      expect(created['scene_id']).to eq('http_scene')

      code, list = http_request(:get, '/scenes')
      expect(code).to eq(200)
      expect(list['scenes'].keys).to eq(['http_scene'])

      code, body_res = http_request(:post, '/scenes/http_scene/rigid_bodies', {
        'mass' => 2.0,
        'position' => { 'x' => 0.0, 'y' => 0.0 },
        'collider' => { 'type' => 'RectangleCollider', 'width' => 4, 'height' => 2 }
      })
      expect(code).to eq(201)
      body_id = body_res['rigidbody_id']

      code, force_res = http_request(:post, "/scenes/http_scene/rigid_bodies/#{body_id}/force", {
        'force' => { 'x' => 6.0, 'y' => 0.0 }
      })
      expect(code).to eq(200)
      expect(force_res['rigid_body']['acceleration']['x']).to eq(3.0)

      code, updated = http_request(:post, '/scenes/http_scene/update', { 'time_step' => 1.0 })
      expect(code).to eq(200)
      expect(updated['scene']['rigid_bodies'][body_id.to_s]['position']['x']).to be_within(1e-9).of(3.0)

      code, fetched_body = http_request(:get, "/scenes/http_scene/rigid_bodies/#{body_id}")
      expect(code).to eq(200)
      expect(fetched_body['rigid_body']['position']['x']).to be_within(1e-9).of(3.0)

      Tempfile.create(['http_scene', '.json']) do |file|
        code, saved = http_request(:post, '/scenes/http_scene/save', { 'file_path' => file.path })
        expect(code).to eq(200)
        expect(saved['file_path']).to eq(file.path)

        code, loaded = http_request(:post, '/scenes/http_scene_loaded/load', { 'file_path' => file.path })
        expect(code).to eq(200)
        expect(loaded['scene']['rigid_bodies'][body_id.to_s]['position']['x']).to be_within(1e-9).of(3.0)
      end

      code, bad_update = http_request(:post, '/scenes/http_scene/update', { 'time_step' => -1 })
      expect(code).to eq(400)
      expect(bad_update['status']).to eq('error')

      code, missing = http_request(:get, '/scenes/unknown_id')
      expect(code).to eq(404)
      expect(missing['status']).to eq('error')

      code, removed_body = http_request(:delete, "/scenes/http_scene/rigid_bodies/#{body_id}")
      expect(code).to eq(200)
      expect(removed_body['rigidbody_id']).to eq(body_id)

      code, deleted = http_request(:delete, '/scenes/http_scene')
      expect(code).to eq(200)
      expect(deleted['scene_id']).to eq('http_scene')
    end
  end
end
