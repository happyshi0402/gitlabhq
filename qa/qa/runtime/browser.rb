require 'rspec/core'
require 'capybara/rspec'
require 'capybara-screenshot/rspec'
require 'selenium-webdriver'

module QA
  module Runtime
    class Browser
      include QA::Scenario::Actable

      def initialize
        self.class.configure!
      end

      ##
      # Visit a page that belongs to a GitLab instance under given address.
      #
      # Example:
      #
      # visit(:gitlab, Page::Main::Login)
      # visit('http://gitlab.example/users/sign_in')
      #
      # In case of an address that is a symbol we will try to guess address
      # based on `Runtime::Scenario#something_address`.
      #
      def visit(address, page = nil, &block)
        Browser::Session.new(address, page).perform(&block)
      end

      def self.visit(address, page = nil, &block)
        new.visit(address, page, &block)
      end

      def self.configure!
        RSpec.configure do |config|
          config.define_derived_metadata(file_path: %r{/qa/specs/features/}) do |metadata|
            metadata[:type] = :feature
          end
        end

        return if Capybara.drivers.include?(:chrome)

        Capybara.register_driver :chrome do |app|
          capabilities = Selenium::WebDriver::Remote::Capabilities.chrome(
            # This enables access to logs with `page.driver.manage.get_log(:browser)`
            loggingPrefs: {
              browser: "ALL",
              client: "ALL",
              driver: "ALL",
              server: "ALL"
            }
          )

          if QA::Runtime::Env.accept_insecure_certs?
            capabilities['acceptInsecureCerts'] = true
          end

          options = Selenium::WebDriver::Chrome::Options.new
          options.add_argument("window-size=1240,1680")

          # Chrome won't work properly in a Docker container in sandbox mode
          options.add_argument("no-sandbox")

          # Run headless by default unless CHROME_HEADLESS is false
          if QA::Runtime::Env.chrome_headless?
            options.add_argument("headless")

            # Chrome documentation says this flag is needed for now
            # https://developers.google.com/web/updates/2017/04/headless-chrome#cli
            options.add_argument("disable-gpu")
          end

          # Use the same profile on QA runs if CHROME_REUSE_PROFILE is true.
          # Useful to speed up local QA.
          if QA::Runtime::Env.reuse_chrome_profile?
            qa_profile_dir = ::File.expand_path('../../tmp/qa-profile', __dir__)
            options.add_argument("user-data-dir=#{qa_profile_dir}")
          end

          # Disable /dev/shm use in CI. See https://gitlab.com/gitlab-org/gitlab-ee/issues/4252
          options.add_argument("disable-dev-shm-usage") if QA::Runtime::Env.running_in_ci?

          Capybara::Selenium::Driver.new(
            app,
            browser: :chrome,
            clear_local_storage: true,
            desired_capabilities: capabilities,
            options: options
          )
        end

        # Keep only the screenshots generated from the last failing test suite
        Capybara::Screenshot.prune_strategy = :keep_last_run

        # From https://github.com/mattheworiordan/capybara-screenshot/issues/84#issuecomment-41219326
        Capybara::Screenshot.register_driver(:chrome) do |driver, path|
          driver.browser.save_screenshot(path)
        end

        Capybara::Screenshot.register_filename_prefix_formatter(:rspec) do |example|
          ::File.join(QA::Runtime::Namespace.name, example.file_path.sub('./qa/specs/features/', ''))
        end

        Capybara.configure do |config|
          config.default_driver = :chrome
          config.javascript_driver = :chrome
          config.default_max_wait_time = 10
          # https://github.com/mattheworiordan/capybara-screenshot/issues/164
          config.save_path = ::File.expand_path('../../tmp', __dir__)
        end
      end

      class Session
        include Capybara::DSL

        def initialize(instance, page = nil)
          @session_address = Runtime::Address.new(instance, page)
        end

        def url
          @session_address.address
        end

        def perform(&block)
          visit(url)

          if QA::Runtime::Env.qa_cookies
            browser = Capybara.current_session.driver.browser
            QA::Runtime::Env.qa_cookies.each do |cookie|
              name, value = cookie.split("=")
              value ||= ""
              browser.manage.add_cookie name: name, value: value
            end
          end

          yield.tap { clear! } if block_given?
        end

        ##
        # Selenium allows to reset session cookies for current domain only.
        #
        # See gitlab-org/gitlab-qa#102
        #
        def clear!
          visit(url)
          reset_session!
        end
      end
    end
  end
end
