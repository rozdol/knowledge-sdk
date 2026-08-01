# frozen_string_literal: true

module StructuredDataset
  class Query
    AUDIT_COLUMNS = Definition::RESERVED_COLUMNS.freeze
    OPERATORS = %w[= != <> < <= > >= LIKE].freeze
    CLAUSE = /\A([a-z][a-z0-9_]*)\s*(=|!=|<>|<=|>=|<|>|LIKE)\s*(NULL|TRUE|FALSE|-?\d+(?:\.\d+)?|'(?:[^']|'')*'|"(?:[^"]|"")*")\z/i.freeze
    NULL_CLAUSE = /\A([a-z][a-z0-9_]*)\s+IS\s+(NOT\s+)?NULL\z/i.freeze

    attr_reader :sql, :binds

    def initialize(database:, definition:, table_name:, where: nil, order: nil,
                   limit: 100, offset: 0, columns: nil, row_id: nil)
      @database = database
      @definition = definition
      @table_name = Names.identifier!(table_name, "table name")
      @allowed = (definition.columns.map(&:name) + AUDIT_COLUMNS).uniq.freeze
      @binds = []
      selected = selected_columns(columns)
      clauses = []
      if row_id
        clauses << "row_id = ?"
        @binds << row_id.to_s
      end
      clauses.concat(parse_where(where)) unless where.to_s.strip.empty?
      @sql = "SELECT #{selected} FROM #{@database.quote_identifier(@table_name)}"
      @sql += " WHERE #{clauses.join(' AND ')}" unless clauses.empty?
      @sql += order_sql(order)
      @sql += " LIMIT ? OFFSET ?"
      @binds.concat([validated_limit(limit), validated_offset(offset)])
      freeze
    end

    private

    def selected_columns(columns)
      values = if columns.nil? || columns.to_s.strip.empty?
                 @allowed
               else
                 columns.is_a?(Array) ? columns : columns.to_s.split(",")
               end
      values = values.map { |value| validate_column(value.to_s.strip) }.uniq
      raise InvalidQuery, "at least one query column is required" if values.empty?

      values.map { |value| @database.quote_identifier(value) }.join(", ")
    end

    def parse_where(source)
      split_clauses(source).map do |clause|
        if (match = NULL_CLAUSE.match(clause))
          column = validate_column(match[1])
          "#{@database.quote_identifier(column)} IS #{match[2] ? 'NOT ' : ''}NULL"
        elsif (match = CLAUSE.match(clause))
          column = validate_column(match[1])
          operator = match[2].upcase
          raise InvalidQuery, "unsupported query operator" unless OPERATORS.include?(operator)
          literal = match[3]
          if literal.casecmp?("NULL")
            raise InvalidQuery, "use IS NULL or IS NOT NULL"
          end
          @binds << coerce_literal(column, literal)
          "#{@database.quote_identifier(column)} #{operator} ?"
        else
          raise InvalidQuery, "unsupported where clause #{clause.inspect}"
        end
      end
    end

    def split_clauses(source)
      clauses = []
      buffer = +""
      quote = nil
      index = 0
      text = source.to_s.strip
      while index < text.length
        character = text[index]
        if quote
          if character == quote && text[index + 1] == quote
            buffer << character << character
            index += 2
            next
          elsif character == quote
            quote = nil
          end
          buffer << character
          index += 1
          next
        end
        if character == "'" || character == '"'
          quote = character
          buffer << character
          index += 1
          next
        end
        remainder = text[index..-1]
        if remainder.match?(/\A\s+AND\s+/i)
          separator = remainder.match(/\A\s+AND\s+/i)[0]
          clauses << buffer.strip
          buffer = +""
          index += separator.length
          next
        end
        buffer << character
        index += 1
      end
      raise InvalidQuery, "unterminated quoted value" if quote

      clauses << buffer.strip
      raise InvalidQuery, "where clause cannot be empty" if clauses.any?(&:empty?)

      clauses
    end

    def coerce_literal(column_name, literal)
      value = if literal.start_with?("'", '"')
                literal[1...-1].gsub(literal[0] * 2, literal[0])
              elsif literal.casecmp?("TRUE")
                true
              elsif literal.casecmp?("FALSE")
                false
              elsif literal.include?(".")
                Float(literal)
              else
                Integer(literal)
              end
      column = @definition.columns.find { |item| item.name == column_name }
      column ? column.coerce(value) : value
    rescue InvalidRow => error
      raise InvalidQuery, error.message
    end

    def order_sql(order)
      return " ORDER BY created_at ASC, row_id ASC" if order.nil? || order.to_s.strip.empty?

      parts = order.to_s.split(",").map do |item|
        column, direction = item.strip.split(/\s+|:/, 2)
        column = validate_column(column)
        direction = (direction || "asc").downcase
        raise InvalidQuery, "order direction must be asc or desc" unless %w[asc desc].include?(direction)

        "#{@database.quote_identifier(column)} #{direction.upcase}"
      end
      " ORDER BY #{parts.join(', ')}"
    end

    def validate_column(value)
      raise InvalidQuery, "unknown query column #{value.inspect}" unless @allowed.include?(value)

      value
    end

    def validated_limit(value)
      number = Integer(value)
      raise InvalidQuery, "limit must be between 1 and 10000" unless number.between?(1, 10_000)

      number
    rescue ArgumentError, TypeError
      raise InvalidQuery, "limit must be between 1 and 10000"
    end

    def validated_offset(value)
      number = Integer(value)
      raise InvalidQuery, "offset must be non-negative" if number.negative?

      number
    rescue ArgumentError, TypeError
      raise InvalidQuery, "offset must be non-negative"
    end
  end
end
