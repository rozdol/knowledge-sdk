# frozen_string_literal: true

require "securerandom"

module KnowledgeGraph
  class IdGenerator
    ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    def initialize(clock: nil, random_bytes: nil)
      @clock = clock || -> { Time.now }
      @random_bytes = random_bytes || ->(length) { SecureRandom.random_bytes(length) }
    end

    def generate(prefix)
      raise ArgumentError, "invalid ID prefix" unless prefix.to_s.match?(/\A[a-z][a-z0-9-]*\z/)

      "#{prefix}_#{time_part}#{random_part}"
    end

    private

    def time_part
      value = (@clock.call.to_f * 1000).to_i
      10.times.map do
        character = ALPHABET[value % 32]
        value /= 32
        character
      end.reverse.join
    end

    def random_part
      @random_bytes.call(10).unpack1("B*").scan(/.{5}/).map do |bits|
        ALPHABET[bits.to_i(2)]
      end.join
    end
  end
end
