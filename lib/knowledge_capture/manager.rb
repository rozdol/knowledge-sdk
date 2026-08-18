# frozen_string_literal: true

require "time"

module KnowledgeCapture
  class Manager
    IMMUTABLE_FIELDS = %w[
      id capture_id type schema_version kind title body captured_at created_at created_by source evidence
      url canonical_url domain resource_type user_note collections author_name published_at description
      content_excerpt content_hash fetch_status fetched_at page_language reading_status
    ].freeze

    def initialize(vault_root:, writer:, id_generator:, clock:, run_id:)
      @vault_root = Pathname.new(vault_root)
      @writer = writer
      @id_generator = id_generator
      @clock = clock
      @run_id = run_id
    end

    def create(intent, context)
      capture_id = intent.capture_id.to_s.empty? ? @id_generator.generate("capture") : intent.capture_id.to_s
      raise KnowledgeGraph::InvalidIntent, "invalid capture ID" unless capture_id.match?(/\Acapture_[0-9A-HJKMNP-TV-Z]{26}\z/)
      kind = intent.kind.to_s
      raise KnowledgeGraph::InvalidIntent, "unsupported capture kind #{kind.inspect}" unless Capture::KINDS.include?(kind)
      if bookmark_metadata_supplied?(intent) && kind != "bookmark"
        raise KnowledgeGraph::InvalidIntent, "bookmark metadata requires kind bookmark"
      end
      if kind == "bookmark" && intent.url.to_s.empty? && bookmark_metadata_supplied?(intent)
        raise KnowledgeGraph::InvalidIntent, "bookmark metadata requires url"
      end
      body = intent.body.to_s
      raise KnowledgeGraph::InvalidIntent, "capture body is required" if body.strip.empty?
      title = intent.title.to_s.strip
      raise KnowledgeGraph::InvalidIntent, "capture title is required" if title.empty?
      relative = File.join(Store::ROOT, "#{capture_id}.md")
      raise KnowledgeGraph::EntityConflict, "capture already exists: #{capture_id}" if context.transaction.exist?(relative)

      now = timestamp
      captured_at = normalize_time(intent.captured_at || @clock.call)
      schema_version = kind == "bookmark" && !intent.url.to_s.empty? ? 2 : 1
      data = {
        "id" => capture_id, "capture_id" => capture_id, "type" => "capture",
        "schema_version" => schema_version, "kind" => kind, "title" => title,
        "captured_at" => captured_at, "created_at" => now, "updated_at" => now,
        "created_by" => intent.created_by.to_s.empty? ? "agent" : intent.created_by.to_s,
        "updated_by" => "agent", "created_by_run" => @run_id, "updated_by_run" => @run_id,
        "importance" => intent.importance.to_s.empty? ? "normal" : intent.importance.to_s,
        "status" => "inbox", "review_state" => "unreviewed", "record_status" => "active",
        "topics" => strings(intent.topics), "tags" => (["knowledge/capture", "capture/#{kind}"] + strings(intent.tags)).uniq,
        "language" => intent.language.to_s.empty? ? "und" : intent.language.to_s,
        "related_entities" => [], "related_projects" => [], "related_contacts" => [],
        "evidence" => strings(intent.evidence), "source" => intent.source.to_s.empty? ? "unknown" : intent.source.to_s,
        "sensitivity" => intent.sensitivity.to_s.empty? ? "private" : intent.sensitivity.to_s
      }
      data.merge!(bookmark_data(intent)) if schema_version == 2
      Capture.new(data: data, body: body, relative_path: relative)
      context.transaction.write(relative, @writer.render(data, body: body))
      result(intent, capture_id, relative, data)
    end

    def review(intent, context)
      capture = store.find(intent.capture_id)
      reject_terminal!(capture, "review")
      status = capture.status == "inbox" ? "reviewed" : capture.status
      update(intent, context, capture, "review_state" => "reviewed", "status" => status)
    end

    def link(intent, context)
      capture = store.find(intent.capture_id)
      reject_terminal!(capture, "link")
      entities = validated_links(intent.related_entities, nil)
      projects = validated_links(intent.related_projects, "project")
      contacts = validated_links(intent.related_contacts, "person")
      if entities.empty? && projects.empty? && contacts.empty?
        raise KnowledgeGraph::InvalidIntent, "LinkCapture requires at least one approved canonical target"
      end
      status = %w[inbox reviewed].include?(capture.status) ? "linked" : capture.status
      update(
        intent, context, capture,
        "related_entities" => (capture.related_entities + entities).uniq,
        "related_projects" => (capture.related_projects + projects).uniq,
        "related_contacts" => (capture.related_contacts + contacts).uniq,
        "review_state" => "reviewed", "status" => status
      )
    end

    def promote(intent, context)
      capture = store.find(intent.capture_id)
      reject_terminal!(capture, "promote")
      targets = resolved_promotion_targets(intent.target_ids)
      raise KnowledgeGraph::InvalidIntent, "PromoteCapture requires at least one target ID" if targets.empty?
      update(
        intent, context, capture,
        "status" => "promoted", "review_state" => "reviewed",
        "promotion_kind" => intent.target_kind.to_s, "promoted_to" => targets
      )
    end

    def archive(intent, context)
      capture = store.find(intent.capture_id)
      return result(intent, capture.id, capture.relative_path, capture.data, replayed: true) if capture.status == "archived"
      raise InvalidTransition, "deleted captures cannot be archived" if capture.status == "deleted"

      update(intent, context, capture, "status" => "archived", "record_status" => "archived")
    end

    private

    def update(intent, context, capture, changes)
      invalid = changes.keys.map(&:to_s) & IMMUTABLE_FIELDS
      unless invalid.empty?
        raise KnowledgeGraph::InvalidIntent, "immutable capture fields cannot be changed: #{invalid.join(', ')}"
      end
      data = capture.data.merge(changes.transform_keys(&:to_s)).merge(
        "updated_at" => timestamp, "updated_by" => "agent", "updated_by_run" => @run_id
      )
      Capture.new(data: data, body: capture.body, relative_path: capture.relative_path)
      context.transaction.write(capture.relative_path, @writer.render(data, body: capture.body))
      result(intent, capture.id, capture.relative_path, data)
    end

    def validated_links(values, expected_type)
      ids = strings(values)
      return ids if ids.empty?

      registry = KnowledgeGraph::SchemaRegistry.new(vault_root: @vault_root)
      repository = KnowledgeGraph::Repository.new(vault_root: @vault_root, registry: registry)
      ids.each do |id|
        record = repository.resolve(id)
        if expected_type && record.type != expected_type
          raise KnowledgeGraph::InvalidIntent, "#{id} is not a #{expected_type}"
        end
      end
      ids
    end

    def resolved_promotion_targets(values)
      ids = strings(values)
      registry = KnowledgeGraph::SchemaRegistry.new(vault_root: @vault_root)
      repository = KnowledgeGraph::Repository.new(vault_root: @vault_root, registry: registry)
      ids.map do |reference|
        if reference.start_with?("relationship:")
          _label, source, predicate, target = reference.split(":", 4)
          source = repository.resolve(source).id
          target = repository.resolve(target).id
          definition = KnowledgeGraph::RelationshipRegistry.new(vault_root: @vault_root).fetch(predicate)
          source, target = [source, target].sort if definition.symmetric?
          record = repository.each_record.find do |candidate|
            candidate.type == "relationship" && candidate.data["relationship_status"] == "asserted" &&
              candidate.data["subject_id"] == source && candidate.data["predicate"] == predicate &&
              candidate.data["object_id"] == target
          end
          unless record
            raise KnowledgeGraph::EntityNotFound, "promoted relationship target was not created"
          end
          record.id
        else
          repository.resolve(reference).id
        end
      end.uniq
    end

    def reject_terminal!(capture, operation)
      return unless %w[archived deleted].include?(capture.status)

      raise InvalidTransition, "#{capture.status} capture cannot be #{operation}d"
    end

    def store
      Store.new(vault_root: @vault_root)
    end

    def timestamp
      @clock.call.iso8601
    end

    def normalize_time(value)
      (value.is_a?(Time) ? value : Time.iso8601(value.to_s)).iso8601
    rescue ArgumentError
      raise KnowledgeGraph::InvalidIntent, "captured_at must be ISO 8601"
    end

    def strings(value)
      Array(value).map(&:to_s).reject(&:empty?).uniq
    end

    def bookmark_data(intent)
      data = {
        "url" => intent.url, "canonical_url" => intent.canonical_url,
        "domain" => intent.domain, "resource_type" => intent.resource_type,
        "user_note" => intent.user_note, "collections" => strings(intent.collections),
        "author_name" => intent.author_name, "published_at" => intent.published_at,
        "description" => intent.description, "content_excerpt" => intent.content_excerpt,
        "content_hash" => intent.content_hash, "fetch_status" => intent.fetch_status,
        "fetched_at" => intent.fetched_at, "page_language" => intent.page_language,
        "reading_status" => intent.reading_status || "unread"
      }
      data = data.each_with_object({}) do |(key, value), result|
        next if value.nil? || (value.respond_to?(:empty?) && value.empty?)
        result[key] = value
      end
      %w[url canonical_url domain resource_type fetch_status].each do |field|
        if data[field].to_s.strip.empty?
          raise KnowledgeGraph::InvalidIntent, "bookmark Capture requires #{field}"
        end
      end
      {
        "url" => Bookmarks::MAX_URL_LENGTH, "canonical_url" => Bookmarks::MAX_URL_LENGTH,
        "author_name" => 500, "description" => 2_000,
        "content_excerpt" => Bookmarks::MAX_EXCERPT_LENGTH
      }.each do |field, maximum|
        if data[field].to_s.length > maximum
          raise KnowledgeGraph::InvalidIntent, "bookmark #{field} exceeds #{maximum} characters"
        end
      end
      data
    end

    def bookmark_metadata_supplied?(intent)
      values = %i[
        url canonical_url domain resource_type user_note collections author_name published_at
        description content_excerpt content_hash fetch_status fetched_at page_language reading_status
      ].map { |name| intent.public_send(name) }
      values.any? { |value| !value.nil? && (!value.respond_to?(:empty?) || !value.empty?) }
    end

    def result(intent, capture_id, relative, data, replayed: false)
      KnowledgeGraph::Result.new(
        intent_type: intent.intent_type, entity_ids: [capture_id], replayed: replayed,
        value: {
          "capture_id" => capture_id, "relative_path" => relative,
          "status" => data["status"], "kind" => data["kind"], "title" => data["title"]
        }.freeze
      )
    end
  end
end
