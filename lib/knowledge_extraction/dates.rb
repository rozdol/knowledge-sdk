# frozen_string_literal: true

require "date"

module KnowledgeExtraction
  class DateNormalizer
    WEEKDAYS = {
      "sunday" => 0, "monday" => 1, "tuesday" => 2, "wednesday" => 3,
      "thursday" => 4, "friday" => 5, "saturday" => 6
    }.freeze
    NUMBER_WORDS = {
      "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5, "six" => 6,
      "seven" => 7, "eight" => 8, "nine" => 9, "ten" => 10, "eleven" => 11, "twelve" => 12
    }.freeze

    def normalize(expression, captured_at: nil)
      original = expression.to_s.strip
      return unresolved(original) if original.empty?

      exact = parse_exact(original)
      return range(original, exact[0], exact[1], 1.0) if exact.is_a?(Array)
      return resolved(original, exact.iso8601, 1.0) if exact

      reference = Support.parse_time(captured_at, field: "captured_at")
      return unresolved(original) unless reference

      date = reference.to_date
      normalized = original.downcase
      case normalized
      when "today", "сегодня", "σήμερα" then resolved(original, date.iso8601, 0.98)
      when "yesterday", "вчера", "χθες" then resolved(original, (date - 1).iso8601, 0.98)
      when "tomorrow", "завтра", "αύριο" then resolved(original, (date + 1).iso8601, 0.98)
      when "next week"
        monday = date + ((8 - date.wday) % 7)
        monday += 7 if monday == date
        range(original, monday, monday + 6, 0.78)
      when "last week"
        monday = date - ((date.wday + 6) % 7) - 7
        range(original, monday, monday + 6, 0.78)
      when /\A(\d+)\s+days?\s+ago\z/
        resolved(original, (date - Regexp.last_match(1).to_i).iso8601, 0.92)
      when /\A(\d+)\s+months?\s+ago\z/
        resolved(original, (date << Regexp.last_match(1).to_i).iso8601, 0.82)
      when /\A(#{NUMBER_WORDS.keys.join('|')})\s+days?\s+ago\z/
        resolved(original, (date - NUMBER_WORDS.fetch(Regexp.last_match(1))).iso8601, 0.90)
      when /\A(#{NUMBER_WORDS.keys.join('|')})\s+months?\s+ago\z/
        resolved(original, (date << NUMBER_WORDS.fetch(Regexp.last_match(1))).iso8601, 0.80)
      when /\A(next|last)\s+(#{WEEKDAYS.keys.join('|')})\z/
        relative_weekday(original, date, Regexp.last_match(1), WEEKDAYS.fetch(Regexp.last_match(2)))
      when /\Aevery\s+(#{WEEKDAYS.keys.join('|')})\z/
        recurrence(original, "weekly", Regexp.last_match(1), 0.95)
      when "weekly" then recurrence(original, "weekly", nil, 0.90)
      when "monthly" then recurrence(original, "monthly", nil, 0.90)
      else unresolved(original)
      end
    end

    private

    def parse_exact(expression)
      if (match = expression.match(/\A(\d{4}-\d{2}-\d{2})\s+(?:to|through)\s+(\d{4}-\d{2}-\d{2})\z/i))
        from = Date.iso8601(match[1])
        to = Date.iso8601(match[2])
        raise ArgumentError if to < from
        return [from, to]
      end
      Date.iso8601(expression)
    rescue ArgumentError
      nil
    end

    def recurrence(original, frequency, weekday, confidence)
      ScalarValue.new(
        value: original, value_type: "recurrence", original_expression: original,
        normalized_value: Support.compact_hash(frequency: frequency, weekday: weekday),
        normalization_confidence: confidence
      )
    end

    def relative_weekday(original, date, direction, target_wday)
      if direction == "next"
        delta = (target_wday - date.wday) % 7
        delta = 7 if delta.zero?
        resolved(original, (date + delta).iso8601, 0.90)
      else
        delta = (date.wday - target_wday) % 7
        delta = 7 if delta.zero?
        resolved(original, (date - delta).iso8601, 0.90)
      end
    end

    def resolved(original, value, confidence)
      ScalarValue.new(
        value: original, value_type: "date", original_expression: original,
        normalized_value: value, normalization_confidence: confidence
      )
    end

    def range(original, from, to, confidence)
      ScalarValue.new(
        value: original, value_type: "date-range", original_expression: original,
        normalized_value: { from: from.iso8601, to: to.iso8601 },
        normalization_confidence: confidence, uncertain: true
      )
    end

    def unresolved(original)
      ScalarValue.new(
        value: original, value_type: "date", original_expression: original,
        normalized_value: nil, normalization_confidence: 0.0, uncertain: true
      )
    end
  end
end
