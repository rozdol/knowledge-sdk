# frozen_string_literal: true

module StructuredDataset
  class Error < StandardError; end
  class DependencyError < Error; end
  class InvalidSchema < Error; end
  class DatasetNotFound < Error; end
  class DatasetConflict < Error; end
  class InvalidRow < Error; end
  class RowNotFound < Error; end
  class InvalidQuery < Error; end
  class MigrationError < Error; end
  class ImportError < Error; end
  class ExportError < Error; end
  class ConsistencyError < Error; end
end
