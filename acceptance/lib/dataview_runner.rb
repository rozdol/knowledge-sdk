# frozen_string_literal: true

require "strscan"
require_relative "acceptance_support"

module PKGAcceptance
  class DataviewExpression
    Token = Struct.new(:type, :value)

    def initialize(source, today: FIXED_NOW.to_date)
      @tokens = tokenize(source)
      @position = 0
      @today = today
      @ast = parse_or
      raise "unexpected token #{peek.value.inspect}" if peek
    end

    def call(note)
      truthy?(evaluate(@ast, note))
    end

    private

    def tokenize(source)
      scanner = StringScanner.new(source)
      tokens = []
      until scanner.eos?
        if scanner.scan(/\s+/)
          next
        elsif (value = scanner.scan(/\[\[[^\]]+\]\]/))
          tokens << Token.new(:literal, value)
        elsif (value = scanner.scan(/"(?:\\.|[^"])*"/))
          tokens << Token.new(:literal, value[1..-2].gsub('\\"', '"'))
        elsif (value = scanner.scan(/>=|<=|!=|=/))
          tokens << Token.new(:operator, value)
        elsif (value = scanner.scan(/[><!(),]/))
          tokens << Token.new(value == "(" || value == ")" || value == "," ? value.to_sym : :operator, value)
        elsif (value = scanner.scan(/[A-Za-z_][A-Za-z0-9_.-]*/))
          keyword = %w[AND OR].include?(value.upcase) ? value.upcase.downcase.to_sym : :identifier
          tokens << Token.new(keyword, value)
        else
          raise "unsupported Dataview expression near #{scanner.rest[0, 40].inspect}"
        end
      end
      tokens
    end

    def parse_or
      node = parse_and
      node = [:or, node, parse_and] while accept(:or)
      node
    end

    def parse_and
      node = parse_comparison
      node = [:and, node, parse_comparison] while accept(:and)
      node
    end

    def parse_comparison
      left = parse_unary
      return left unless peek && peek.type == :operator && %w[= != > < >= <=].include?(peek.value)

      operator = advance.value
      [:compare, operator, left, parse_unary]
    end

    def parse_unary
      return [:not, parse_unary] if peek && peek.type == :operator && peek.value == "!" && advance
      return parse_parenthesized if accept(:"(")

      parse_primary
    end

    def parse_parenthesized
      node = parse_or
      expect(:")")
      node
    end

    def parse_primary
      token = advance
      raise "unexpected end of Dataview expression" unless token

      return [:literal, token.value] if token.type == :literal
      raise "expected value, got #{token.value.inspect}" unless token.type == :identifier

      if accept(:"(")
        arguments = []
        unless accept(:")")
          arguments << parse_or
          arguments << parse_or while accept(:",")
          expect(:")")
        end
        [:call, token.value, arguments]
      else
        [:field, token.value]
      end
    end

    def evaluate(node, note)
      case node[0]
      when :literal
        node[1]
      when :field
        return @today if node[1] == "today"
        return note.relative.sub(/\.md\z/, "") if node[1] == "file.path"

        note.data[node[1]]
      when :not
        !truthy?(evaluate(node[1], note))
      when :and
        truthy?(evaluate(node[1], note)) && truthy?(evaluate(node[2], note))
      when :or
        truthy?(evaluate(node[1], note)) || truthy?(evaluate(node[2], note))
      when :compare
        compare(node[1], evaluate(node[2], note), evaluate(node[3], note))
      when :call
        call_function(node[1], node[2].map { |argument| evaluate(argument, note) })
      else
        raise "unknown Dataview AST node #{node.inspect}"
      end
    end

    def call_function(name, arguments)
      case name
      when "date"
        value = arguments.first
        return value if value.is_a?(Date)
        return value.to_date if value.respond_to?(:to_date)

        Date.parse(value.to_s)
      else
        raise "unsupported Dataview function #{name}"
      end
    rescue ArgumentError
      nil
    end

    def compare(operator, left, right)
      if PKGAcceptance.link_target(left) || PKGAcceptance.link_target(right)
        left = PKGAcceptance.link_target(left) || left
        right = PKGAcceptance.link_target(right) || right
      elsif left.respond_to?(:to_date) || right.respond_to?(:to_date)
        left = comparable_date(left)
        right = comparable_date(right)
      end
      return false if left.nil? || right.nil?

      case operator
      when "=" then left == right
      when "!=" then left != right
      when ">" then left > right
      when "<" then left < right
      when ">=" then left >= right
      when "<=" then left <= right
      end
    end

    def comparable_date(value)
      return value.to_date if value.respond_to?(:to_date)

      parsed = PKGAcceptance.scalar_time(value)
      parsed && (parsed.respond_to?(:to_date) ? parsed.to_date : parsed)
    end

    def truthy?(value)
      !value.nil? && value != false
    end

    def peek
      @tokens[@position]
    end

    def advance
      token = peek
      @position += 1 if token
      token
    end

    def accept(type)
      return false unless peek && peek.type == type

      advance
    end

    def expect(type)
      token = advance
      raise "expected #{type}, got #{token && token.value.inspect}" unless token && token.type == type

      token
    end
  end

  class DataviewRunner
    attr_reader :vault, :source_root, :results

    def initialize(vault, source_root)
      @vault = vault
      @source_root = Pathname.new(source_root)
      @results = []
    end

    def run!
      extract_blocks.each do |block|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          rows = block["language"] == "dataviewjs" ? execute_javascript(block["query"]) : execute_dql(block["query"])
          error = nil
        rescue StandardError => exception
          rows = 0
          error = "#{exception.class}: #{exception.message}"
        end
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        results << block.merge("rows" => rows, "seconds" => elapsed, "error" => error, "warnings" => [])
      end
      self
    end

    def pass?
      results.all? { |result| result["error"].nil? && result["warnings"].empty? }
    end

    private

    def extract_blocks
      blocks = []
      Dir.glob(source_root.join("**/*.md").to_s).sort.each do |filename|
        relative = Pathname.new(filename).relative_path_from(source_root).to_s
        content = File.read(filename)
        content.to_enum(:scan, /^```(dataview(?:js)?)\s*\n(.*?)^```\s*$/m).each do
          match = Regexp.last_match
          line = content[0...match.begin(0)].count("\n") + 1
          blocks << { "source" => relative, "line" => line, "language" => match[1], "query" => match[2].strip }
        end
      end
      blocks
    end

    def execute_dql(query)
      folder = query[/^FROM\s+"([^"]+)"/i, 1]
      raise "missing FROM folder" unless folder

      candidates = vault.notes.select { |note| note.relative.start_with?(folder + "/") }
      where = extract_where(query)
      candidates = candidates.select(&DataviewExpression.new(where).method(:call)) unless where.empty?
      group = query[/^GROUP BY\s+([A-Za-z_][A-Za-z0-9_.-]*)/i, 1]
      rows = group ? candidates.group_by { |note| note.data[group] }.length : candidates.length
      limit = query[/^LIMIT\s+(\d+)/i, 1]
      rows = [rows, limit.to_i].min if limit
      rows
    end

    def extract_where(query)
      lines = query.lines.map(&:strip)
      start = lines.index { |line| line.start_with?("WHERE ") }
      return "" unless start

      parts = [lines[start].sub(/\AWHERE\s+/, "")]
      index = start + 1
      while index < lines.length && lines[index] !~ /\A(?:SORT|GROUP BY|LIMIT)\b/
        parts << lines[index]
        index += 1
      end
      parts.join(" ")
    end

    def execute_javascript(query)
      required_fragments = ["dv.pages('\"People\"')", "dv.pages('\"Interactions\"')", "cadence_target_days", "dv.table"]
      unless required_fragments.all? { |fragment| query.include?(fragment) }
        raise "unsupported DataviewJS block; add an explicit compatibility evaluator"
      end

      substantive = vault.notes_of("interaction").select do |note|
        note.active? && note.data["contact_weight"] == "substantive"
      end
      last_contact = {}
      substantive.each do |interaction|
        started = PKGAcceptance.scalar_time(interaction.data["starts_at"])
        Array(interaction.data["participants"]).each do |participant|
          target = PKGAcceptance.link_target(participant)
          next unless target && started

          last_contact[target] = started if !last_contact[target] || started > last_contact[target]
        end
      end
      vault.notes_of("person").count do |person|
        next false unless person.active?
        next false if person.data["is_self"] == true || person.data["life_status"] == "deceased"
        next false if person.data["contact_policy"] == "do_not_contact" || person.data["tier"] == "archive"

        path = person.relative.sub(/\.md\z/, "")
        last = last_contact[path]
        cadence = (person.data["cadence_target_days"] || 180).to_i
        last.nil? || last.to_date + cadence < FIXED_NOW.to_date
      end
    end
  end
end
