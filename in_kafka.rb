#require 'fluent/input'

module Fluent

class KafkaGroupInput < Input
  Plugin.register_input('kafka_group', self)

  config_param :brokers, :string,
               :desc => "List of broker-host:port, separate with comma, must set."
  config_param :zookeepers, :string, :default => 'nozookeeper',
               :desc => "List of broker-host:port, separate with comma, must set."
  config_param :consumer_group, :string, :default => nil,
               :desc => "Consumer group name, must set."
  config_param :topics, :string,
               :desc => "Listening topics(separate with comma',')."
  config_param :interval, :integer, :default => 1, # seconds
               :desc => "Interval (Unit: seconds)"
  config_param :format, :string, :default => 'json',
               :desc => "Supported format: (json|text|ltsv|msgpack)"
  config_param :message_key, :string, :default => 'message',
               :desc => "For 'text' format only."
  config_param :add_prefix, :string, :default => nil,
               :desc => "Tag prefix (Optional)"
  config_param :add_suffix, :string, :default => nil,
               :desc => "Tag suffix (Optional)"

  # poseidon PartitionConsumer options
  config_param :max_bytes, :integer, :default => nil,
               :desc => "Maximum number of bytes to fetch."
  config_param :max_wait_ms, :integer, :default => nil,
               :desc => "How long to block until the server sends us data."
  config_param :min_bytes, :integer, :default => nil,
               :desc => "Smallest amount of data the server should send us."
  config_param :socket_timeout_ms, :integer, :default => nil,
               :desc => "How long to wait for reply from server. Should be higher than max_wait_ms."

  unless method_defined?(:router)
    define_method("router") { Fluent::Engine }
  end

  def initialize
    super
    require 'kafka'
  end

  def _config_to_array(config)
    config_array = config.split(',').map {|k| k.strip }
    if config_array.empty?
      raise ConfigError, "kafka_group: '#{config}' is a required parameter"
    end
    config_array
  end

  private :_config_to_array

  def configure(conf)
    super
    @broker_list = _config_to_array(@brokers)
    @zookeeper_list = _config_to_array(@zookeepers)
    @topic_list = _config_to_array(@topics)

    unless @consumer_group
      raise ConfigError, "kafka_group: 'consumer_group' is a required parameter"
    end
    $log.info "Will watch for topics #{@topic_list} at brokers " \
              "#{@broker_list}, zookeepers #{@zookeeper_list} and group " \
              "'#{@consumer_group}'"

    case @format
    when 'json'
      require 'yajl'
    when 'ltsv'
      require 'ltsv'
    when 'msgpack'
      require 'msgpack'
    end
  end

  def start
    super
    @loop = Coolio::Loop.new
    opt = {}
    opt[:max_bytes] = @max_bytes if @max_bytes
    opt[:max_wait_ms] = @max_wait_ms if @max_wait_ms
    opt[:min_bytes] = @min_bytes if @min_bytes
    opt[:socket_timeout_ms] = @socket_timeout_ms if @socket_timeout_ms

    @topic_watchers = @topic_list.map {|topic|
      TopicWatcher.new(topic, @broker_list, @zookeeper_list, @consumer_group,
                       interval, @format, @message_key, @add_prefix,
                       @add_suffix, router, opt)
    }
    @topic_watchers.each {|tw|
      tw.attach(@loop)
    }
    @thread = Thread.new(&method(:run))
  end

  def shutdown
    @loop.stop
    super
  end

  def run
    @loop.run
  rescue
    $log.error "unexpected error", :error=>$!.to_s
    $log.error_backtrace
  end

  class TopicWatcher < Coolio::TimerWatcher
    def initialize(topic, broker_list, zookeeper_list, consumer_group,
                   interval, format, message_key, add_prefix, add_suffix,
                   router, options)
      @topic = topic
      @callback = method(:consume)
      @format = format
      @message_key = message_key
      @add_prefix = add_prefix
      @add_suffix = add_suffix
      @router = router

      kafka = Kafka.new(seed_brokers: broker_list)

      @consumer = kafka.consumer(group_id: consumer_group)
      @consumer.subscribe(topic )

      $log.info "TopicWatcher: Subscribed to topic #{topic}"
      # It's possible to subscribe to multiple topics by calling `subscribe`
      # repeatedly.
      # @consumer.subscribe(topic)

      super(interval, true)
    end

    def on_timer
      @callback.call
    rescue
        # TODO log?
        $log.error $!.to_s
        $log.error_backtrace
    end

    def consume
      es = MultiEventStream.new
      tag = @topic
      tag = @add_prefix + "." + tag if @add_prefix
      tag = tag + "." + @add_suffix if @add_suffix

      $log.info "consume: Will check messages #{@topic}"

      # This will loop indefinitely, yielding each message in turn.
      @consumer.each_message do |message|
        begin
          msg_record = parse_line(message.value)
          es.add(Engine.now, msg_record)
        rescue
          $log.warn msg_record.to_s, :error=>$!.to_s
          $log.debug_backtrace
        end
      end

      unless es.empty?
        @router.emit_stream(tag, es)
      end
    end

    def parse_line(record)
      case @format
      when 'json'
        Yajl::Parser.parse(record)
      when 'ltsv'
        LTSV.parse(record)
      when 'msgpack'
        MessagePack.unpack(record)
      when 'text'
        {@message_key => record}
      end
    end
  end
end

end
