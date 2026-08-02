# frozen_string_literal: true

require "date"
require "time"

module KnowledgeAnalysis
  # Pure deterministic statistics. The engine produces associations and causal
  # hints only; it never promotes temporal order or correlation to causality.
  class CorrelationEngine
    def trend(points, from: nil, to: nil)
      selected = normalize(points, from: from, to: to)
      return nil if selected.length < 2

      first = selected.first
      last = selected.last
      change = last.fetch("value") - first.fetch("value")
      elapsed_days = [(last.fetch("time") - first.fetch("time")) / 86_400.0, 1.0].max
      slope = regression_slope(selected)
      {
        "kind" => "trend", "observations" => selected.length,
        "from" => first.fetch("time").iso8601, "to" => last.fetch("time").iso8601,
        "first" => round(first.fetch("value")), "last" => round(last.fetch("value")),
        "absolute_change" => round(change),
        "percent_change" => first.fetch("value").zero? ? nil : round(change / first.fetch("value").abs * 100.0),
        "slope_per_day" => round(slope * 86_400.0),
        "direction" => direction(change),
        "confidence" => confidence(selected.length, [change.abs, elapsed_days].min / elapsed_days)
      }.reject { |_key, value| value.nil? }
    end

    def align(left, right, window_days: 3)
      first = normalize(left)
      second = normalize(right)
      maximum = Float(window_days) * 86_400.0
      used = {}
      first.each_with_object([]) do |point, pairs|
        candidates = second.each_with_index.reject { |_candidate, index| used[index] }.map do |candidate, index|
          [candidate, index, (candidate.fetch("time") - point.fetch("time")).abs]
        end.select { |_candidate, _index, distance| distance <= maximum }
        selected = candidates.min_by { |candidate, index, distance| [distance, candidate.fetch("time"), index] }
        next unless selected

        candidate, index, distance = selected
        used[index] = true
        pairs << {
          "left_time" => point.fetch("time").iso8601,
          "right_time" => candidate.fetch("time").iso8601,
          "left" => point.fetch("value"), "right" => candidate.fetch("value"),
          "distance_days" => round(distance / 86_400.0)
        }
      end
    end

    def correlate(left, right, window_days: 3)
      pairs = align(left, right, window_days: window_days)
      return nil if pairs.length < 3

      coefficient = pearson(
        pairs.map { |pair| pair.fetch("left") },
        pairs.map { |pair| pair.fetch("right") }
      )
      return nil if coefficient.nil?

      {
        "kind" => "correlation", "coefficient" => round(coefficient),
        "strength" => strength(coefficient), "direction" => direction(coefficient),
        "aligned_observations" => pairs.length, "window_days" => Float(window_days),
        "confidence" => confidence(pairs.length, coefficient.abs),
        "causal" => false,
        "causal_hint" => "Association only; timing and correlation do not establish causality."
      }
    end

    def compare_around(points, event_time:, before_days: 30, after_days: 30)
      event = parse_time(event_time)
      normalized = normalize(points)
      before = normalized.select do |point|
        point.fetch("time") < event && point.fetch("time") >= event - before_days.to_i * 86_400
      end
      after = normalized.select do |point|
        point.fetch("time") >= event && point.fetch("time") <= event + after_days.to_i * 86_400
      end
      return nil if before.empty? || after.empty?

      before_mean = mean(before.map { |point| point.fetch("value") })
      after_mean = mean(after.map { |point| point.fetch("value") })
      {
        "kind" => "window_comparison", "event_time" => event.iso8601,
        "before" => {
          "days" => before_days.to_i, "observations" => before.length, "mean" => round(before_mean)
        },
        "after" => {
          "days" => after_days.to_i, "observations" => after.length, "mean" => round(after_mean)
        },
        "absolute_change" => round(after_mean - before_mean),
        "direction" => direction(after_mean - before_mean),
        "confidence" => confidence(before.length + after.length, (after_mean - before_mean).abs),
        "causal" => false
      }
    end

    private

    def normalize(points, from: nil, to: nil)
      lower = from && parse_time(from)
      upper = to && parse_time(to)
      Array(points).each_with_object([]) do |point, result|
        data = point.each_with_object({}) { |(key, value), copy| copy[key.to_s] = value }
        time = parse_time(data.fetch("time"))
        value = Float(data.fetch("value"))
        next if lower && time < lower
        next if upper && time > upper

        result << { "time" => time, "value" => value }
      rescue KeyError, ArgumentError, TypeError
        next
      end.sort_by { |point| [point.fetch("time"), point.fetch("value")] }
    end

    def regression_slope(points)
      origin = points.first.fetch("time").to_f
      x = points.map { |point| point.fetch("time").to_f - origin }
      y = points.map { |point| point.fetch("value") }
      x_mean = mean(x)
      y_mean = mean(y)
      denominator = x.sum { |value| (value - x_mean)**2 }
      return 0.0 if denominator.zero?

      x.each_with_index.sum { |value, index| (value - x_mean) * (y[index] - y_mean) } / denominator
    end

    def pearson(first, second)
      first_mean = mean(first)
      second_mean = mean(second)
      numerator = first.each_with_index.sum do |value, index|
        (value - first_mean) * (second[index] - second_mean)
      end
      first_variance = first.sum { |value| (value - first_mean)**2 }
      second_variance = second.sum { |value| (value - second_mean)**2 }
      denominator = Math.sqrt(first_variance * second_variance)
      denominator.zero? ? nil : numerator / denominator
    end

    def mean(values)
      values.sum.to_f / values.length
    end

    def strength(value)
      magnitude = value.abs
      return "strong" if magnitude >= 0.7
      return "moderate" if magnitude >= 0.4
      return "weak" if magnitude >= 0.2

      "negligible"
    end

    def direction(value)
      return "increasing" if value.positive?
      return "decreasing" if value.negative?

      "stable"
    end

    def confidence(count, signal)
      sample = [count.to_f / 12.0, 1.0].min
      magnitude = [[signal.to_f.abs, 1.0].min, 0.0].max
      round([0.35 + sample * 0.4 + magnitude * 0.2, 0.95].min)
    end

    def round(value)
      value.to_f.round(6)
    end

    def parse_time(value)
      return value if value.is_a?(Time)
      return Time.utc(value.year, value.month, value.day) if value.is_a?(Date)

      Time.iso8601(value.to_s)
    rescue ArgumentError
      date = Date.iso8601(value.to_s)
      Time.utc(date.year, date.month, date.day)
    end
  end
end
