# frozen_string_literal: true

module KnowledgeFinance
  module Accounting
    class Security
      def opening_cash(quantity, price, sign)
        -quantity * price * sign
      end

      def closing_cash(quantity, price, sign, _profit)
        quantity * price * sign
      end

      def market_value(notional, _unrealized)
        notional
      end

      def basis_name
        "FIFO acquisition price; income and costs recorded separately"
      end
    end

    class Future < Security
      def opening_cash(_quantity, _price, _sign)
        BigDecimal("0")
      end

      def closing_cash(_quantity, _price, _sign, profit)
        raise InvalidFinance, "futures cash settlement requires known basis" unless profit
        profit
      end

      def market_value(_notional, unrealized)
        unrealized
      end

      def basis_name
        "FIFO daily settlement basis; variation margin is counted once"
      end
    end

    class Option < Security
      def basis_name
        "FIFO premium basis with explicit contract multiplier and settlement type"
      end
    end

    class Bond < Security
      def basis_name
        "FIFO dirty price per 100 nominal; coupons separate; tax interest allocation unavailable"
      end
    end

    module_function

    def registry
      @registry ||= { "future" => Future.new, "option" => Option.new, "futures_option" => Option.new, "bond" => Bond.new }
    end

    def register(asset_class, adapter)
      raise InvalidFinance, "accounting adapter already registered" if registry.key?(asset_class.to_s)
      %i[opening_cash closing_cash market_value basis_name].each do |method|
        raise InvalidFinance, "incomplete accounting adapter" unless adapter.respond_to?(method)
      end
      registry[asset_class.to_s] = adapter
    end

    def for(asset)
      registry.fetch(asset.data["asset_class"]) { Security.new }
    end
  end
end
