require 'active_record/connection_adapters/makara_abstract_adapter'
require 'active_record/connection_adapters/mysql2_adapter'

# module ActiveRecord
#   module ConnectionHandling
#     def mysql2_makara_connection(config)
#       ActiveRecord::ConnectionAdapters::MakaraMysql2Adapter.new(config)
#     end
#   end
# end

module ActiveRecord
  module ConnectionHandling
    def makara_mysql2_connection(config)
      ActiveRecord::ConnectionAdapters::MakaraMysql2Adapter.new(config).tap do |adapter|
        adapter.active_record_connection_for(config)
      end
    end
  end
end

module ActiveRecord
  module ConnectionAdapters
    class MakaraMysql2Adapter < ActiveRecord::ConnectionAdapters::MakaraAbstractAdapter
      class << self
        def visitor_for(*args)
          ActiveRecord::ConnectionAdapters::Mysql2Adapter.visitor_for(*args)
        end
      end

      protected

      # def active_record_connection_for(config)
      #   ::ActiveRecord::ConnectionAdapters::Mysql2Adapter.new(
      #       config,
      #       logger,
      #       pool,
      #       schema_cache
      #   )
      # end
      #
      # def active_record_connection_for(config)
      #   puts "===config====+#{config.inspect}"
      #   client = ActiveRecord::ConnectionAdapters::Mysql2Adapter.new_client(
      #       config.symbolize_keys.slice(:host, :username, :password, :port, :database, :flags, :encoding)
      #   )
      #
      #   ActiveRecord::ConnectionAdapters::Mysql2Adapter.new(
      #       client,
      #       logger,
      #       nil,    # pool handled by Makara
      #       config
      #   )
      # end

    end
  end
end
