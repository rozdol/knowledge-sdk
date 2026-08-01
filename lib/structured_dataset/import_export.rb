# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rexml/document"
require "tmpdir"

module StructuredDataset
  class ImportExport
    FORMATS = %w[csv json xlsx].freeze

    def initialize(engine:)
      @engine = engine
    end

    def import(reference, path:, format: nil, provenance: {})
      source = Pathname.new(path).expand_path
      raise ImportError, "import file does not exist" unless source.file?

      selected = normalize_format(format || source.extname.delete_prefix("."))
      rows = case selected
             when "csv" then CSV.read(source.to_s, headers: true).map(&:to_h)
             when "json" then json_rows(JSON.parse(source.read))
             when "xlsx" then Xlsx.read(source)
             end
      raise ImportError, "import contains no rows" if rows.empty?

      @engine.import_rows(reference, rows, provenance.merge(source: provenance[:source] || provenance["source"] || source.to_s))
    rescue CSV::MalformedCSVError, JSON::ParserError => error
      raise ImportError, "invalid #{selected || 'import'}: #{error.message}"
    end

    def export(reference, format:, path: nil, force: false, where: nil, order: nil, limit: 10_000)
      selected = normalize_format(format)
      rows = @engine.query(reference, where: where, order: order, limit: limit)
      content = case selected
                when "csv" then csv(rows)
                when "json" then JSON.pretty_generate(rows) + "\n"
                end
      if selected == "xlsx"
        raise ExportError, "XLSX export requires --file" if path.to_s.strip.empty?

        destination = destination!(path, force: force)
        Xlsx.write(destination, rows)
        return { "format" => selected, "path" => destination.to_s, "row_count" => rows.length }
      end
      if path
        destination = destination!(path, force: force)
        destination.binwrite(content)
        { "format" => selected, "path" => destination.to_s, "row_count" => rows.length }
      else
        { "format" => selected, "content" => content, "row_count" => rows.length }
      end
    rescue Errno::EACCES, Errno::EISDIR, Errno::ENOENT => error
      raise ExportError, "export could not be written: #{error.message}"
    end

    private

    def normalize_format(value)
      format = value.to_s.downcase
      raise ArgumentError, "format must be csv, json, or xlsx" unless FORMATS.include?(format)

      format
    end

    def json_rows(value)
      rows = value.is_a?(Hash) ? value["rows"] || value[:rows] : value
      raise ImportError, "JSON import must be an array or an object with rows" unless rows.is_a?(Array)
      raise ImportError, "each imported row must be an object" unless rows.all? { |row| row.is_a?(Hash) }

      rows
    end

    def csv(rows)
      headers = rows.flat_map(&:keys).uniq
      CSV.generate do |output|
        output << headers
        rows.each do |row|
          output << headers.map do |header|
            value = row[header]
            value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value
          end
        end
      end
    end

    def destination!(path, force:)
      destination = Pathname.new(path).expand_path
      raise ExportError, "export target already exists; pass --force to replace it" if destination.exist? && !force

      FileUtils.mkdir_p(destination.dirname)
      destination
    end
  end

  module Xlsx
    module_function

    def write(path, rows)
      headers = rows.flat_map(&:keys).uniq
      Dir.mktmpdir("sde-xlsx-") do |root|
        files = {
          "[Content_Types].xml" => content_types,
          "_rels/.rels" => root_relationships,
          "xl/workbook.xml" => workbook,
          "xl/_rels/workbook.xml.rels" => workbook_relationships,
          "xl/worksheets/sheet1.xml" => worksheet(headers, rows)
        }
        files.each do |relative, content|
          destination = File.join(root, relative)
          FileUtils.mkdir_p(File.dirname(destination))
          File.binwrite(destination, content)
        end
        File.delete(path.to_s) if path.exist?
        _stdout, stderr, status = Open3.capture3("/usr/bin/zip", "-q", "-r", path.to_s, ".", chdir: root)
        raise ExportError, "XLSX packaging failed: #{stderr.strip}" unless status.success?
      end
      path
    end

    def read(path)
      shared = unzip(path, "xl/sharedStrings.xml", optional: true)
      strings = shared ? parse_shared_strings(shared) : []
      sheet = unzip(path, "xl/worksheets/sheet1.xml")
      values = parse_sheet(sheet, strings)
      headers = Array(values.shift).map(&:to_s)
      raise ImportError, "XLSX first row must contain unique headers" if headers.empty? || headers.any?(&:empty?) || headers.uniq.length != headers.length

      values.map do |row|
        headers.each_with_index.each_with_object({}) do |(header, index), result|
          result[header] = row[index]
        end
      end
    end

    def worksheet(headers, rows)
      data = [headers] + rows.map { |row| headers.map { |header| row[header] } }
      body = data.each_with_index.map do |row, row_index|
        cells = row.each_with_index.map do |value, column_index|
          cell(reference(column_index, row_index + 1), value)
        end.join
        %Q{<row r="#{row_index + 1}">#{cells}</row>}
      end.join
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>#{body}</sheetData>
        </worksheet>
      XML
    end

    def cell(reference, value)
      case value
      when Integer, Float
        %Q{<c r="#{reference}"><v>#{value}</v></c>}
      when TrueClass, FalseClass
        %Q{<c r="#{reference}" t="b"><v>#{value ? 1 : 0}</v></c>}
      when NilClass
        %Q{<c r="#{reference}"/>}
      else
        rendered = value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value.to_s
        %Q{<c r="#{reference}" t="inlineStr"><is><t xml:space="preserve">#{xml(rendered)}</t></is></c>}
      end
    end

    def reference(index, row)
      number = index + 1
      letters = +""
      while number.positive?
        number -= 1
        letters.prepend((65 + (number % 26)).chr)
        number /= 26
      end
      "#{letters}#{row}"
    end

    def unzip(path, member, optional: false)
      stdout, stderr, status = Open3.capture3("/usr/bin/unzip", "-p", path.to_s, member)
      return nil if optional && !status.success?
      raise ImportError, "XLSX member #{member} could not be read: #{stderr.strip}" unless status.success?

      stdout
    end

    def parse_shared_strings(xml_source)
      document = REXML::Document.new(without_default_namespace(xml_source))
      document.get_elements("//si").map do |item|
        item.get_elements(".//t").map { |text| text.text.to_s }.join
      end
    rescue REXML::ParseException => error
      raise ImportError, "invalid XLSX shared strings: #{error.message}"
    end

    def parse_sheet(xml_source, shared_strings)
      document = REXML::Document.new(without_default_namespace(xml_source))
      document.get_elements("//sheetData/row").map do |row|
        values = []
        row.get_elements("c").each do |cell|
          column = cell.attributes.fetch("r").to_s[/\A[A-Z]+/]
          index = letters_to_index(column)
          type = cell.attributes["t"]
          value = if type == "inlineStr"
                    cell.get_elements(".//t").map { |text| text.text.to_s }.join
                  else
                    node = cell.elements["v"]
                    decode_cell(node && node.text, type, shared_strings)
                  end
          values[index] = value
        end
        values
      end
    rescue REXML::ParseException, KeyError => error
      raise ImportError, "invalid XLSX worksheet: #{error.message}"
    end

    def decode_cell(value, type, shared_strings)
      return nil if value.nil?
      return shared_strings.fetch(value.to_i) if type == "s"
      return value == "1" if type == "b"
      return value if type == "str"

      value.include?(".") ? Float(value) : Integer(value)
    rescue ArgumentError
      value
    end

    def letters_to_index(value)
      value.to_s.each_byte.reduce(0) { |memo, byte| (memo * 26) + byte - 64 } - 1
    end

    def without_default_namespace(source)
      source.sub(/\sxmlns="[^"]+"/, "")
    end

    def xml(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end

    def content_types
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
        </Types>
      XML
    end

    def root_relationships
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
      XML
    end

    def workbook
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="Dataset" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
      XML
    end

    def workbook_relationships
      <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
        </Relationships>
      XML
    end
  end
end
