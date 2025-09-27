# Adapted from code orinially Copyright (c) 2013 Jonathan Stott

require 'reel'
require 'rack'
require 'stringio'
require 'uri'

module Reel
  module Rack
    class Server < Reel::Server::HTTP
      include Celluloid::Internals::Logger

      attr_reader :app

      def initialize(app, options)
        raise ArgumentError, "no host given" unless options[:Host]
        raise ArgumentError, "no port given" unless options[:Port]

        info  "A Reel good HTTP server! (Codename \"#{::Reel::CODENAME}\")"
        info "Listening on http://#{options[:Host]}:#{options[:Port]}"

        super(options[:Host], options[:Port], &method(:on_connection))
        @app = app
      end

      def on_connection(connection)
        connection.each_request do |request|
          if request.websocket?
            request.respond :bad_request, "WebSockets not supported"
          else
            route_request request
          end
        end
      end

      # Compile the regex once - Rack 3 uses lowercase headers
      CONTENT_LENGTH_HEADER = %r{^content-length$}

      def route_request(request)
        env = build_rack_env(request)
        status, headers, body = app.call(env)

        # Normalize headers for Reel (convert to string keys with proper casing)
        normalized_headers = {}
        headers.each do |key, value|
          # Reel expects headers with dashes and proper casing
          normalized_key = key.to_s.split('-').map(&:capitalize).join('-')
          normalized_headers[normalized_key] = value
        end

        if body.respond_to? :each
          # If Content-Length was specified we can send the response all at once
          if headers.keys.detect { |h| h.to_s =~ CONTENT_LENGTH_HEADER }
            # Can't use collect here because Rack::BodyProxy/Rack::Lint isn't a real Enumerable
            full_body = ''
            body.each { |b| full_body << b }
            request.respond status_symbol(status), normalized_headers, full_body
          else
            request.respond status_symbol(status), normalized_headers.merge(:transfer_encoding => :chunked)
            body.each { |chunk| request << chunk }
            request.finish_response
          end
        else
          Logger.error("don't know how to render: #{body.inspect}")
          request.respond :internal_server_error, "An error occurred processing your request"
        end

        body.close if body.respond_to? :close
      end

      def build_rack_env(request)
        uri = URI.parse(request.url)

        # Create rack.input with proper encoding for Rack 3
        body = request.body.to_s
        rack_input = StringIO.new(body.force_encoding(Encoding::ASCII_8BIT))
        rack_input.set_encoding(Encoding::ASCII_8BIT)

        env = {
          "REQUEST_METHOD"    => request.method,
          "SCRIPT_NAME"       => "",
          "PATH_INFO"         => uri.path || "/",
          "QUERY_STRING"      => uri.query || "",
          "SERVER_NAME"       => uri.host || "localhost",
          "SERVER_PORT"       => (uri.port || 80).to_s,
          "SERVER_PROTOCOL"   => "HTTP/1.1",
          "rack.version"      => ::Rack::VERSION,
          "rack.url_scheme"   => uri.scheme || "http",
          "rack.input"        => rack_input,
          "rack.errors"       => $stderr,
          "rack.multithread"  => true,
          "rack.multiprocess" => false,
          "rack.run_once"     => false,
          "rack.hijack?"      => false,
          "REMOTE_ADDR"       => request.remote_addr
        }

        # Add HTTP headers
        request.headers.each do |key, value|
          header = key.upcase.gsub('-', '_')
          if NO_PREFIX_HEADERS.member?(header)
            env[header] = value
          else
            env["HTTP_#{header}"] = value
          end
        end

        # Normalize SERVER_NAME and SERVER_PORT from HTTP_HOST if present
        if host = env["HTTP_HOST"]
          if colon = host.index(":")
            env["SERVER_NAME"] = host[0, colon]
            env["SERVER_PORT"] = host[colon+1, host.bytesize]
          else
            env["SERVER_NAME"] = host
            env["SERVER_PORT"] = (env['HTTP_X_FORWARDED_PROTO'] == 'https' ? "443" : "80")
          end
        end

        env
      end

      # Those headers must not start with 'HTTP_'.
      NO_PREFIX_HEADERS=%w[CONTENT_TYPE CONTENT_LENGTH].freeze

      def status_symbol(status)
        if status.is_a?(Integer)
          Reel::Response::STATUS_CODES[status].downcase.gsub(/\s|-/, '_').to_sym
        else
          status.to_sym
        end
      end
    end
  end
end
