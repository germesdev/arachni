=begin
    Copyright 2010-2015 Tasos Laskos <tasos.laskos@arachni-scanner.com>

    This file is part of the Arachni Framework project and is subject to
    redistribution and commercial restrictions. Please see the Arachni Framework
    web site for more information on licensing and terms of use.
=end

module Arachni::Element
class Input

# @author Tasos "Zapotek" Laskos <tasos.laskos@arachni-scanner.com>
class DOM < Base
    include Arachni::Element::Capabilities::WithNode
    include Arachni::Element::Capabilities::Auditable::DOM

    def initialize( options )
        super

        self.method = options[:method] || self.parent.method

        if options[:inputs]
            @valid_input_name = options[:inputs].keys.first.to_s
            self.inputs       = options[:inputs]
        else
            @valid_input_name = (locator.attributes['name'] || locator.attributes['id']).to_s
            self.inputs       = {
                @valid_input_name => locator.attributes['value']
            }
        end

        @default_inputs = self.inputs.dup.freeze
    end

    # Submits the form using the configured {#inputs}.
    def trigger
        [ browser.fire_event( element, @method, value: value ) ]
    end

    def name
        inputs.keys.first
    end

    def value
        inputs.values.first
    end

    def valid_input_name?( name )
        @valid_input_name == name.to_s
    end

    def type
        self.class.type
    end
    def self.type
        :input_dom
    end

    def initialization_options
        super.merge( inputs: inputs.dup, method: @method )
    end

end
end
end
