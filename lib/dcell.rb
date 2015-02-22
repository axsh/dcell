require 'celluloid'
require 'reel'
require 'celluloid/zmq'
require 'socket'
require 'securerandom'
require 'msgpack'

Celluloid::ZMQ.init

require 'dcell/version'
require 'dcell/utils'
require 'dcell/resource_manager'
require 'dcell/actor_proxy'
require 'dcell/directory'
require 'dcell/messages'
require 'dcell/node_manager'
require 'dcell/node'
require 'dcell/global'
require 'dcell/responses'
require 'dcell/mailbox_manager'
require 'dcell/server'
require 'dcell/info_service'
require 'dcell/registries/adapter'
require 'dcell/registries/errors'

require 'dcell/celluloid_ext'

# Distributed Celluloid
module DCell
  class NotConfiguredError < RuntimeError; end # Not configured yet

  @lock = Mutex.new
  @actors = Set.new

  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    attr_reader :me, :registry

    # Configure DCell with the following options:
    #
    # * id: to identify the local node, defaults to hostname
    # * addr: 0MQ address of the local node (e.g. tcp://4.3.2.1:7777)
    # *
    def setup(options = {})
      # Stringify keys :/
      options = options.inject({}) { |h,(k,v)| h[k.to_s] = v; h }

      @lock.synchronize do
        @configuration = {
          'addr' => "tcp://127.0.0.1:*",
          'heartbeat_rate' => 5,
          'heartbeat_timeout' => 10,
          'async_pool_size' => 50,
        }.merge(options)

        @registry = @configuration['registry']
        raise ArgumentError, "no registry adapter given in config" unless @registry

        @configuration['id'] ||= generate_node_id
        @me = Node.new @configuration['id'], nil
        ObjectSpace.define_finalizer(me, proc {Directory.remove @configuration['id']})
      end

      me
    end

    def add_local_actor(name)
      @lock.synchronize do
        @actors << name.to_sym
      end
    end

    def get_local_actor(name)
      name = name.to_sym
      if @actors.include? name
        return Celluloid::Actor[name]
      end
      nil
    end

    def local_actors
      @actors.to_a
    end

    # Returns actors from multiple nodes
    def find(actor)
      actors = Array.new
      Directory.each do |node|
        next unless node.actors.include? actor
        begin
          actors << Node[node.id][actor]
        rescue Exception => e
          Logger.warn "Failed to get actor '#{actor}' on node '#{node.id}': #{e}"
        end
      end
      actors
    end
    alias_method :[], :find

    def config(option)
      unless @configuration
        Logger.warn "DCell unconfigured, can't get #{option}"
        return nil
      end
      @configuration[option]
    end

    # Obtain the local node ID
    def id
      config 'id'
    end

    # Obtain the 0MQ address to the local mailbox
    def addr
      config 'addr'
    end
    alias_method :address, :addr

    # Updates server address of the node
    def addr=(addr)
      @configuration['addr'] = addr
      Directory[id].address = addr
      @me.update_server_address addr
    end
    alias_method :address=, :addr=

    # Default heartbeat rate for the nodes
    def heartbeat_rate
      config 'heartbeat_rate'
    end

    # Default heartbeat timeout for the nodes
    def heartbeat_timeout
      config 'heartbeat_timeout'
    end

    # Max size of mailbox when processing async messages
    def async_pool_size
      config 'async_pool_size'
    end

    # Attempt to generate a unique node ID for this machine
    def generate_node_id
      # a little bit more creative
      if @registry.respond_to? :unique
        @registry.unique
      else
        digest = Digest::SHA512.new
        seed = Socket.gethostname + rand.to_s + Time.now.to_s + SecureRandom.hex
        digest.update(seed).to_s
      end
    end

    # Run the DCell application in the background
    def run!
      Directory[id].actors = local_actors
      DCell::SupervisionGroup.run!
    end

    # Start combines setup and run! into a single step
    def start(options = {})
      setup options
      run!
    end
  end

  extend ClassMethods

  # DCell's actor dependencies
  class SupervisionGroup < Celluloid::SupervisionGroup
    supervise Server,      :as => :dcell_server, :args => [DCell]
    supervise InfoService, :as => :info
  end
  DCell.add_local_actor :info

  Logger = Celluloid::Logger
end
