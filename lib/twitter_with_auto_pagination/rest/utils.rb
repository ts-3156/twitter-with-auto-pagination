require 'hashie'

module TwitterWithAutoPagination
  module REST
    module Utils
      # for backward compatibility
      def uid
        @uid || user.id.to_i
      end

      def __uid
        ActiveSupport::Deprecation.warn(<<-MESSAGE.strip_heredoc)
          `TwitterWithAutoPagination::Utils##{__method__}` is deprecated.
        MESSAGE
        uid
      end

      def __uid_i
        ActiveSupport::Deprecation.warn(<<-MESSAGE.strip_heredoc)
          `TwitterWithAutoPagination::Utils##{__method__}` is deprecated.
        MESSAGE
        uid
      end

      # for backward compatibility
      def screen_name
        @screen_name || user.screen_name
      end

      def __screen_name
        ActiveSupport::Deprecation.warn(<<-MESSAGE.strip_heredoc)
          `TwitterWithAutoPagination::Utils##{__method__}` is deprecated.
        MESSAGE
        screen_name
      end

      def uid_or_screen_name?(object)
        object.kind_of?(String) || object.kind_of?(Integer)
      end

      def authenticating_user?(target)
        user.id.to_i == user(target).id.to_i
      end

      def authorized_user?(target)
        target_user = user(target)
        !target_user.protected? || friendship?(user.id.to_i, target_user.id.to_i)
      end

      def instrument(operation, key, options = nil)
        payload = {operation: operation, key: key}
        payload.merge!(options) if options.is_a?(Hash)
        ActiveSupport::Notifications.instrument('call.twitter_with_auto_pagination', payload) { yield(payload) }
      end

      def call_api(method_obj, *args)
        api_options = args.extract_options!
        begin
          self.call_count += 1
          # TODO call without reduce, call_count
          options = {method_name: method_obj.name, call_count: self.call_count, args: [*args, api_options]}
          instrument('request', args[0], options) { method_obj.call(*args, api_options) }
        rescue Twitter::Error::TooManyRequests => e
          logger.warn "#{__method__}: #{options.inspect} #{e.class} Retry after #{e.rate_limit.reset_in} seconds."
          raise e
        rescue Twitter::Error::ServiceUnavailable, Twitter::Error::InternalServerError,
          Twitter::Error::Forbidden, Twitter::Error::NotFound => e
          logger.warn "#{__method__}: #{options.inspect} #{e.class} #{e.message}"
          raise e
        rescue => e
          logger.warn "NEED TO CATCH! #{__method__}: #{options.inspect} #{e.class} #{e.message}"
          raise e
        end
      end

      # user_timeline, search
      def collect_with_max_id(method_obj, *args)
        options = args.extract_options!
        call_limit = options.delete(:call_limit) || 3
        last_response = call_api(method_obj, *args, options)
        last_response = yield(last_response) if block_given?
        return_data = last_response
        call_count = 1

        while last_response.any? && call_count < call_limit
          options[:max_id] = last_response.last.kind_of?(Hash) ? last_response.last[:id] : last_response.last.id
          last_response = call_api(method_obj, *args, options)
          last_response = yield(last_response) if block_given?
          return_data += last_response
          call_count += 1
        end

        return_data.flatten
      end

      # friends, followers
      def collect_with_cursor(method_obj, *args)
        options = args.extract_options!
        last_response = call_api(method_obj, *args, options).attrs
        return_data = (last_response[:users] || last_response[:ids])

        while (next_cursor = last_response[:next_cursor]) && next_cursor != 0
          options[:cursor] = next_cursor
          last_response = call_api(method_obj, *args, options).attrs
          return_data += (last_response[:users] || last_response[:ids])
        end

        return_data
      end

      require 'digest/md5'

      def file_cache_key(method_name, user, options = {})
        delim = ':'
        identifier =
          case
            when method_name == :verify_credentials
              "object-id#{delim}#{object_id}"
            when method_name == :search
              "str#{delim}#{user.to_s}"
            when method_name == :mentions_timeline
              "#{user.kind_of?(Integer) ? 'id' : 'sn'}#{delim}#{user.to_s}"
            when method_name == :home_timeline
              "#{user.kind_of?(Integer) ? 'id' : 'sn'}#{delim}#{user.to_s}"
            when method_name.in?([:users, :replying]) && options[:super_operation].present?
              case
                when user.kind_of?(Array) && user.first.kind_of?(Integer)
                  "#{options[:super_operation]}-ids#{delim}#{Digest::MD5.hexdigest(user.join(','))}"
                when user.kind_of?(Array) && user.first.kind_of?(String)
                  "#{options[:super_operation]}-sns#{delim}#{Digest::MD5.hexdigest(user.join(','))}"
                else raise "#{method_name.inspect} #{user.inspect}"
              end
            when user.kind_of?(Integer)
              "id#{delim}#{user.to_s}"
            when user.kind_of?(Array) && user.first.kind_of?(Integer)
              "ids#{delim}#{Digest::MD5.hexdigest(user.join(','))}"
            when user.kind_of?(Array) && user.first.kind_of?(String)
              "sns#{delim}#{Digest::MD5.hexdigest(user.join(','))}"
            when user.kind_of?(String)
              "sn#{delim}#{user}"
            when user.kind_of?(Twitter::User)
              "user#{delim}#{user.id.to_s}"
            else raise "#{method_name.inspect} #{user.inspect}"
          end

        "#{method_name}#{delim}#{identifier}"
      end

      def namespaced_key(method_name, user, options = {})
        file_cache_key(method_name, user, options)
      end

      PROFILE_SAVE_KEYS = %i(
          id
          name
          screen_name
          location
          description
          url
          protected
          followers_count
          friends_count
          listed_count
          favourites_count
          utc_offset
          time_zone
          geo_enabled
          verified
          statuses_count
          lang
          status
          profile_image_url_https
          profile_banner_url
          profile_link_color
          suspended
          verified
          entities
          created_at
        )

      STATUS_SAVE_KEYS = %i(
        created_at
        id
        text
        source
        truncated
        coordinates
        place
        entities
        user
        contributors
        is_quote_status
        retweet_count
        favorite_count
        favorited
        retweeted
        possibly_sensitive
        lang
      )

      # encode
      def encode_json(obj, caller_name, options = {})
        options[:reduce] = true unless options.has_key?(:reduce)
        case caller_name
          when :user_timeline, :home_timeline, :mentions_timeline, :favorites # Twitter::Tweet
            JSON.pretty_generate(obj.map { |o| o.attrs })

          when :search # Hash
            data =
              if options[:reduce]
                obj.map { |o| o.to_hash.slice(*STATUS_SAVE_KEYS) }
              else
                obj.map { |o| o.to_hash }
              end
            JSON.pretty_generate(data)

          when :friends, :followers # Hash
            data =
              if options[:reduce]
                obj.map { |o| o.to_hash.slice(*PROFILE_SAVE_KEYS) }
              else
                obj.map { |o| o.to_hash }
              end
            JSON.pretty_generate(data)

          when :friend_ids, :follower_ids # Integer
            JSON.pretty_generate(obj)

          when :verify_credentials # Twitter::User
            JSON.pretty_generate(obj.to_hash.slice(*PROFILE_SAVE_KEYS))

          when :user # Twitter::User
            JSON.pretty_generate(obj.to_hash.slice(*PROFILE_SAVE_KEYS))

          when :users, :friends_parallelly, :followers_parallelly # Twitter::User
            data =
              if options[:reduce]
                obj.map { |o| o.to_hash.slice(*PROFILE_SAVE_KEYS) }
              else
                obj.map { |o| o.to_hash }
              end
            JSON.pretty_generate(data)

          when :user? # true or false
            obj

          when :friendship? # true or false
            obj

          else
            raise "#{__method__}: caller=#{caller_name} key=#{options[:key]} obj=#{obj.inspect}"
        end
      end

      # decode
      def decode_json(json_str, caller_name, options = {})
        obj = json_str.kind_of?(String) ? JSON.parse(json_str) : json_str
        case
          when obj.nil?
            obj

          when obj.kind_of?(Array) && obj.first.kind_of?(Hash)
            obj.map { |o| Hashie::Mash.new(o) }

          when obj.kind_of?(Array) && obj.first.kind_of?(Integer)
            obj

          when obj.kind_of?(Hash)
            Hashie::Mash.new(obj)

          when obj === true || obj === false
            obj

          when obj.kind_of?(Array) && obj.empty?
            obj

          else
            raise "#{__method__}: caller=#{caller_name} key=#{options[:key]} obj=#{obj.inspect}"
        end
      end

      def fetch_cache_or_call_api(method_name, user, options = {})
        key = namespaced_key(method_name, user, options)
        # options.update(key: key)

        fetch_result =
          if options[:cache] == :read
            instrument('Cache Read(Force)', key, caller: method_name) { cache.read(key) }
          else
            cache.fetch(key, expires_in: 1.hour, race_condition_ttl: 5.minutes) do
              block_result = yield
              instrument('serialize', key, caller: method_name) { encode_json(block_result, method_name, options) }
            end
          end

        instrument('deserialize', key, caller: method_name) { decode_json(fetch_result, method_name, options) }
      end
    end
  end
end