# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "tempfile"
require "time"

module KnowledgePlanning
  class GoalStore
    RUNTIME = "#{KnowledgeSDK::RUNTIME_PATH}/planning/goals".freeze

    def initialize(vault_root:, id_generator: nil, clock: nil)
      @root = Pathname.new(vault_root).join(RUNTIME)
      @clock = clock || -> { Time.now }
      @id_generator = id_generator || KnowledgeGraph::IdGenerator.new(clock: @clock)
    end

    def create(attributes)
      values = attributes.transform_keys(&:to_s)
      goal = Goal.new(
        id: values["id"] || @id_generator.generate("goal"),
        description: values.fetch("description"), goal_type: values.fetch("goal_type", "generic"),
        priority: values.fetch("priority", "normal"), deadline: values["deadline"],
        constraints: values.fetch("constraints", {}), preferences: values.fetch("preferences", {}),
        success_criteria: values.fetch("success_criteria", []), status: values.fetch("status", "active"),
        created_at: values["created_at"] || @clock.call.iso8601
      )
      write(goal)
      goal
    rescue KeyError => error
      raise InvalidGoal, "missing goal field #{error.key}"
    end

    def fetch(id)
      path = goal_path(id)
      raise GoalNotFound, "goal not found: #{id}" unless path.file?

      Goal.new(**JSON.parse(path.read).transform_keys(&:to_sym))
    rescue JSON::ParserError => error
      raise InvalidGoal, "stored goal is invalid JSON: #{error.message}"
    end

    def list(status: nil)
      return [] unless @root.directory?

      Dir[@root.join("goal_*.json").to_s].sort.map { |path| fetch(File.basename(path, ".json")) }
        .select { |goal| !status || goal.status == status.to_s }.sort_by(&:id).freeze
    end

    def archive(id)
      current = fetch(id)
      archived = current.with_status("archived")
      write(archived)
      archived
    end

    private

    def write(goal)
      path = goal_path(goal.id)
      FileUtils.mkdir_p(path.dirname)
      Tempfile.create([".goal", ".tmp"], path.dirname.to_s) do |file|
        file.write(JSON.pretty_generate(Immutable.canonical(goal.to_h)) + "\n")
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path.to_s)
      end
      path
    end

    def goal_path(id)
      value = id.to_s
      unless value.match?(/\Agoal_[0-9A-HJKMNP-TV-Z]{26}\z/)
        raise InvalidGoal, "invalid goal ID"
      end

      @root.join("#{value}.json")
    end
  end
end
