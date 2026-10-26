# frozen_string_literal: true

# Synthetic shared fixture; no attached Vault or external source is consulted.
module HealthReadFixture
  SUBJECT = "person_00000000000000000000000011"
  OTHER = "person_00000000000000000000000012"
  HIDDEN = "person_00000000000000000000000013"
  EVIDENCE = "evidence_00000000000000000000000001"
  ANALYTE = "Novel assay <img src=x onerror=window.injected=true>"

  def self.build(root, today: Date.new(2026, 10, 25))
    graph = KnowledgeGraph::Engine.new(vault_root: root)
    [[SUBJECT, "Synthetic patient", "private"], [OTHER, "Other synthetic patient", "private"], [HIDDEN, "Hidden synthetic patient", "restricted"]].each do |id, name, sensitivity|
      graph.execute(KnowledgeGraph::CreateEntity.new(entity_type: "person", attributes: {
        id: id, name: name, tier: "active", sensitivity: sensitivity, data_origin: "given_by_subject"
      }))
    end
    writer = StructuredDataset::Engine.new(vault_root: root)
    template = StructuredDataset.template_registry.fetch("blood_tests")
    columns = JSON.parse(JSON.generate(template.definition.columns.map(&:to_h))) + [{ "name" => "subject_id", "type" => "TEXT" }, { "name" => "sensitivity", "type" => "TEXT" }, { "name" => "method", "type" => "TEXT" }]
    writer.create("clinical_samples", schema: template.definition.to_h.merge(columns: columns),
      template_id: template.id, template_version: template.version, template_digest: template.digest)
    [[12, {}], [14, {}], [3.1, { unit: "mmol/L" }], [99, { method: "assay B" }],
      [55, { specimen: "plasma" }], [66, { laboratory: "Other laboratory" }],
      [777, { subject_id: OTHER }], [888, { subject_id: HIDDEN }], [999, { sensitivity: "restricted" }]].each_with_index do |(value, overrides), index|
      date = (today - index).iso8601
      writer.insert("clinical_samples", { test_date: date, observed_at: "#{date}T12:00:00Z", analyte: ANALYTE, marker: ANALYTE,
        panel: "Synthetic panel", value: value, unit: "mg/dL", reference_low: 2, reference_high: 10 + index,
        reference_text: "Original interval #{index}", flag: "H", specimen: "serum", laboratory: "Synthetic laboratory",
        subject_id: SUBJECT, sensitivity: "private" }.merge(overrides),
        { evidence_id: EVIDENCE, source_uri: "file:///private/synthetic-report.pdf", source_filename: "private-synthetic.pdf", source_span: "1:20" })
    end
    qualitative = columns.reject { |column| %w[subject_id sensitivity method].include?(column["name"]) }.map { |column| column["name"] == "value" ? column.merge("type" => "TEXT") : column }
    writer.create("qualitative_samples", schema: template.definition.to_h.merge(columns: qualitative), owner_id: SUBJECT,
      template_id: template.id, template_version: template.version, template_digest: template.digest)
    ["Negative", "<5", "123"].each do |value|
      date = today.iso8601
      writer.insert("qualitative_samples", { test_date: date, observed_at: "#{date}T00:00:00Z", analyte: ANALYTE, marker: ANALYTE,
        panel: "Qualitative panel", value: value, unit: "mg/dL", reference_text: "Report supplied text", flag: "reported", laboratory: "Synthetic laboratory" })
    end
    writer
  end

  def self.logical(root)
    reader = StructuredDataset::Reader.new(vault_root: root, database_path: File.join(root, KnowledgeSDK::DATASET_PATH))
    reader.with_consistent_read do
      %w[clinical_samples qualitative_samples].map { |id| [reader.describe(id), reader.query(id, order: "row_id:asc", limit: 100)] }
    end
  end
end
