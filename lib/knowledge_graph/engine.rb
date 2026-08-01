# frozen_string_literal: true

require "pathname"

module KnowledgeGraph
  class Engine
    attr_reader :vault_root, :hooks, :run_id, :audit_log

    def initialize(vault_root:, handlers: {}, validator: nil, transaction_factory: nil,
                   run_id: nil, clock: nil, id_generator: nil, builtin_handlers: true,
                   audit_log: nil, receipt_store: nil, actor_id: nil)
      @vault_root = Pathname.new(vault_root).expand_path.freeze
      @run_id = (run_id || IdGenerator.new.generate("run")).freeze
      clock ||= -> { Time.now }
      id_generator ||= IdGenerator.new(clock: clock)
      @dispatcher = Dispatcher.new
      @hooks = HookBus.new
      @receipt_store = receipt_store || ReceiptStore.new(vault_root: @vault_root)
      @audit_log = audit_log || AuditLog.new(
        vault_root: @vault_root,
        clock: clock,
        id_generator: IdGenerator.new(clock: clock),
        actor_id: actor_id,
        run_id: @run_id
      )
      validator ||= default_validator
      @executor = Executor.new(
        vault_root: @vault_root,
        dispatcher: @dispatcher,
        hooks: @hooks,
        validator: validator,
        transaction_factory: transaction_factory,
        receipt_store: @receipt_store,
        audit_log: @audit_log
      )
      register_builtin_handlers(clock, id_generator) if builtin_handlers
      handlers.each { |intent_class, handler| register(intent_class, handler) }
    end

    def register(intent_class, handler = nil, &block)
      callable = handler || block
      raise ArgumentError, "handler must respond to call" unless callable&.respond_to?(:call)
      raise ArgumentError, "handler key must be an Intent class" unless intent_class <= Intent

      @dispatcher.register(intent_class, callable)
      self
    end

    def on(event, callable = nil, &block)
      @hooks.subscribe(event, callable, &block)
      self
    end

    def execute(intent)
      raise InvalidIntent, "execute expects a KnowledgeGraph::Intent" unless intent.is_a?(Intent)

      @executor.execute(intent)
    end

    def create_person(**attributes)
      execute(CreateEntity.new(entity_type: "person", attributes: attributes))
    end

    def update_person(entity_id, **changes)
      execute(UpdateEntity.new(entity_id: entity_id, changes: changes))
    end

    def link(source:, predicate:, target:, **attributes)
      execute(AddRelationship.new(source: source, predicate: predicate, target: target, attributes: attributes))
    end

    private

    def default_validator
      path = KnowledgeSDK.validator_path(@vault_root)
      return ExternalValidator.new(vault_root: @vault_root, validator_path: path) if path.file?

      lambda { |_context| raise ValidationError, "SDK validator not found: #{path}" }
    end

    def register_builtin_handlers(clock, id_generator)
      registry = SchemaRegistry.new(vault_root: @vault_root)
      manager = EntityManager.new(
        vault_root: @vault_root,
        registry: registry,
        writer: YamlWriter.new,
        id_generator: id_generator,
        clock: clock,
        run_id: @run_id
      )
      relationship_manager = RelationshipManager.new(
        vault_root: @vault_root,
        schema_registry: registry,
        relationship_registry: RelationshipRegistry.new(vault_root: @vault_root),
        writer: YamlWriter.new,
        id_generator: id_generator,
        clock: clock,
        run_id: @run_id
      )
      identity_manager = IdentityManager.new(
        vault_root: @vault_root,
        schema_registry: registry,
        relationship_registry: RelationshipRegistry.new(vault_root: @vault_root),
        entity_manager: manager,
        writer: YamlWriter.new,
        clock: clock,
        run_id: @run_id
      )
      {
        CreateEntity => :create,
        UpdateEntity => :update,
        RenameEntity => :rename,
        ArchiveEntity => :archive,
        RestoreEntity => :restore,
        AttachEvidence => :attach_evidence,
        ImportTranscript => :import_transcript,
        CompleteFollowUp => :complete_follow_up
      }.each { |intent_class, method_name| register(intent_class, manager.method(method_name)) }
      {
        CreateMeeting => :create_meeting,
        RecordInteraction => :record_interaction,
        RecordPromise => :record_promise
      }.each { |intent_class, method_name| register(intent_class, manager.method(method_name)) }
      {
        AddRelationship => :add,
        RemoveRelationship => :remove,
        ReplaceRelationship => :replace
      }.each do |intent_class, method_name|
        register(intent_class, relationship_manager.method(method_name))
      end
      register(MergeEntities, identity_manager.method(:merge))
      register(SplitEntity, identity_manager.method(:split))
    end
  end
end
