# frozen_string_literal: true

module KnowledgeGraph
  class ExecutionContext
    attr_reader :intent, :transaction, :vault_root
    attr_accessor :result

    def initialize(intent:, transaction:, vault_root:)
      @intent = intent
      @transaction = transaction
      @vault_root = vault_root
      @result = nil
    end
  end

  class Executor
    def initialize(vault_root:, dispatcher:, hooks:, validator: nil, transaction_factory: nil)
      @vault_root = vault_root
      @dispatcher = dispatcher
      @hooks = hooks
      @validator = validator || ->(_context) {}
      @transaction_factory = transaction_factory || ->(root) { Transaction.new(vault_root: root) }
    end

    def execute(intent)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      transaction = @transaction_factory.call(@vault_root)
      context = ExecutionContext.new(intent: intent, transaction: transaction, vault_root: @vault_root)

      @hooks.emit(:before_execute, context)
      value = @dispatcher.dispatch(intent, context)
      context.result = preliminary_result(intent, value, transaction)
      @hooks.emit(:after_execute, context)
      @validator.call(context)
      @hooks.emit(:before_commit, context)
      transaction.commit
      @hooks.emit(:after_commit, context)

      finalize_result(context.result, transaction, started_at)
    rescue StandardError
      roll_back(context, transaction)
      raise
    end

    private

    def preliminary_result(intent, value, transaction)
      return value if value.is_a?(Result)

      Result.new(intent_type: intent.intent_type, changed_paths: transaction.changed_paths, value: value)
    end

    def finalize_result(result, transaction, started_at)
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000
      Result.new(
        intent_type: result.intent_type,
        entity_ids: result.entity_ids,
        changed_paths: transaction.changed_paths,
        value: result.value,
        replayed: result.replayed,
        duration_ms: elapsed.round(3),
        audit_id: result.audit_id
      )
    end

    def roll_back(context, transaction)
      return unless transaction && transaction.state == :open

      @hooks.emit(:before_rollback, context)
      transaction.rollback
      @hooks.emit(:after_rollback, context)
    end
  end
end
