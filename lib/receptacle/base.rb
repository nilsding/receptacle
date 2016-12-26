# frozen_string_literal: true
require 'receptacle/registration'
require 'receptacle/method_cache'
require 'set'
module Receptacle
  class NotConfigured < StandardError; end
  module Base
    def self.included(base)
      base.extend(ClassMethods)
    end
    module ClassMethods
      def delegate_to_strategy(method_name)
        Registration.methods[self] ||= Set.new
        Registration.methods[self] << method_name
      end

      def method_missing(method_name, *arguments, &block)
        if Registration.methods[self]&.include?(method_name)
          build_method(method_name)
          build_cached_method(method_name)
          public_send("#{method_name}_cached", *arguments, &block)
        else
          super
        end
      end

      def respond_to_missing?(method_name, include_private = false)
        super
        Registration.methods[self]&.include?(method_name) || super
      end

      def build_method_call_cache(method_name)
        wrappers = Registration.wrappers[self]
        before_method_name = :"before_#{method_name}"
        after_method_name = :"after_#{method_name}"

        MethodCache.new(
          strategy: Registration.receptacles.fetch(self) { raise NotConfigured },
          before_wrappers: wrappers&.select { |w| w.method_defined?(before_method_name) },
          after_wrappers: wrappers&.select { |w| w.method_defined?(after_method_name) },
          method_name: method_name
        )
      end

      def build_cached_method(method_name)
        method_cache = build_method_call_cache(method_name)
        if method_cache.wrappers.nil? || method_cache.wrappers.empty?
          define_singleton_method("#{method_name}_cached") do |*args, &inner_block|
            method_cache.strategy.new.public_send(method_name, *args, &inner_block)
          end
        else
          define_singleton_method("#{method_name}_cached") do |*args, &inner_block|
            run_wrappers(method_cache, *args) do |*call_args|
              method_cache.strategy.new.public_send(method_name, *call_args, &inner_block)
            end
          end
        end
      end

      def run_wrappers(method_cache, input_args)
        wrappers = method_cache.wrappers.map(&:new)
        args = if method_cache.skip_before_wrappers?
                 input_args
               else
                 run_before_wrappers(wrappers, method_cache.before_method_name, input_args)
               end
        ret = yield(args)
        return ret if method_cache.skip_after_wrappers?
        run_after_wrappers(wrappers, method_cache.after_method_name, args, ret)
      end

      #-------------------------------------------------------------------------#

      def build_method(method_name)
        define_singleton_method(method_name) do |*args, &inner_block|
          strategy = Registration.receptacles.fetch(self) do
            raise NotConfigured
          end

          with_wrappers(self, method_name, *args) do |*call_args|
            strategy.new.public_send(method_name, *call_args, &inner_block)
          end
        end
      end

      def with_wrappers(base, method_name, *input_args)
        wrappers = Registration.wrappers[base]
        return yield(*input_args) if wrappers.nil? || wrappers.empty?

        wrappers = wrappers.map(&:new)
        args = run_before_wrappers(wrappers, "before_#{method_name}", *input_args)
        ret = yield(args)
        run_after_wrappers(wrappers, "after_#{method_name}", args, ret)
      end

      def run_before_wrappers(wrappers, method_name, args)
        before_wrappers = wrappers
                          .select { |w| w.respond_to?(method_name) }
        return args if before_wrappers.empty?

        before_wrappers.reduce(args) do |memo, wrapper|
          wrapper.public_send(method_name, memo)
        end
      end

      def run_after_wrappers(wrappers, method_name, args, return_value)
        after_wrappers = wrappers
                         .select { |w| w.respond_to?(method_name) }
        return return_value if after_wrappers.empty?

        after_wrappers.reverse.reduce(return_value) do |memo, wrapper|
          wrapper.public_send(method_name, args, memo)
        end
      end
    end
  end
end
