require 'twitter_with_auto_pagination/rest/utils'
require 'parallel'

module TwitterWithAutoPagination
  module REST
    module Users
      include TwitterWithAutoPagination::REST::Utils

      def verify_credentials(*args)
        options = {skip_status: true}.merge(args.extract_options!)
        instrument(__method__, nil, options) do
          fetch_cache_or_call_api(__method__, args) do
            call_api(method(__method__).super_method, *args, options).to_hash
          end
        end
      end

      def user?(*args)
        options = args.extract_options!
        return false if args.empty? || args[0].nil? || !args[0].to_s.match(/\A([a-zA-Z0-9_]{1,20}|[1-9][0-9]*)\z/)
        instrument(__method__, nil, options) do
          fetch_cache_or_call_api(__method__, args[0], options) do
            call_api(method(__method__).super_method, *args, options)
          end
        end
      end

      def user(*args)
        options = args.extract_options!
        args[0] = verify_credentials(super_operation: __method__).id if args.empty?
        instrument(__method__, nil, options) do
          fetch_cache_or_call_api(__method__, args[0], options) do
            call_api(method(__method__).super_method, *args, options).to_hash
          end
        end
      end

      # use compact, not use sort and uniq
      # specify reduce: false to use tweet for inactive_*
      # TODO Perhaps `old_users` automatically merges result...
      def users(*args)
        options = args.extract_options!
        options[:reduce] = false
        users_per_workers = args.first.compact.each_slice(100).to_a
        processed_users = []
        thread_size = [users_per_workers.size, 10].min

        instrument(__method__, nil, options) do
          Parallel.each_with_index(users_per_workers, in_threads: thread_size) do |users_per_worker, i|
            _users = fetch_cache_or_call_api(__method__, users_per_worker, options) do
              call_api(method(__method__).super_method, users_per_worker, options).map { |u| u.to_hash }
            end

            processed_users << {i: i, users: _users}
          end
        end

        processed_users.sort_by { |p| p[:i] }.map { |p| p[:users] }.flatten.compact
      end
    end
  end
end
