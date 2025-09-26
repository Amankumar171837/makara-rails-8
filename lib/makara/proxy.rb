require 'delegate'
require 'active_support/core_ext/class/attribute'
require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/string/inflections'

# The entry point of Makara. It contains a primary and replica pool which are chosen based on the invocation
# being proxied. Makara::Proxy implementations should declare which methods they are hijacking via the
# `hijack_method` class method.
# While debugging this class use prepend debug calls with Kernel. (Kernel.byebug for example)
# to avoid getting into method_missing stuff.

module Makara
  class Proxy < ::SimpleDelegator
    METHOD_MISSING_SKIP = [:byebug, :puts]

    class_attribute :hijack_methods, :control_methods
    self.hijack_methods = []
    self.control_methods = []

    class << self
      def hijack_method(*method_names)
        self.hijack_methods = hijack_methods || []
        self.hijack_methods |= method_names

        method_names.each do |method_name|
          define_method(method_name) do |*args, &block|
            appropriate_connection(method_name, args) do |con|
              con.send(method_name, *args, &block)
            end
          end

          ruby2_keywords method_name if Module.private_method_defined?(:ruby2_keywords)
        end
      end

      def send_to_all(*method_names)
        method_names.each do |method_name|
          define_method(method_name) do |*args|
            send_to_all(method_name, *args)
          end

          ruby2_keywords method_name if Module.private_method_defined?(:ruby2_keywords)
        end
      end

      def control_method(*method_names)
        self.control_methods = control_methods || []
        self.control_methods |= method_names

        method_names.each do |method_name|
          define_method(method_name) do |*args, &block|
            control&.send(method_name, *args, &block)
          end

          ruby2_keywords method_name if Module.private_method_defined?(:ruby2_keywords)
        end
      end
    end

    attr_reader :error_handler, :sticky, :config_parser, :control

    def initialize(config)
      puts "=config======#{config.inspect}===="
      @config         = config.symbolize_keys
      @config_parser  = Makara::ConfigParser.new(@config)
      @id             = @config_parser.id
      @ttl            = @config_parser.makara_config[:primary_ttl]
      @sticky         = @config_parser.makara_config[:sticky]
      @hijacked       = false
      @error_handler ||= ::Makara::ErrorHandler.new
      @skip_sticking = false
      instantiate_connections
      # super(config)
      delegate_to = @primary_pool&.connections&.first&._makara_connection || Object.new
      super(delegate_to)
    end

    # def initialize(config)
    #   puts "=config======#{config.inspect}===="
    #
    #   begin
    #     puts "=======setting up instance variables===="
    #     @config         = config.symbolize_keys
    #     @config_parser  = Makara::ConfigParser.new(@config)
    #     @id             = @config_parser.id
    #     @ttl            = @config_parser.makara_config[:primary_ttl]
    #     @sticky         = @config_parser.makara_config[:sticky]
    #     @hijacked       = false
    #     @error_handler ||= ::Makara::ErrorHandler.new
    #     @skip_sticking = false
    #     @in_any_connection = false
    #     puts "=======instance variables set===="
    #
    #     puts "=======about to call instantiate_connections===="
    #     instantiate_connections
    #     puts "=======instantiate_connections returned===="
    #
    #     puts "=======@primary_pool after instantiate: #{@primary_pool.inspect}===="
    #     puts "=======@replica_pool after instantiate: #{@replica_pool.inspect}===="
    #
    #     # Don't call super with config, either call it with a proper delegate object or not at all
    #     # For now, let's try without calling super to see if that fixes the issue
    #     puts "=======skipping super call for debugging===="
    #       # super(delegate_to)
    #
    #   rescue => e
    #     puts "=======ERROR in initialize: #{e.class}: #{e.message}===="
    #     puts "=======Backtrace: #{e.backtrace.first(10).join("\n")}===="
    #     raise e
    #   end
    # end

    def without_sticking
      @skip_sticking = true
      yield
    ensure
      @skip_sticking = false
    end

    def hijacked?
      @hijacked
    end

    # If persist is true, we stick the proxy to primary for subsequent requests
    # up to primary_ttl duration. Otherwise we just stick it for the current request
    def stick_to_primary!(persist = true)
      stickiness_duration = persist ? @ttl : 0
      Makara::Context.stick(@id, stickiness_duration)
    end

    def stick_to_master!(persist = true)
      warn "#{self.class}.stick_to_master! is deprecated. Switch to #stick_to_primary!"
      stick_to_primary!(persist)
    end

    def strategy_for(role)
      strategy_class_for(strategy_name_for(role)).new(self)
    end

    def strategy_name_for(role)
      @config_parser.makara_config["#{role}_strategy".to_sym]
    end

    def shard_aware_for(role)
      @config_parser.makara_config["#{role}_shard_aware".to_sym]
    end

    def default_shard_for(role)
      @config_parser.makara_config["#{role}_default_shard".to_sym]
    end

    def strategy_class_for(strategy_name)
      case strategy_name
      when 'round_robin', 'roundrobin', nil, ''
        ::Makara::Strategies::RoundRobin
      when 'failover'
        ::Makara::Strategies::PriorityFailover
      else
        strategy_name.constantize
      end
    end

    def method_missing(m, *args, &block)
      return super if METHOD_MISSING_SKIP.include?(m)

      any_connection do |con|
        if con.respond_to?(m, true)
          con.send(m, *args, &block)
        else
          super
        end
      end
    end

    ruby2_keywords :method_missing if Module.private_method_defined?(:ruby2_keywords)

    def respond_to_missing?(m, _include_private = false)
      any_connection do |con|
        con._makara_connection.respond_to?(m, true)
      end
    end

    def graceful_connection_for(config)
      fake_wrapper = Makara::ConnectionWrapper.new(self, nil, config)

      @error_handler.handle(fake_wrapper) do
        connection_for(config)
      end
    rescue Makara::Errors::BlacklistConnection => e
      fake_wrapper.initial_error = e.original_error
      fake_wrapper
    end

    def disconnect!
      send_to_all(:disconnect!)
    rescue ::Makara::Errors::AllConnectionsBlacklisted, ::Makara::Errors::NoConnectionsAvailable
      # all connections are already down, nothing to do here
    end

    protected

    def send_to_all(method_name, *args)
      # replica pool must run first to allow for replica --> primary failover without running operations on the primary twice.
      handling_an_all_execution(method_name) do
        @replica_pool.send_to_all(method_name, *args)
        @primary_pool.send_to_all(method_name, *args)
      end
    end

    ruby2_keywords :send_to_all if Module.private_method_defined?(:ruby2_keywords)

    # def any_connection(&block)
    #   puts "===primar==#{@primary_pool.inspect}===replica==#{@replica_pool.inspect}="
    #   if @primary_pool.disabled
    #     puts "=====111==inside if===="
    #     @replica_pool.provide(&block)
    #   else
    #     puts "=====222==inside else="
    #     @primary_pool.provide(&block)
    #   end
    # rescue ::Makara::Errors::AllConnectionsBlacklisted, ::Makara::Errors::NoConnectionsAvailable
    #   begin
    #     puts "=====inside===begin==="
    #     @primary_pool.disabled = true
    #     @replica_pool.provide(&block)
    #   ensure
    #     puts "======after==ensure"
    #     @primary_pool.disabled = false
    #   end
    # end


    def any_connection(&block)
      # Add a guard to prevent infinite recursion
      return if @in_any_connection

      @in_any_connection = true

      begin
        puts "===primar==#{@primary_pool.inspect}===replica==#{@replica_pool.inspect}="
        if @primary_pool.disabled
          puts "=====111==inside if===="
          @replica_pool.provide(&block)
        else
          puts "=====222==inside else="
          @primary_pool.provide(&block)
        end
      rescue ::Makara::Errors::AllConnectionsBlacklisted, ::Makara::Errors::NoConnectionsAvailable
        begin
          puts "=====inside===begin==="
          @primary_pool.disabled = true
          @replica_pool.provide(&block)
        ensure
          puts "======after==ensure"
          @primary_pool.disabled = false
        end
      ensure
        @in_any_connection = false
      end
    end

    # based on the method_name and args, provide the appropriate connection
    # mark this proxy as hijacked so the underlying connection does not attempt to check
    # with back with this proxy.
    def appropriate_connection(method_name, args)
      appropriate_pool(method_name, args) do |pool|
        pool.provide do |connection|
          hijacked do
            yield connection
          end
        end
      end
    end

    # primary or replica
    def appropriate_pool(method_name, args)
      # for testing purposes
      pool = _appropriate_pool(method_name, args)
      yield pool
    rescue ::Makara::Errors::AllConnectionsBlacklisted, ::Makara::Errors::NoConnectionsAvailable => e
      if pool == @primary_pool
        @primary_pool.connections.each(&:_makara_whitelist!)
        @replica_pool.connections.each(&:_makara_whitelist!)
        Kernel.raise e
      else
        @primary_pool.blacklist_errors << e
        retry
      end
    end

    def _appropriate_pool(method_name, args)
      # the args provided absolutely need primary
      if needs_primary?(method_name, args)
        stick_to_primary(method_name, args)
        @primary_pool

      elsif stuck_to_primary?

        # we're on primary because we already stuck this proxy in this
        # request or because we got stuck in previous requests and the
        # stickiness is still valid
        @primary_pool

      # all replicas are down (or empty)
      elsif @replica_pool.completely_blacklisted?
        stick_to_primary(method_name, args)
        @primary_pool

      elsif in_transaction?
        @primary_pool

      # yay! use a replica
      else
        @replica_pool
      end
    end

    # Do these args require a primary connection
    def needs_primary?(method_name, args)
      if respond_to?(:needs_master?)
        warn "#{self.class}#needs_master? is deprecated. Switch to #needs_primary?"
        needs_master?(method_name, args)
      else
        true
      end
    end

    def in_transaction?
      if respond_to?(:open_transactions)
        open_transactions > 0
      else
        false
      end
    end

    def hijacked
      @hijacked = true
      yield
    ensure
      @hijacked = false
    end

    def stuck_to_primary?
      sticky? && Makara::Context.stuck?(@id)
    end

    def stick_to_primary(method_name, args)
      # check to see if we're configured, bypassed, or some custom implementation has input
      return unless should_stick?(method_name, args)

      # do the sticking
      stick_to_primary!
    end

    def stick_to_master(method_names, args)
      warn "#{self.class}#stick_to_master is deprecated. Switch to #stick_to_primary"
      stick_to_primary(method_names, args)
    end

    # For the generic proxy implementation, we stick if we are sticky,
    # method and args don't matter
    def should_stick?(_method_name, _args)
      sticky?
    end

    # If we are configured to be sticky and we aren't bypassing stickiness,
    def sticky?
      @sticky && !@skip_sticking
    end

    # use the config parser to generate a primary and replica pool
    # def instantiate_connections
    #   puts "=======inside instantiate connection===="
    #   @primary_pool = Makara::Pool.new('primary', self)
    #   @config_parser.primary_configs.each do |primary_config|
    #     @primary_pool.add primary_config do
    #       graceful_connection_for(primary_config)
    #     end
    #   end
    #
    #   @replica_pool = Makara::Pool.new('replica', self)
    #   @config_parser.replica_configs.each do |replica_config|
    #     @replica_pool.add replica_config do
    #       graceful_connection_for(replica_config)
    #     end
    #   end
    #   puts "====primary_pool===#{@primary_pool.inspect}===="
    #   puts "====replica_pool===#{@replica_pool.inspect}===="
    # end

    def instantiate_connections
      puts "=======inside instantiate connection===="

      begin
        # Initialize both pools first to avoid circular dependency
        puts "=======creating primary pool===="
        @primary_pool = Makara::Pool.new('primary', self)
        puts "=======primary pool created===="

        puts "=======creating replica pool===="
        @replica_pool = Makara::Pool.new('replica', self)
        puts "=======replica pool created===="

        # Now add connections to primary pool
        puts "=======processing primary configs===="
        @config_parser.primary_configs.each do |primary_config|
          puts "=======adding primary config: #{primary_config.inspect}===="
          @primary_pool.add primary_config do
            graceful_connection_for(primary_config)
          end
          puts "=======primary config added===="
        end
        puts "=======finished primary configs===="

        # Now add connections to replica pool
        puts "=======processing replica configs===="
        puts "=======replica configs: #{@config_parser.replica_configs.inspect}===="
        @config_parser.replica_configs.each do |replica_config|
          puts "=======adding replica config: #{replica_config.inspect}===="
          @replica_pool.add replica_config do
            graceful_connection_for(replica_config)
          end
          puts "=======replica config added===="
        end
        puts "=======finished replica configs===="

        puts "====primary_pool===#{@primary_pool.inspect}===="
        puts "====replica_pool===#{@replica_pool.inspect}===="
        puts "=======instantiate_connections completed successfully===="

      rescue => e
        puts "=======ERROR in instantiate_connections: #{e.class}: #{e.message}===="
        puts "=======Backtrace: #{e.backtrace.first(5).join("\n")}===="
        puts "=======@replica_pool at error: #{@replica_pool.inspect}===="
        raise e
      end
    end

    def handling_an_all_execution(_method_name)
      yield
    rescue ::Makara::Errors::NoConnectionsAvailable => e
      if e.role == 'primary'
        # this means replica connections are good.
        return
      end

      @replica_pool.disabled = true
      yield
    ensure
      @replica_pool.disabled = false
    end

    # def connection_for(_config)
    #   Kernel.raise NotImplementedError
    # end

    # def connection_for(config)
    #   # This should create and return an actual database connection
    #   # For MySQL2, this would typically be something like:
    #
    #   # Remove makara-specific keys that MySQL2 doesn't understand
    #   connection_config = config.dup
    #   connection_config.delete(:makara)
    #   connection_config.delete(:primary_ttl)
    #   connection_config.delete(:blacklist_duration)
    #   connection_config.delete(:sticky)
    #   connection_config.delete(:primary_strategy)
    #   connection_config.delete(:name)
    #
    #   # Create the actual MySQL2 connection
    #   Mysql2::Client.new(connection_config)
    # end

    # def connection_for(config)
    #   puts "======config connection==#{config}"
    #   connection_config = config.dup
    #   connection_config[:charset] = connection_config.delete(:encoding) if connection_config[:encoding]
    #   %i[makara primary_ttl blacklist_duration sticky primary_strategy name].each { |k| connection_config.delete(k) }
    #
    #   begin
    #     Mysql2::Client.new(connection_config)
    #   rescue => e
    #     puts "MYSQL CONNECTION FAILED: #{e.class} - #{e.message} (#{connection_config.inspect})"
    #     raise
    #   end
    # end

    def connection_for(config)
      puts "======config connection==#{config}"
      connection_config = config.dup
      connection_config[:charset] = connection_config.delete(:encoding) if connection_config[:encoding]
      %i[makara primary_ttl blacklist_duration sticky primary_strategy name].each { |k| connection_config.delete(k) }

      begin
        # Use ActiveRecord to build the adapter
        spec = ActiveRecord::Base.send(:resolve_config_for_connection, connection_config)
        conn = ActiveRecord::Base.send(:new_connection, spec)

        conn
      rescue => e
        puts "MYSQL CONNECTION FAILED: #{e.class} - #{e.message} (#{connection_config.inspect})"
        raise
      end
    end
  end
end
