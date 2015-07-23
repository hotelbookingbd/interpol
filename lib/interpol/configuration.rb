require 'interpol'
require 'interpol/endpoint'
require 'interpol/errors'
require 'yaml'
require 'uri'

module Interpol
  # Meant to be extended onto an array, to provide custom
  # finder methods for interpol endpoint definitions.
  module DefinitionFinder
    include HashFetcher
    NoDefinitionFound = Class.new

    def find_definition(method, path, message_type, status_code = nil)
      with_endpoint_matching(method, path) do |endpoint|
        version = yield endpoint
        find_definitions_for(endpoint, version, message_type).find do |definition|
          definition.matches_status_code?(status_code)
        end
      end
    end

  private

    def find_definitions_for(endpoint, version, message_type)
      endpoint.find_definitions(version, message_type) { [] }
    end

    def with_endpoint_matching(method, path)
      method = method.downcase.to_sym
      endpoint = find { |e| e.method == method && e.route_matches?(path) }
      (yield endpoint if endpoint) || NoDefinitionFound
    end
  end

  # Public: Defines interpol configuration.
  class Configuration
    attr_reader :endpoint_definition_files, :endpoints, :filter_example_data_blocks,
                :endpoint_definition_merge_key_files, :base_path
    attr_accessor :validation_mode, :documentation_title

    def initialize
      self.endpoint_definition_files = []
      self.endpoint_definition_merge_key_files = []
      self.base_path = ''
      self.documentation_title = "API Documentation Provided by Interpol"
      register_default_callbacks
      register_built_in_param_parsers
      @filter_example_data_blocks = []

      yield self if block_given?
    end

    def base_path=(path)
      @base_path = path
    end

    def endpoint_definition_files=(files)
      @endpoints = nil
      @endpoint_definition_files = files
    end

    def endpoint_definition_merge_key_files=(files)
      @endpoints = nil
      @endpoint_definition_merge_key_files = files
    end

    def endpoints=(endpoints)
      @endpoints = endpoints.extend(DefinitionFinder)
    end

    def endpoints
      @endpoints ||= @endpoint_definition_files.map do |file|
        Endpoint.new(deserialized_hash_from(file), self)
      end.extend(DefinitionFinder)
    end

    [:request, :response].each do |type|
      class_eval <<-EOEVAL, __FILE__, __LINE__ + 1
        def #{type}_version(version = nil, &block)
          if [version, block].compact.size.even?
            raise ConfigurationError.new("#{type}_version requires a static version " +
                                         "or a dynamic block, but not both")
          end

          @#{type}_version_block = block || lambda { |*a| version }
        end

        def #{type}_version_for(rack_env, *extra_args)
          @#{type}_version_block.call(rack_env, *extra_args).to_s
        end
      EOEVAL
    end

    def api_version(version=nil, &block)
      warn "WARNING: Interpol's #api_version config option is deprecated. " +
           "Instead, use separate #request_version and #response_version " +
           "config options."

      request_version(version, &block)
      response_version(version, &block)
    end

    def validate_response_if(&block)
      @validate_response_if_block = block
    end

    def validate_response?(*args)
      @validate_response_if_block.call(*args)
    end

    def validate_if(&block)
      warn "WARNING: Interpol's #validate_if config option is deprecated. " +
           "Instead, use #validate_response_if."

      validate_response_if(&block)
    end

    def validate_request?(env)
      @validate_request_if_block.call(env)
    end

    def validate_request_if(&block)
      @validate_request_if_block = block
    end

    def on_unavailable_sinatra_request_version(&block)
      @unavailable_sinatra_request_version_block = block
    end

    def sinatra_request_version_unavailable(execution_context, *args)
      execution_context.instance_exec(*args, &@unavailable_sinatra_request_version_block)
    end

    def on_unavailable_request_version(&block)
      @unavailable_request_version_block = block
    end

    def request_version_unavailable(*args)
      @unavailable_request_version_block.call(*args)
    end

    def on_invalid_sinatra_request_params(&block)
      @invalid_sinatra_request_params_block = block
    end

    def sinatra_request_params_invalid(execution_context, *args)
      execution_context.instance_exec(*args, &@invalid_sinatra_request_params_block)
    end

    def on_invalid_request_body(&block)
      @invalid_request_body_block = block
    end

    def request_body_invalid(*args)
      @invalid_request_body_block.call(*args)
    end

    def filter_example_data(&block)
      filter_example_data_blocks << block
    end

    def select_example_response(endpoint_name = nil, &block)
      if endpoint_name
        named_example_selectors[endpoint_name] = block
      else
        named_example_selectors.default = block
      end
    end

    def example_response_for(endpoint_def, env)
      selector = named_example_selectors[endpoint_def.endpoint_name]
      selector.call(endpoint_def, env)
    end

    def scalars_nullable_by_default=(value)
      @endpoints = nil
      @scalars_nullable_by_default = value
    end

    def scalars_nullable_by_default?
      !!@scalars_nullable_by_default
    end

    def self.default
      @default ||= Configuration.new
    end

    def customized_duplicate(&block)
      # ensure our endpoints our loaded; if they are not, they could be loaded
      # a separate time by each interpol tool (when it uses this method) and
      # that would be slow.
      endpoints

      block ||= lambda { |c| }
      dup.tap(&block)
    end

    def define_request_param_parser(type, options = {}, &block)
      ParamParser.new(type, options, &block).tap do |parser|
        # Use unshift so that new parsers take precedence over older ones.
        param_parsers[type].unshift parser
      end
    end

    def param_parser_for(type, options)
      match = param_parsers[type].find do |parser|
        parser.matches_options?(options)
      end

      return match if match

      raise UnsupportedTypeError.new(type, options)
    end

  private
    def deserialized_hash_from(file)
      YAML.load(yaml_content_for file)
    end

    def yaml_content_for(file)
      File.read(file).gsub(/\A---\n/, "---\n" + endpoint_merge_keys + "\n\n")
    end

    def endpoint_merge_keys
      @endpoint_merge_keys ||= endpoint_definition_merge_key_files.map { |f|
        File.read(f).gsub(/\A---\n/, '')
      }.join("\n\n")
    end

    def rack_json_response(status, hash)
      json = JSON.dump(hash)

      [status, { 'Content-Type'   => 'application/json',
                 'Content-Length' => json.bytesize.to_s }, [json]]
    end

    def named_example_selectors
      @named_example_selectors ||= {}
    end

    def param_parsers
      @param_parsers ||= Hash.new { |h, k| h[k] = [] }
    end

    def self.instance_eval_args_for(file)
      filename = File.expand_path("../configuration/#{file}.rb", __FILE__)
      contents = File.read(filename)
      [contents, filename, 1]
    end

    BUILT_IN_PARSER_EVAL_ARGS = instance_eval_args_for("built_in_param_parsers")

    def register_built_in_param_parsers
      instance_eval(*BUILT_IN_PARSER_EVAL_ARGS)
    end

    DEFAULT_CALLBACK_EVAL_ARGS = instance_eval_args_for("default_callbacks")
    def register_default_callbacks
      instance_eval(*DEFAULT_CALLBACK_EVAL_ARGS)
    end
  end

  # Holds the validation/parsing logic for a particular parameter
  # type (w/ additional options).
  class ParamParser
    attr_reader :type, :options
    def initialize(type, options = {})
      @type = type
      @options = options
      yield self
    end

    def string_validation_options(options = nil, &block)
      @string_validation_options_block = block || Proc.new { options }
    end

    def parse(&block)
      @parse_block = block
    end

    def matches_options?(options)
      @options.all? do |key, value|
        options.has_key?(key) && options[key] == value
      end
    end

    def type_validation_options_for(type, options)
      return type unless @string_validation_options_block
      string_options = @string_validation_options_block.call(options)
      Array(type) + [string_options.merge('type' => 'string')]
    end

    def parse_value(value)
      unless @parse_block
        raise "No parse callback has been set for param type definition: #{description}"
      end

      @parse_block.call(value)
    end

    def description
      @description ||= @type.inspect.tap do |desc|
        if @options.any?
          desc << " (with options: #{@options.inspect})"
        end
      end
    end
  end
end
