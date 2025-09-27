require 'celluloid/autostart'
require 'reel/rack/server'

module Rack
  module Handler
    class Reel
      DEFAULT_OPTIONS = {
        :Host    => "0.0.0.0",
        :Port    => 3000,
        :quiet   => false
      }

      def self.run(app, options = {})
        options = DEFAULT_OPTIONS.merge(options)

        app = Rack::CommonLogger.new(app, STDOUT) unless options[:quiet]
        ENV['RACK_ENV'] = options[:environment].to_s if options[:environment]

        supervisor = ::Reel::Rack::Server.supervise(as: :reel_rack_server, args: [app, options])

        begin
          sleep
        rescue Interrupt
          if defined?(Celluloid) && Celluloid.respond_to?(:logger)
            Celluloid.logger.info "Interrupt received... shutting down"
          else
            puts "[INFO] Interrupt received... shutting down"
          end
          supervisor.terminate
        end
      end
    end
  end
end

# For Rack 3 compatibility, register the handler if the method exists
if Rack::Handler.respond_to?(:register)
  Rack::Handler.register(:reel, Rack::Handler::Reel)
end
