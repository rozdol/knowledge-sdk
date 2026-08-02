# frozen_string_literal: true

require_relative "structured_dataset/errors"
require_relative "structured_dataset/schema"
require_relative "structured_dataset/templates"
require_relative "structured_dataset/database"
require_relative "structured_dataset/query"
require_relative "structured_dataset/import_export"
require_relative "structured_dataset/engine"
require_relative "structured_dataset/medication_schedules"
require_relative "structured_dataset/integrations"
require_relative "structured_dataset/evolution"
require_relative "structured_dataset/routing"
require_relative "structured_dataset/cli"

module StructuredDataset
  VERSION = "15.0.0".freeze
end
