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
      @deferred_operation = nil
    end

    def defer(&operation)
      raise TransactionError, "deferred operation must respond to call" unless operation
      raise TransactionError, "execution context already has a deferred operation" if @deferred_operation

      @deferred_operation = operation
      self
    end

    def deferred?
      !@deferred_operation.nil?
    end

    def execute_deferred
      raise TransactionError, "execution context has no deferred operation" unless @deferred_operation

      operation = @deferred_operation
      @deferred_operation = nil
      operation.call
    end
  end

  class Executor
    def initialize(vault_root:, dispatcher:, hooks:, validator: nil, transaction_factory: nil,
                   receipt_store:, audit_log:)
      @vault_root = vault_root
      @dispatcher = dispatcher
      @hooks = hooks
      @validator = validator || ->(_context) {}
      @transaction_factory = transaction_factory || ->(root) { Transaction.new(vault_root: root) }
      @receipt_store = receipt_store
      @audit_log = audit_log
    end

    def execute(intent)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      transaction = @transaction_factory.call(@vault_root)
      context = ExecutionContext.new(intent: intent, transaction: transaction, vault_root: @vault_root)
      fingerprint = @receipt_store.fingerprint(intent)
      deferred_receipt = false

      begin
        @hooks.emit(:before_execute, context)
        receipt = @receipt_store.fetch(fingerprint)
        if receipt
          context.result = receipt
        else
          value = @dispatcher.dispatch(intent, context)
          context.result = preliminary_result(intent, value, transaction)
          if context.deferred?
            deferred_receipt = true
          else
            @receipt_store.stage(transaction, fingerprint, intent, context.result)
          end
        end
        @hooks.emit(:after_execute, context)
        @validator.call(context)
        @hooks.emit(:before_commit, context)
        if deferred_receipt
          value = context.execute_deferred
          context.result = preliminary_result(intent, value, transaction)
          @receipt_store.stage(transaction, fingerprint, intent, context.result)
        end
        transaction.commit
        @hooks.emit(:after_commit, context)
      rescue StandardError => error
        roll_back(context, transaction)
        audit_failure(intent, fingerprint, error, transaction, started_at)
        raise
      end

      result = finalize_result(context.result, started_at)
      audit_id = @audit_log.record(
        intent: intent,
        fingerprint: fingerprint,
        result: result,
        rollback: false,
        duration_ms: result.duration_ms
      )
      with_audit_id(result, audit_id)
    end

    private

    def preliminary_result(intent, value, transaction)
      if value.is_a?(Result)
        return Result.new(
          intent_type: value.intent_type,
          entity_ids: value.entity_ids,
          changed_paths: transaction.changed_paths,
          value: value.value,
          replayed: value.replayed
        )
      end

      Result.new(intent_type: intent.intent_type, changed_paths: transaction.changed_paths, value: value)
    end

    def finalize_result(result, started_at)
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000
      Result.new(
        intent_type: result.intent_type,
        entity_ids: result.entity_ids,
        changed_paths: result.changed_paths,
        value: result.value,
        replayed: result.replayed,
        duration_ms: elapsed.round(3),
        audit_id: result.audit_id
      )
    end

    def with_audit_id(result, audit_id)
      Result.new(
        intent_type: result.intent_type,
        entity_ids: result.entity_ids,
        changed_paths: result.changed_paths,
        value: result.value,
        replayed: result.replayed,
        duration_ms: result.duration_ms,
        audit_id: audit_id
      )
    end

    def audit_failure(intent, fingerprint, error, transaction, started_at)
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000
      @audit_log.record(
        intent: intent,
        fingerprint: fingerprint,
        error: error,
        rollback: transaction.nil? || transaction.state != :committed,
        duration_ms: elapsed.round(3)
      )
    rescue AuditError => audit_error
      raise AuditError, "#{error.class}: #{error.message}; audit failed: #{audit_error.message}"
    end

    def roll_back(context, transaction)
      return unless transaction && transaction.state == :open

      @hooks.emit(:before_rollback, context)
      transaction.rollback
      @hooks.emit(:after_rollback, context)
    end
  end
end
