# Fix problems caused because tests all run in a single transaction.

# The single transaction means that after_commit callback never happens in tests.  Instead use savepoints.

module AfterCommit
  module AfterSavepoint
    def self.included(klass)
      klass.class_eval do
        class << self
          def include_after_savepoint_extensions
            base = ::ActiveRecord::ConnectionAdapters::AbstractAdapter
            Object.subclasses_of(base).each do |klass|
              include_after_savepoint_extension klass
            end
        
            if defined?(JRUBY_VERSION) and defined?(JdbcSpec::MySQL)
              include_after_savepoint_extension JdbcSpec::MySQL
            end
          end

          private
      
          def include_after_savepoint_extension(adapter)
            additions = AfterCommit::TestConnectionAdapters
            unless adapter.included_modules.include?(additions)
              adapter.send :include, additions
            end
          end
        end
      end
    end
  end
  
  module TestConnectionAdapters
    def self.included(base)
      base.class_eval do

        def after_callback_transaction_committed?
          committed = (Thread.current[:after_callback_committed] || {})[unique_transaction_key]
          return !committed.nil? && committed
        end

        def after_callback_mark_committed committed          
          (Thread.current[:after_callback_committed] ||= {})[unique_transaction_key] = committed
        end

        def after_callback_cleanup_committed
          (Thread.current[:after_callback_committed] ||= {})[unique_transaction_key] = nil
        end
        
        def release_savepoint_with_callback
          increment_transaction_pointer
          after_callback_mark_committed false
          begin
            trigger_before_commit_callbacks
            trigger_before_commit_on_create_callbacks
            trigger_before_commit_on_save_callbacks
            trigger_before_commit_on_update_callbacks
            trigger_before_commit_on_destroy_callbacks
            
            release_savepoint_without_callback
            after_callback_mark_committed true
            trigger_after_commit_callbacks
            trigger_after_commit_on_create_callbacks
            trigger_after_commit_on_save_callbacks
            trigger_after_commit_on_update_callbacks
            trigger_after_commit_on_destroy_callbacks
            AfterCommit.cleanup(self)
            after_callback_cleanup_committed
          ensure
            decrement_transaction_pointer
          end
        end 
        alias_method_chain :release_savepoint, :callback

        # In the event the transaction fails and rolls back, nothing inside
        # should recieve the after_commit callback, but do fire the after_rollback
        # callback for each record that failed to be committed.
        def rollback_to_savepoint_with_callback
          increment_transaction_pointer
          begin
            # Only rollback if we have not already released rollback
            unless after_callback_transaction_committed?
              trigger_before_rollback_callbacks
              rollback_to_savepoint_without_callback
              trigger_after_rollback_callbacks
            end
          ensure
            AfterCommit.cleanup(self)
            after_callback_cleanup_committed
            decrement_transaction_pointer
          end         
        end
        alias_method_chain :rollback_to_savepoint, :callback
      end
    end
  end
end
