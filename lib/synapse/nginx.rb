require 'fileutils'

module Synapse
  class Nginx
    include Logging
    attr_reader :opts, :name
    
    def initialize(opts)
      @opts = opts
      @name = 'nginx'
      log.info "nginx opts are #{@opts}"
      options = [
        "backend_conf_file",
        "do_backend_conf_softlink",
        "backend_conf_softlink"    
      ].freeze

      %w{backend_conf_file}.each do |req|
        raise ArgumentError, "nginx requires #{req}" if !opts.has_key?(req)
      end

      req_pairs = {
        'do_writes' => 'backend_conf_file',
        'do_reloads' => 'reload_command',
        'do_backend_conf_softlink' => 'backend_conf_softlink'
      }
      
      req_pairs.each do |cond,req|
        if opts[cond]
          raise ArgumentError, "the #{req} option is required when #{cond} is true" unless opts[req]
        end
      end
      
      @opts['do_writes'] = true unless @opts.key?('do_writes')
      @opts['do_reloads'] = true unless @opts.key?('do_reloads')

      
      # how to restart nginx
      @restart_interval = @opts.fetch('restart_interval', 2).to_i
      @restart_jitter = @opts.fetch('restart_jitter', 0).to_f
      @restart_required = true
    
      # virtual clock bookkeeping for controlling how often nginx restarts
      @time = 0
      @next_restart = @time
    
      # a place to store the parsed haproxy config from each watcher
      @watcher_configs = {}            
    end

    def tick(watchers)
      @time += 1

      # We potentially have to restart if the restart was rate limited
      # in the original call to update_config
      restart if @opts['do_reloads'] && @restart_required  
    end

    # update the configuration of nginx
    def update_config(watchers)
      # if we support updating backends, try that whenever possible
      if @opts['do_socket']
        update_backends(watchers)
      else
        @restart_required = true
      end
      
      # generate new config
      new_config = generate_config(watchers)
      new_config = new_config.flatten.join("\n")
      
      # if we write config files, lets do that and then possibly restart
      if @opts['do_writes']
        write_config(new_config)
        restart if @opts['do_reloads'] && @restart_required
      end
    end

    # generates the configuration for updating
    def generate_config(watchers)
      upstream_stanza = []
      location_stanza = []
      server_stanza = []
      watchers.each do |watcher|
        # if service doesnt has nginx block, skip it
        next unless watcher.nginx 
        log.info "#{watcher.name} - #{watcher.backends} - #{watcher.haproxy} - #{watcher.nginx}"
        @watcher_configs[watcher.name] = parse_watcher_config(watcher)
        log.info @watcher_configs
        upstream_stanza << generate_upstream_stanza(watcher, @watcher_configs[watcher.name]['upstream']) 
        location_stanza << generate_location_stanza(watcher,@watcher_configs[watcher.name]['location'])
      end
      base_server_config = get_server_base_config
      server_stanza = generate_server_stanza(location_stanza,base_server_config)
      final_config = upstream_stanza << server_stanza 
      log.info "config array is #{final_config}"

      return final_config
    end


    def write_config(new_config)
      generate_symlink
      begin
        old_config = File.read(@opts['backend_conf_file'])
      rescue Errno::ENOENT => e
        log.info "synapse: could not open the nginx config file at #{@opts['backend_conf_file']}"
        old_config = ""
      end

      if old_config == new_config
        return false
      else
        log.info "writing new content to file"
        File.open(@opts['backend_conf_file'],'wt'){|f| 
          f.write(new_config)
        }
        return true
      end
    end

    # restarts nginx if the time is right
    def restart
      if @time < @next_restart
      log.info "synapse: at time #{@time} waiting until #{@next_restart} to restart"
      return
      end

      @next_restart = @time + @restart_interval
      @next_restart += rand(@restart_jitter * @restart_interval + 1)

      # do the actual restart
      res = `#{opts['reload_command']}`.chomp
      unless $?.success?
      log.error "failed to reload haproxy via #{opts['reload_command']}: #{res}"
      return
      end
      log.info "synapse: restarted nginx"

      @restart_required = false
    end

    # generate upstream and location sections
    def parse_watcher_config(watcher)
      config = Hash.new{|config,key| config[key]=Hash.new(&config.default_proc) } 
      # generate upstream sections
      config["upstream"]["name"] = watcher.name
      config["upstream"]["backends"] = watcher.backends
      config["upstream"]["options"] = watcher.nginx["upstream_options"] || []
      

      # generate location section
      config["location"]["name"] = watcher.nginx["location"] || ""
      config["location"]["options"] = watcher.nginx["location_options"] || []
      
      return config 
    end

    # get the static server block 
    def get_server_base_config
      backend_conf = @opts['backend_conf'] || {}
      return backend_conf
    end

    def generate_location_stanza(watcher,config)
      unless watcher.nginx.has_key?("location_block")
        log.warn "synapse: not generating the frontend config for watcher #{watcher.name} because it has no location defined"
        return []
      end
      stanza = []
      location_block = watcher.nginx["location_block"]
      location_block.each do |block|
        stanza << [
          "\n\tlocation #{block['location']} {",
          "\t\t#{block['proxy_pass']}" % [watcher.name],
          block["location_options"].map { |c|
            "\t\t#{c}" % [watcher.name]
          },
          "\t}"
        ]
      end
      return stanza
    end
    
    #TODO: check for server and listen options
    def generate_server_stanza(location_stanza,base_server_config)
      if base_server_config.empty?
        log.warn "synapse: not generating the frotnend config for nginx because it has no server key in nginx in synapse config"
        return []
      end
      stanza = [
        "\nserver {",
        "\tserver_name #{base_server_config["server_name"]};",
        base_server_config["server"].map { |c|
          "\t#{c}"
        },
        location_stanza,
        "}"
      ]
      return stanza
    end

    def generate_upstream_stanza(watcher,config)
      backends = {}

      watcher.backends.each do |backend|
        backend_name = construct_name(backend)
        backends[backend_name] = backend.merge('enabled' => true)
      end
      log.info "backends are #{backends}"

      if watcher.backends.empty?
        log.info "synapse: no backends found for watcher #{watcher.name}"
      end

      stanza = [
        "\nupstream #{watcher.name} {",
        backends.keys.map {|backend_name|
          backend = backends[backend_name]
          b = "\tserver #{backend['host']}:#{backend['port']};"
          b
        },
        config["options"].map {
          |c| "\t#{c}"
        },
        "}"
      ]
      log.info "stanza is #{stanza}"
      
      return stanza
    end

    def construct_name(backend)
      name = "#{backend['host']}:#{backend['port']}"
      if backend['name'] && !backend['name'].empty?
        name = "#{backend['name']}_#{name}"
      end

      return name    
    end

    def generate_symlink
      if @opts['do_backend_conf_softlink']
        unless @opts.has_key?('backend_conf_softlink') && File.exist?(@opts['backend_conf_softlink']) && File.symlink?(@opts['backend_conf_softlink'])
          log.info "Creating the symlink file"
          File.symlink(@opts['backend_conf_file'],@opts['backend_conf_softlink'])
        end
      end
    end
  end
end

