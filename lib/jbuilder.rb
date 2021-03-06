require 'active_support/basic_object'
require 'active_support/ordered_hash'
require 'active_support/core_ext/array/access'
require 'active_support/core_ext/enumerable'
require 'active_support/core_ext/hash'
require 'active_support/cache'
require 'multi_json'
require 'bigdecimal'

class Jbuilder < ActiveSupport::BasicObject
  class BigDecimalFloatingPointRepresentationFix < ::BigDecimal
    def as_json(x=nil); self; end
    def to_json(x=nil); to_s; end
  end

  class KeyFormatter
    def initialize(*args)
      @format = {}
      @cache = {}

      options = args.extract_options!
      args.each do |name|
        @format[name] = []
      end
      options.each do |name, paramaters|
        @format[name] = paramaters
      end
    end

    def initialize_copy(original)
      @cache = {}
    end

    def format(key)
      @cache[key] ||= @format.inject(key.to_s) do |result, args|
        func, args = args
        if func.is_a? Proc
          func.call(result, *args)
        else
          result.send(func, *args)
        end
      end
    end
  end

  # Yields a builder and automatically turns the result into a JSON string
  def self.encode(*args)
    jbuilder = new(*args)
    yield jbuilder
    jbuilder.target!
  end

  @@key_formatter              = KeyFormatter.new
  @@ignore_nil                 = false
  @@use_floating_point_numbers = false

  def initialize(key_formatter = @@key_formatter.clone, ignore_nil = @@ignore_nil, use_floating_point_numbers = @@use_floating_point_numbers)
    @attributes                 = ::ActiveSupport::OrderedHash.new
    @key_formatter              = key_formatter
    @ignore_nil                 = ignore_nil
    @use_floating_point_numbers = use_floating_point_numbers
  end

  # Dynamically set a key value pair.
  #
  # Example:
  #
  #   json.set!(:each, "stuff")
  #
  #   { "each": "stuff" }
  #
  # You can also pass a block for nested attributes
  #
  #   json.set!(:author) do
  #     json.name "David"
  #     json.age 32
  #   end
  #
  #   { "author": { "name": "David", "age": 32 } }
  def set!(key, value = nil)
    if ::Kernel::block_given?
      _set_value(key, _scope { yield self })
    else
      _set_value(key, value)
    end
  end

  # Specifies formatting to be applied to the key. Passing in a name of a function
  # will cause that function to be called on the key.  So :upcase will upper case
  # the key.  You can also pass in lambdas for more complex transformations.
  #
  # Example:
  #
  #   json.key_format! :upcase
  #   json.author do
  #     json.name "David"
  #     json.age 32
  #   end
  #
  #   { "AUTHOR": { "NAME": "David", "AGE": 32 } }
  #
  # You can pass parameters to the method using a hash pair.
  #
  #   json.key_format! :camelize => :lower
  #   json.first_name "David"
  #
  #   { "firstName": "David" }
  #
  # Lambdas can also be used.
  #
  #   json.key_format! ->(key){ "_" + key }
  #   json.first_name "David"
  #
  #   { "_first_name": "David" }
  #
  def key_format!(*args)
    @key_formatter = KeyFormatter.new(*args)
  end

  # Same as the instance method key_format! except sets the default.
  def self.key_format(*args)
    @@key_formatter = KeyFormatter.new(*args)
  end

  # If you want to skip adding nil values to your JSON hash. This is useful
  # for JSON clients that don't deal well with nil values, and would prefer
  # not to receive keys which have null values.
  #
  # Example:
  #   json.ignore_nil!
  #   json.id User.new.id
  #
  #   { "id": null }
  #
  #   json.ignore_nil
  #   json.id User.new.id
  #
  #   {}
  #
  def ignore_nil!(value = true)
    @ignore_nil = value
  end

  # Same as instance method ignore_nil! except sets the default.
  def self.ignore_nil(value = true)
    @@ignore_nil = value
  end

  # If you want BigDecimal values to be represented as floating point numbers,
  # set the value to true. You might lose accuracy depending on the JSON parser.
  #
  # Example:
  #   json.use_floating_point_numbers!
  #
  def use_floating_point_numbers!(value = true)
    @use_floating_point_numbers = value
  end

  # Same as instance method use_floating_point_numbers! except sets the default.
  def self.use_floating_point_numbers(value = true)
    @@use_floating_point_numbers = value
  end

  # Turns the current element into an array and yields a builder to add a hash.
  #
  # Example:
  #
  #   json.comments do
  #     json.child! { json.content "hello" }
  #     json.child! { json.content "world" }
  #   end
  #
  #   { "comments": [ { "content": "hello" }, { "content": "world" } ]}
  #
  # More commonly, you'd use the combined iterator, though:
  #
  #   json.comments(@post.comments) do |comment|
  #     json.content comment.formatted_content
  #   end
  def child!
    @attributes = [] unless @attributes.is_a? ::Array
    @attributes << _scope { yield self }
  end

  # Turns the current element into an array and iterates over the passed collection, adding each iteration as
  # an element of the resulting array.
  #
  # Example:
  #
  #   json.array!(@people) do |person|
  #     json.name person.name
  #     json.age calculate_age(person.birthday)
  #   end
  #
  #   [ { "name": David", "age": 32 }, { "name": Jamie", "age": 31 } ]
  #
  # If you are using Ruby 1.9+, you can use the call syntax instead of an explicit extract! call:
  #
  #   json.(@people) { |person| ... }
  #
  # It's generally only needed to use this method for top-level arrays. If you have named arrays, you can do:
  #
  #   json.people(@people) do |person|
  #     json.name person.name
  #     json.age calculate_age(person.birthday)
  #   end
  #
  #   { "people": [ { "name": David", "age": 32 }, { "name": Jamie", "age": 31 } ] }
  #
  # If you omit the block then you can set the top level array directly:
  #
  #   json.array! [1, 2, 3]
  #
  #   [1,2,3]
  def array!(collection)
    @attributes = if ::Kernel::block_given?
      _map_collection(collection) { |element| if ::Proc.new.arity == 2 then yield self, element else yield element end }
    else
      collection
    end
  end

  # Extracts the mentioned attributes or hash elements from the passed object and turns them into attributes of the JSON.
  #
  # Example:
  #
  #   @person = Struct.new(:name, :age).new("David", 32)
  #
  #   or you can utilize a Hash
  #
  #   @person = {:name => "David", :age => 32}
  #
  #   json.extract! @person, :name, :age
  #
  #   { "name": David", "age": 32 }, { "name": Jamie", "age": 31 }
  #
  # If you are using Ruby 1.9+, you can use the call syntax instead of an explicit extract! call:
  #
  #   json.(@person, :name, :age)
  def extract!(object, *attributes)
    if object.is_a?(::Hash)
      attributes.each {|attribute| _set_value attribute, object.send(:fetch, attribute)}
    else
      attributes.each {|attribute| _set_value attribute, object.send(attribute)}
    end
  end

  def call(object = nil, *attributes)
    if attributes.empty?
      array!(object, &::Proc.new)
    else
      extract!(object, *attributes)
    end
  end

  # Returns the attributes of the current builder.
  def attributes!
    @attributes
  end

  # Convert all BigDecimals to floating point numbers.
  def force_floating_point_numbers(hash)
    hash.each do |key, value|
      if value.is_a?(::Hash)
        force_floating_point_numbers(value)
      elsif value.is_a?(::BigDecimal)
        hash[key] = BigDecimalFloatingPointRepresentationFix.new(value.to_s)
      else
        hash[key] = value
      end
    end

    hash
  end

  # Encodes the current builder as JSON.
  def target!
    if @use_floating_point_numbers
      force_floating_point_numbers(@attributes)
    end

    ::MultiJson.encode @attributes
  end

  protected
    def _set_value(key, value)
      unless @ignore_nil && value.nil?
        @attributes[@key_formatter.format(key)] = value
      end
    end

  private
    def method_missing(method, value = nil, *args)
      result = if ::Kernel.block_given?
        if value
          # json.comments @post.comments { |comment| ... }
          # { "comments": [ { ... }, { ... } ] }
          _map_collection(value) { |element| if ::Proc.new.arity == 2 then yield self, element else yield element end }
        else
          # json.comments { ... }
          # { "comments": ... }
          _scope { yield self }
        end
      else
        if args.empty?
          if ::Jbuilder === value
            # json.age 32
            # json.person another_jbuilder
            # { "age": 32, "person": { ...  }
            value.attributes!
          else
            # json.age 32
            # { "age": 32 }
            value
          end
        else
          if value.respond_to?(:each)
            # json.comments(@post.comments, :content, :created_at)
            # { "comments": [ { "content": "hello", "created_at": "..." }, { "content": "world", "created_at": "..." } ] }
            _map_collection(value) do |element|
              args.each do |attribute|
                _set_value attribute, element.send(attribute)
              end
            end
          else
            # json.author @post.creator, :name, :email_address
            # { "author": { "name": "David", "email_address": "david@loudthinking.com" } }
            _scope { extract! value, *args }
          end
        end
      end
      _set_value method, result
    end

    def _map_collection(collection)
      collection.map do |element|
        _scope { yield element }
      end
    end

    def _scope
      parent_attributes, parent_formatter = @attributes, @key_formatter
      @attributes = ::ActiveSupport::OrderedHash.new
      yield
      @attributes
    ensure
      @attributes, @key_formatter = parent_attributes, parent_formatter
    end

    def _merge(hash_or_array)
      if hash_or_array.is_a?(::Array)
        @attributes = [] unless @attributes.is_a? ::Array
        @attributes.concat(hash_or_array)
      else
        @attributes.update(hash_or_array)
      end
    end
end

require "jbuilder_template" if defined?(ActionView::Template)
