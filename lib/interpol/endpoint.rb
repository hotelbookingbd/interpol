require 'json-schema'
require 'interpol/errors'

module Interpol
  # Represents an endpoint. Instances of this class are constructed
  # based on the endpoint definitions in the YAML files.
  class Endpoint
    attr_reader :name, :route, :method

    def initialize(endpoint_hash)
      @name        = endpoint_hash.fetch('name')
      @route       = endpoint_hash.fetch('route')
      @method      = endpoint_hash.fetch('method').downcase.to_sym
      @definitions = extract_definitions_from(endpoint_hash)
    end

    def find_example_for!(version)
      d = @definitions.fetch(version) do
        message = "No definition found for #{name} endpoint for version #{version}"
        raise ArgumentError.new(message)
      end
      d.examples.first
    end

    def available_versions
      definitions.map(&:version)
    end

    def definitions
      @definitions.values
    end

    def route_matches?(path)
      path =~ route_regex
    end

  private

    def route_regex
      @route_regex ||= begin
        regex_string = route.split('/').map do |path_part|
          if path_part.start_with?(':')
            '[^\/]+' # it's a parameter; match anything
          else
            Regexp.escape(path_part)
          end
        end.join('\/')

        /\A#{regex_string}\z/
      end
    end

    def extract_definitions_from(endpoint_hash)
      definitions = {}

      endpoint_hash.fetch('definitions').each do |definition|
        definition.fetch('versions').each do |version|
          definitions[version] = EndpointDefinition.new(self, version, definition)
        end
      end

      definitions
    end
  end

  # Wraps a single versioned definition for an endpoint.
  # Provides the means to validate data against that version of the schema.
  class EndpointDefinition
    attr_reader :endpoint, :version, :schema, :examples

    def initialize(endpoint, version, definition)
      @endpoint = endpoint
      @version  = version
      @schema   = definition.fetch('schema')
      @examples = definition.fetch('examples').map { |e| EndpointExample.new(e, self) }
      make_schema_strict!(@schema)
    end

    def validate_data!(data)
      errors = ::JSON::Validator.fully_validate_schema(schema)
      raise ValidationError.new(errors, nil, description) if errors.any?
      errors = ::JSON::Validator.fully_validate(schema, data)
      raise ValidationError.new(errors, data, description) if errors.any?
    end

    def description
      "#{endpoint.name} (v. #{version})"
    end

  private

    def make_schema_strict!(raw_schema, modify_object=true)
      return unless Hash === raw_schema

      raw_schema.each do |key, value|
        make_schema_strict!(value, key != 'properties')
      end

      return unless modify_object

      raw_schema['additionalProperties'] = false
      raw_schema['required'] = !raw_schema.delete('optional')
    end
  end

  # Wraps an example for a particular endpoint entry.
  class EndpointExample
    attr_reader :data, :definition

    def initialize(data, definition)
      @data, @definition = data, definition
    end

    def validate!
      definition.validate_data!(data)
    end
  end
end


