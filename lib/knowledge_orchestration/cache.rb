# frozen_string_literal: true

require "pathname"

module KnowledgeOrchestration
  class ArtifactDependencies
    attr_reader :observation_ids, :event_ids, :event_types, :entity_ids, :snapshot_digest,
                :capability_id, :capability_version

    def initialize(event_ids:, event_types:, snapshot_digest:, observation_ids: [], entity_ids: [],
                   capability_id: nil, capability_version: nil)
      @observation_ids = strings(observation_ids)
      @event_ids = strings(event_ids)
      @event_types = strings(event_types)
      @entity_ids = strings(entity_ids)
      @snapshot_digest = required(snapshot_digest, "snapshot digest")
      @capability_id = capability_id && required(capability_id, "capability id")
      @capability_version = capability_version && required(capability_version, "capability version")
      freeze
    end

    def to_h
      {
        observation_ids: observation_ids, event_ids: event_ids,
        event_types: event_types, entity_ids: entity_ids,
        snapshot_digest: snapshot_digest, capability_id: capability_id,
        capability_version: capability_version
      }.reject { |_key, value| value.nil? }
    end

    def with_event_id(event_id)
      self.class.new(
        observation_ids: observation_ids, event_ids: event_ids + [event_id.to_s], event_types: event_types,
        entity_ids: entity_ids, snapshot_digest: snapshot_digest,
        capability_id: capability_id, capability_version: capability_version
      )
    end

    def self.from_h(value)
      data = value.transform_keys(&:to_s)
      new(
        observation_ids: data.fetch("observation_ids", []),
        event_ids: data.fetch("event_ids"), event_types: data.fetch("event_types"),
        entity_ids: data.fetch("entity_ids", []), snapshot_digest: data.fetch("snapshot_digest"),
        capability_id: data["capability_id"], capability_version: data["capability_version"]
      )
    end

    private

    def strings(values)
      Array(values).map(&:to_s).reject(&:empty?).uniq.sort.freeze
    end

    def required(value, field)
      AgentPlatform::Value.required_string(value, field, maximum: 500)
    end
  end

  class CachedArtifact
    STATUSES = %w[valid stale].freeze
    TYPES = %w[
      analysis plan report briefing digest recommendation workflow_output
      knowledge_extraction entity_resolution
    ].freeze

    attr_reader :id, :artifact_type, :cache_key, :value, :dependencies,
                :created_at, :status, :invalidated_by, :metadata

    def initialize(id:, artifact_type:, cache_key:, value:, dependencies:, created_at:,
                   status: "valid", invalidated_by: [], metadata: {})
      @id = AgentPlatform::Value.required_string(id, "artifact id", maximum: 200)
      @artifact_type = artifact_type.to_s
      raise CacheError, "unsupported derived artifact type #{@artifact_type}" unless TYPES.include?(@artifact_type)
      @cache_key = AgentPlatform::Value.required_string(cache_key, "cache key", maximum: 200)
      raise CacheError, "artifact value must be an object" unless value.is_a?(Hash)
      raise CacheError, "artifact dependencies are required" unless dependencies.is_a?(ArtifactDependencies)
      @value = AgentPlatform::Value.immutable(value)
      @dependencies = dependencies
      parsed_created_at = created_at.is_a?(Time) ? created_at : Time.iso8601(created_at.to_s)
      @created_at = parsed_created_at.iso8601(6).freeze
      @status = status.to_s
      raise CacheError, "invalid artifact status" unless STATUSES.include?(@status)
      @invalidated_by = Array(invalidated_by).map(&:to_s).uniq.sort.freeze
      @metadata = AgentPlatform::Value.immutable(metadata || {})
      freeze
    rescue ArgumentError => error
      raise CacheError, error.message
    end

    def valid_for?(snapshot_digest)
      status == "valid" && dependencies.snapshot_digest == snapshot_digest.to_s
    end

    def stale(event_id)
      self.class.new(
        id: id, artifact_type: artifact_type, cache_key: cache_key, value: value,
        dependencies: dependencies, created_at: created_at, status: "stale",
        invalidated_by: (invalidated_by + [event_id.to_s]).uniq.sort, metadata: metadata
      )
    end

    def with_dependencies(updated_dependencies)
      self.class.new(
        id: id, artifact_type: artifact_type, cache_key: cache_key, value: value,
        dependencies: updated_dependencies, created_at: created_at, status: status,
        invalidated_by: invalidated_by, metadata: metadata
      )
    end

    def to_h
      {
        artifact_id: id, artifact_type: artifact_type, cache_key: cache_key,
        value: value, dependencies: dependencies.to_h, created_at: created_at,
        status: status, invalidated_by: invalidated_by, metadata: metadata
      }
    end

    def summary
      {
        artifact_id: id, artifact_type: artifact_type, cache_key: cache_key,
        dependencies: dependencies.to_h, created_at: created_at,
        status: status, invalidated_by: invalidated_by
      }
    end

    def self.from_h(value)
      data = value.transform_keys(&:to_s)
      new(
        id: data.fetch("artifact_id"), artifact_type: data.fetch("artifact_type"),
        cache_key: data.fetch("cache_key"), value: data.fetch("value"),
        dependencies: ArtifactDependencies.from_h(data.fetch("dependencies")),
        created_at: data.fetch("created_at"), status: data.fetch("status", "valid"),
        invalidated_by: data.fetch("invalidated_by", []), metadata: data.fetch("metadata", {})
      )
    end
  end

  class DependencyGraph
    def initialize(artifacts)
      @artifacts = Array(artifacts).freeze
    end

    def affected_by(event, new_snapshot_digest: nil)
      changed_ids = event_entity_ids(event)
      @artifacts.select do |artifact|
        dependency = artifact.dependencies
        type_match = dependency.event_types.include?(event.type)
        scope_match = dependency.entity_ids.empty? || !(dependency.entity_ids & changed_ids).empty?
        snapshot_changed = new_snapshot_digest && dependency.snapshot_digest != new_snapshot_digest.to_s
        type_match && scope_match && (event.type != "GraphChanged" || snapshot_changed)
      end.sort_by(&:id).freeze
    end

    def to_h
      {
        nodes: @artifacts.map { |artifact| { id: artifact.id, type: artifact.artifact_type, status: artifact.status } },
        edges: @artifacts.flat_map do |artifact|
          dependency = artifact.dependencies
          dependency.observation_ids.map { |id| { from: id, to: artifact.id, kind: "observation" } } +
            dependency.event_ids.map { |id| { from: id, to: artifact.id, kind: "event" } } +
            [{ from: dependency.snapshot_digest, to: artifact.id, kind: "snapshot" }] +
            dependency.entity_ids.map { |id| { from: id, to: artifact.id, kind: "entity_scope" } }
        end.sort_by { |edge| [edge[:to], edge[:kind], edge[:from]] }
      }
    end

    private

    def event_entity_ids(event)
      keys = %w[entity_id subject_id object_id person_id goal_id]
      direct = keys.map { |key| event.payload[key] }
      (direct + Array(event.payload["entity_ids"]) + Array(event.payload["changed_entity_ids"]))
        .compact.map(&:to_s).uniq
    end
  end

  class KnowledgeCache
    RUNTIME = File.join(EventStore::RUNTIME, "cache").freeze

    attr_reader :hits, :misses, :invalidations

    def initialize(vault_root:, clock: nil)
      @root = Pathname.new(vault_root).join(RUNTIME)
      @clock = clock || -> { Time.now }
      @hits = 0
      @misses = 0
      @invalidations = 0
    end

    def key(capability_id:, capability_version:, arguments:, snapshot_digest:)
      Stable.id("cache-key", capability_id, capability_version, arguments, snapshot_digest)
    end

    def fetch(cache_key, snapshot_digest:)
      artifact = find_by_key(cache_key)
      if artifact && artifact.valid_for?(snapshot_digest)
        @hits += 1
        artifact
      else
        @misses += 1
        nil
      end
    end

    def write(artifact_type:, cache_key:, value:, dependencies:, metadata: {})
      raise CacheError, "Knowledge Cache only accepts explicit ArtifactDependencies" unless dependencies.is_a?(ArtifactDependencies)
      artifact = CachedArtifact.new(
        id: Stable.id("artifact", artifact_type, cache_key), artifact_type: artifact_type,
        cache_key: cache_key, value: value, dependencies: dependencies,
        created_at: @clock.call.iso8601(6), metadata: metadata
      )
      AtomicFile.write_json(path_for(artifact.id), artifact.to_h)
      artifact
    end

    def record_reuse(artifact, event_id:)
      updated = artifact.with_dependencies(artifact.dependencies.with_event_id(event_id))
      AtomicFile.write_json(path_for(updated.id), updated.to_h)
      updated
    end

    def invalidate(event, new_snapshot_digest: nil)
      affected = dependency_graph.affected_by(event, new_snapshot_digest: new_snapshot_digest)
      affected.each do |artifact|
        AtomicFile.write_json(path_for(artifact.id), artifact.stale(event.id).to_h)
      end
      @invalidations += affected.length
      affected.map(&:id).freeze
    end

    def list(status: nil)
      return [] unless @root.directory?

      Dir[@root.join("artifact_*.json").to_s].sort.map { |path| CachedArtifact.from_h(AtomicFile.read_json(path, error_class: CacheError)) }
        .select { |artifact| !status || artifact.status == status.to_s }.freeze
    end

    def fetch_artifact(artifact_id)
      path = path_for(artifact_id)
      raise CacheError, "artifact not found: #{artifact_id}" unless path.file?

      CachedArtifact.from_h(AtomicFile.read_json(path, error_class: CacheError))
    end

    def dependency_graph
      DependencyGraph.new(list)
    end

    def metrics
      total = hits + misses
      {
        hits: hits, misses: misses, invalidations: invalidations,
        hit_rate: total.zero? ? 0.0 : (hits.to_f / total).round(6), artifacts: list.length
      }
    end

    private

    def find_by_key(cache_key)
      list.find { |artifact| artifact.cache_key == cache_key.to_s }
    end

    def path_for(artifact_id)
      value = artifact_id.to_s
      raise CacheError, "invalid artifact id" unless value.match?(/\Aartifact_[0-9A-HJKMNP-TV-Z]{26}\z/)

      @root.join("#{value}.json")
    end
  end
end
