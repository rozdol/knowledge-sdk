# frozen_string_literal: true

# Synthetic test fixture only. No test controls or clock hooks enter the product.
require "knowledge_sdk/dashboard"
require "socket"
operator = File.realpath(ARGV.fetch(0))
KnowledgeSDK.config_path = File.join(operator, "sdk-config.yml")
vault = File.join(operator, "synthetic-independent-vault")
Dir.mkdir(vault)
KnowledgeSDK::PluginRegistry.new.install("personal-crm", vault)
engine = KnowledgeGraph::Engine.new(vault_root: vault, run_id: "run_00000000000000000000000001")
[
  ["person_00000000000000000000000002", "Ada Synthetic", ["Ada", "Αδά", "Ада"], "private"],
  ["person_00000000000000000000000003", "Synthetic <img src=x onerror=window.injected=true>", ["Unsafe"], "private"],
  ["person_00000000000000000000000004", "Hidden Synthetic", ["Secret"], "restricted"],
  ["person_00000000000000000000000005", "Other Synthetic", [], "private"]
].each do |id, name, aliases, sensitivity|
  engine.execute(KnowledgeGraph::CreateEntity.new(entity_type: "person", attributes: {
    id: id, name: name, aliases: aliases, tier: "active", sensitivity: sensitivity, data_origin: "public"
  }))
end
reader = KnowledgeGraph::GraphReader.new(vault_root: vault)
engine.execute(KnowledgeGraph::RecordInteraction.new(attributes: {
  name: "Synthetic recorded call", starts_at: Time.now.getutc.iso8601,
  participants: [reader.find("person_00000000000000000000000002").link, reader.find("person_00000000000000000000000005").link],
  interaction_kind: "call", contact_weight: "substantive", sensitivity: "private", data_origin: "public"
}))
engine.execute(KnowledgeGraph::AddRelationship.new(source: "person_00000000000000000000000002", predicate: "knows", target: "person_00000000000000000000000005"))
engine.execute(KnowledgeGraph::CreateCapture.new(capture_id: "capture_00000000000000000000000006", kind: "bookmark", title: "Synthetic research resource",
  body: "**Synthetic** research on Unicode Αδά and literal text <script>neverExecute()</script>.",
  captured_at: Time.now.getutc.iso8601, language: "en", source: "test"))
settings_file = File.join(operator, "settings.json")
File.write(settings_file, JSON.generate(version: 1, permissions: %w[graph:read capture:read intelligence:read activity:read]), mode: "w", perm: 0o600)
secret = SecureRandom.urlsafe_base64(32)
secret_file = File.join(operator, "secret")
File.write(secret_file, secret, mode: "w", perm: 0o600)
reservation = TCPServer.new("127.0.0.1", 0)
port = reservation.addr[1]
reservation.close
settings = KnowledgeSDK::Dashboard::Settings.new(vault: vault, timezone: "Europe/Berlin",
  secret_file: secret_file, settings_file: settings_file, config_path: KnowledgeSDK.config_path, port: port)
clock_file = File.join(operator, "clock-shift")
File.write(clock_file, "0")
clock = -> { Time.now + Integer(File.read(clock_file)) }
log = File.open(File.join(operator, "host.log"), "w")
app = KnowledgeSDK::Dashboard::App.new(settings, clock: clock, logger: log)
metadata = { origin: settings.origin, secret: secret, vault: vault,
             files: Dir.glob(File.join(vault, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] } }
server = KnowledgeSDK::Dashboard::Server.new(app, BindAddress: "127.0.0.1", Port: port,
  StartCallback: -> { File.write(File.join(operator, "fixture.json"), JSON.generate(metadata), mode: "w", perm: 0o600) },
  RequestTimeout: 10, AccessLog: [], Logger: WEBrick::Log.new(File::NULL, WEBrick::Log::FATAL))
%w[INT TERM].each { |signal| Signal.trap(signal) { server.shutdown } }
server.start
app.close
log.close
