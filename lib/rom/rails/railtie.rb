require 'rails'

require 'rom/rails/inflections'
require 'rom/rails/configuration'
require 'rom/rails/controller_extension'
require 'rom/rails/active_record/configuration'

Spring.after_fork { ROM::Rails::Railtie.disconnect } if defined?(Spring)

module ROM
  module Rails
    class Railtie < ::Rails::Railtie
      COMPONENT_DIRS = %w(relations mappers commands).freeze

      attr_accessor :rake_mode

      MissingRepositoryConfigError = Class.new(StandardError)

      initializer 'rom.configure_action_controller' do
        ActiveSupport.on_load(:action_controller) do
          ActionController::Base.send(:include, ControllerExtension)
        end
      end

      initializer 'rom.adjust_eager_load_paths' do |app|
        paths = COMPONENT_DIRS.map do |directory|
          root.join('app', directory).to_s
        end

        app.config.eager_load_paths -= paths
      end

      rake_tasks do
        load "rom/rails/tasks/db.rake" unless self.class.active_record?
        self.rake_mode = true
      end

      # Make `ROM::Rails::Configuration` instance available to the user via
      # `Rails.application.config` before other initializers run.
      config.before_initialize do |_app|
        Railtie.set_configuration
      end

      # Reload ROM-related application code on each request.
      config.to_prepare do |_config|
        Railtie.finalize
      end

      # Behaves like `Railtie#configure` if the given block does not take any
      # arguments. Otherwise yields the ROM configuration to the block.
      #
      # @example
      #   ROM::Rails::Railtie.configure do |config|
      #     config.repositories[:default] = [:yaml, 'yaml:///data']
      #   end
      #
      # @api public
      def configure(&block)
        if block.arity == 1
          block.call(config.rom)
        else
          super
        end
      end

      # @api public
      def setup
        repositories = config.rom.repositories

        raise(
          MissingRepositoryConfigError,
          "seems like you didn't configure any repositories"
        ) unless repositories.any?

        ROM.setup(repositories)
        self
      end

      # @api public
      def finalize
        if ROM.env
          prepare_repositories(ROM.env.repositories)
        else
          prepare_repositories
        end

        setup
        unless rake_mode
          load_components
        else
          puts '<= skipping loading rom components'
        end
        ROM.finalize

        self
      end

      # @api private
      def set_configuration
        config.rom = Configuration.new
        self
      end

      # If there's no default repository configured, try to infer it from
      # other sources, e.g. ActiveRecord.
      #
      # @api private
      def infer_default_repository
        return unless active_record?
        spec = ROM::Rails::ActiveRecord::Configuration.call
        [:sql, spec[:uri], spec[:options]]
      end

      # TODO: Add `ROM.env.disconnect` to core.
      #
      # @api private
      def disconnect
        ROM.env.repositories.each_value(&:disconnect)
      end

      # @api private
      def prepare_repositories(repositories = nil)
        repositories ||= config.rom.repositories
        repositories[:default] ||= infer_default_repository if active_record?
        repositories
      end

      # @api private
      def load_components
        COMPONENT_DIRS.each { |type| load_files(type) }
      end

      # @api private
      def load_files(type)
        Dir[root.join("app/#{type}/**/*.rb")].each do |path|
          require_dependency(path)
        end
      end

      # @api private
      def root
        ::Rails.root
      end

      # @api private
      def active_record?
        defined?(::ActiveRecord)
      end
    end
  end
end
