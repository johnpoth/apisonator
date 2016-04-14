require '3scale/backend/oauth'

module ThreeScale
  module Backend
    module OAuthAccessTokenStorage
      class << self
        def get_app_id(service_id, token)
          ids = OAuth::Token::Storage.get_credentials(token, service_id)
          raise AccessTokenInvalid.new token if ids.first.nil?
          ids
        end

        # triggered by Application deletion.
        #
        # requires service_id and app_id at the least, optionally user_id
        #
        # If user_id is nil or unspecified, will remove all app tokens
        #
        def remove_app_tokens(service_id, app_id, user_id = nil)
          if user_id
            OAuth::Token::Storage.remove_tokens service_id, app_id, user_id
          else
            OAuth::Token::Storage.remove_all_tokens service_id, app_id
          end
        end

      end
    end
  end
end
