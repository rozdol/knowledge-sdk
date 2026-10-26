# frozen_string_literal: true

module AgentPlatform
  # SDK-owned read compatibility layouts; these never provision or alter a template.
  class HealthReads < ReadViews
    FIELDS = %w[test_date observed_at panel analyte value unit reference_low reference_high reference_text flag specimen laboratory method].freeze
    GROUP = %w[subject_id analyte unit method specimen laboratory].freeze
    SOURCE_LIMIT = 100_000

    def self.register(registry, services)
      %w[labs lab_series].each do |operation|
        registry.register("kg.health.#{operation}") do |arguments, context|
          HandlerResult.new(payload: new(services, context).call(operation, arguments),
            why: "Read explicitly scoped laboratory observations with a nonmigrating Reader; no clinical inference or execution authority.")
        end
      end
    end

    def call(operation, arguments)
      @args = arguments.dup
      scopes = operation == "labs" && @args["scopes"] == true
      raise InvalidArguments, "scopes accepts no filters" if scopes && @args.keys != ["scopes"]
      raise InvalidArguments, "subject is required" unless scopes || @args["subject_id"]
      validate_dates! unless scopes
      return unavailable("source_bound_reached") unless within_read_budget?
      if !scopes && !subject(@args["subject_id"])
        raise PolicyDenied, "record not found"
      end
      registrations = raw_snapshot.records(type: "dataset").select do |record|
        clinical_visible?(record) && (record["dataset_template"] == "blood_tests" || record["dataset_slug"] == "blood_tests") &&
          references_visible?(record.data)
      end
      return unavailable("laboratory_history_unavailable") if registrations.empty?
      return unavailable("source_bound_reached") if registrations.length > 50
      @rows, @subjects, @unknown, @read_count = [], [], false, 0
      reader = @services.activity_reader(@context)
      reader.with_consistent_read do
        registrations.each do |registration|
          description = reader.describe(registration.id)
          return unavailable("laboratory_schema_unsupported") unless compatible?(description)
          @subjects << description["owner_id"] if subject(description["owner_id"])
          load_rows(reader, registration, description)
        end
      end
      return subject_scopes if scopes
      selected = @rows.select { |row| row["subject_id"] == @args["subject_id"] && matches?(row) }
      return unavailable("subject_scope_unknown") if selected.empty? && @unknown
      raise PolicyDenied, "record not found" unless @subjects.include?(@args["subject_id"])
      @limitations = @unknown ? ["subject_scope_unknown"] : []
      return series(selected) if operation == "lab_series"
      selected.sort_by! { |row| [row["test_date"], row["observed_at"].to_s, row["dataset_id"], row["row_id"]] }
      selected.reverse!
      response = list(selected, selected.map { |row| row.values_at("test_date", "observed_at", "dataset_id", "row_id") }, limitations: @limitations)
      response["evidence"] = evidence(selected)
      response
    rescue StructuredDataset::StorageUnavailable => error
      unavailable(error.code)
    rescue StructuredDataset::Error
      unavailable("laboratory_history_invalid")
    rescue ArgumentError, TypeError
      raise InvalidArguments, "invalid typed laboratory arguments"
    end

    private

    def clinical_visible?(record)
      visible?(record) && (record["sensitivity"] != "restricted" || @agent.permits?("dataset:restricted"))
    end

    def subject(id)
      record = raw_snapshot.record(id)
      record if record && record.type == "person" && record.active? && clinical_visible?(record)
    end

    def references_visible?(value)
      audit_references(value).all? { |id| clinical_visible?(raw_snapshot.record(id)) }
    end

    def validate_dates!
      raise InvalidArguments, "both laboratory boundaries are required" if !!@args["from"] != !!@args["to"]
      @args["to"] ||= @services.clock.call.utc.to_date.iso8601
      @args["from"] ||= (Date.iso8601(@args["to"]) - 29).iso8601
      dates = %w[from to].map do |key|
        value = @args.fetch(key)
        raise ArgumentError unless value.match?(/\A\d{4}-\d\d-\d\d\z/)
        Date.iso8601(value)
      end
      raise ArgumentError unless dates[1] >= dates[0] && dates[1] - dates[0] <= 366
    end

    def compatible?(description)
      template = StructuredDataset.template_registry.fetch("blood_tests")
      metadata = description.values_at("template", "template_version", "template_digest")
      if metadata.any?
        return false unless metadata == [template.id, template.version, template.digest]
      else
        return false unless description["slug"] == "blood_tests"
      end
      columns = description.fetch("columns").to_h { |column| [column.fetch(:name), column.fetch(:type)] }
      trusted = template.definition.columns.to_h { |column| [column.name, [column.type]] }
      # Explicit read variants support already-recorded qualitative results and
      # optional row subjects/methods. Numeric-looking TEXT remains TEXT.
      trusted.merge!("value" => %w[REAL INTEGER TEXT], "subject_id" => ["TEXT"], "sensitivity" => ["TEXT"], "method" => ["TEXT"])
      return false unless columns.all? { |name, type| trusted.fetch(name, []).include?(type) }
      canonical = columns["test_date"] == "DATE" && columns["analyte"] == "TEXT"
      legacy = columns["observed_at"] == "DATETIME" && columns["marker"] == "TEXT"
      (canonical || legacy) && columns.key?("value")
    end

    def load_rows(reader, registration, description)
      offset = 0
      loop do
        page = reader.query(registration.id, order: "row_id:asc", limit: 10_000, offset: offset)
        @read_count += page.length
        raise StructuredDataset::StorageUnavailable, "laboratory_source_bound_reached" if @read_count > SOURCE_LIMIT
        page.each do |row|
          next if row["sensitivity"] == "restricted" && !%w[graph:restricted dataset:restricted].all? { |grant| @agent.permits?(grant) }
          content = row.reject { |key, _| StructuredDataset::Definition::RESERVED_COLUMNS.include?(key) }
          next unless references_visible?(content)
          row_subject, owner = row["subject_id"], description["owner_id"]
          if row_subject && owner && row_subject != owner
            raise StructuredDataset::StorageUnavailable, "subject_scope_conflict"
          end
          id = row_subject || owner
          if id.nil? || id.empty?
            @unknown = true
            next
          end
          next unless subject(id)
          item = FIELDS.to_h { |key| [key, row[key]] }
          item["test_date"] ||= row["observed_at"] && row["observed_at"][0, 10]
          item["analyte"] ||= row["marker"]
          raise StructuredDataset::StorageUnavailable, "laboratory_history_invalid" unless item["test_date"] && item["analyte"] && !item["value"].nil?
          Date.iso8601(item["test_date"])
          if item.values.grep(String).any? { |value| value.length > 1000 }
            raise StructuredDataset::StorageUnavailable, "laboratory_value_bound_reached"
          end
          item.merge!("subject_id" => id, "dataset_id" => registration.id, "row_id" => row.fetch("row_id"))
          ref = row["evidence_id"]
          item["evidence"] = ref.to_s.match?(/\Aevidence_[0-9A-HJKMNP-TV-Z]{26}\z/) ? [{ "record_id" => registration.id, "evidence_id" => ref, "role" => "laboratory_source" }] : []
          @subjects << id
          @rows << item
        end
        break if page.length < 10_000
        offset += page.length
      end
    end

    def subject_scopes
      subjects = @subjects.uniq.sort.map do |id|
        name = subject(id).name
        { "id" => id, "name" => references_visible?(name) ? text(name) : id }
      end
      return unavailable("scope_bound_reached") if subjects.length > 1000
      return unavailable("subject_scope_unknown") if subjects.empty? && @unknown
      result({ "subjects" => subjects }, dependencies: subjects, empty: subjects.empty?, limitations: @unknown ? ["subject_scope_unknown"] : [])
    end

    def matches?(row)
      row["test_date"] >= @args["from"] && row["test_date"] <= @args["to"] &&
        %w[panel analyte unit specimen laboratory method].all? { |key| !@args[key] || row[key] == @args[key] }
    end

    def evidence(rows)
      rows.flat_map { |row| row["evidence"] }.uniq.first(20)
    end

    def series(rows)
      groups = rows.group_by { |row| row.values_at(*GROUP) }.sort_by { |key, _| key.map(&:to_s) }
      limitations = @limitations.dup
      limitations << "series_bound_reached" if groups.length > 10
      data = groups.first(10).map do |key, items|
        ordered = items.sort_by { |row| row.values_at("test_date", "dataset_id", "row_id") }
        limitations << "series_point_bound_reached" if ordered.length > 1000
        GROUP.zip(key).to_h.merge("points" => ordered.first(1000), "aggregation" => "none", "returned" => [ordered.length, 1000].min,
          "bounded" => ordered.length > 1000)
      end
      result({ "series" => data }, dependencies: rows, empty: rows.empty?, limitations: limitations.uniq, evidence: evidence(rows))
    end
  end
end
