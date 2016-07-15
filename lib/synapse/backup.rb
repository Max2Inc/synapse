require 'fileutils'
require 'erb'
require 'pp'

module Synapse
  class Backup
    include Logging
    attr_reader :opts, :name

    def initialize(opts)
      super()

      @name = "backup"
      log.info "#{@name} opts are #{@opts}"

      %w{run_command}.each do |req|
        raise ArgumentError, "#{@name} requires a #{req} section" if !opts.has_key?(req)
      end

      req_pairs = {
      }

      req_pairs.each do |cond, req|
        if opts[cond]
          raise ArgumentError, "the `#{req}` option is required when `#{cond}` is true" unless opts[req]
        end
      end

      @opts = opts

      @opts['do_cron'] = true unless @opts.key?('do_cron')

      # how to rerun backup
      @restart_interval = @opts.fetch('restart_interval', 2).to_i
      @restart_jitter = @opts.fetch('restart_jitter', 0).to_f
      @restart_required = true

      # virtual clock bookkeeping for controlling how often rerun backup
      @time = 0
      @next_restart = @time

      # a place to store the parsed haproxy config from each watcher
      @watcher_configs = {}
    end

    def tick(watchers)
      @time += 1
    end

    # update the configuration of backup
    def update_config(watchers)
      # if we support updating backends, try that whenever possible
      if @opts['do_socket']
        update_backends(watchers)
      else
        @restart_required = true
      end

      # generate a new config
      generate_config(watchers)

    end 

    # generates the configuration for updating
    def generate_config(watchers)
      watchers.each do |watcher|
        # if service doesnt have backup block, skip it
        next unless watcher.backup
        log.info "#{watcher.name} - #{watcher.backends} - #{watcher.haproxy} - #{watcher.backup}"
        
        @watcher_configs[watcher.name] = parse_watcher_config(watcher)
        backup_conf_file = watcher.backup['backup_conf_file']
        cron_conf_file = watcher.backup['cron_conf_file']
        types = watcher.backends[0]['backup']
        gzip = watcher.backup['gzip']
        name = watcher.name

        # generate backup config
        databases_stanza = generate_stanza("#{types['databases']['type']}.erb", @watcher_configs[watcher.name]['databases'])
        storages_stanza = generate_stanza("#{types['storages']['type']}.erb", @watcher_configs[watcher.name]['storages'])
        notifiers_stanza = generate_stanza("#{types['notifiers']['type']}.erb", @watcher_configs[watcher.name]['notifiers'])
        final_config = generate_backup(name, databases_stanza, storages_stanza, notifiers_stanza, gzip)
        log.info "config array is #{final_config}"

        write_config(final_config, backup_conf_file)

        # generate cron job config 
        run_command = "#{@opts['run_command']} --config-file #{@opts['config_file']} --trigger #{name}"
        cron_config = "#{watcher.backup['cron']} #{run_command} > /dev/null 2>&1"

        if @opts['do_cron']
          write_config(cron_config, cron_conf_file)
        end
      end
    end

    def write_config(new_config, conf_file)
      begin
        #old_config = File.read(@opts['backup_conf_file'])
        old_config = File.read(conf_file)
      rescue Errno::ENOENT => e
        log.info "synapse: could not open the config file at #{@opts['backup_conf_file']}"
        old_config = ""
      end

      if old_config == new_config
        return false
      else
        log.info "writing new content to file"
        File.open(conf_file, 'wt'){|f| 
          f.write(new_config)
        }
        return true
      end
    end
 
    def restart
      if @time < @next_restart
      log.info "synapse: at time #{@time} waiting until #{@next_restart} to restart"
      return
      end

      @next_restart = @time + @restart_interval
      @next_restart += rand(@restart_jitter * @restart_interval + 1)

      # do the actual restart
      res = `#{opts['run_command']}`.chomp
      unless $?.success?
        log.error "failed to rerun backup via #{opts['run_command']}: #{res}"
        return
      end
      log.info "synapse: rerun backup"

      @restart_required = false
    end

    def parse_watcher_config(watcher)
      config = Hash.new{|config,key| config[key]=Hash.new(&config.default_proc) } 
      # generate database sections
      config['databases'] = watcher.backends[0]['backup']['databases']
      config['storages'] = watcher.backends[0]['backup']['storages']
      config['notifiers'] = watcher.backends[0]['backup']['notifiers']

      # generate location section
      #config["location"]["name"] = watcher.nginx["location"] || ""
      #config["location"]["options"] = watcher.nginx["location_options"] || []
      #
      return config 
    end

    def generate_stanza(template_file, config)
      current_dir = File.dirname(__FILE__)
      template_dir = "template/backup"
      template = "#{current_dir}/#{template_dir}/#{template_file}"
      
      erb = ERB.new(File.read(template))
      stanza = erb.result(binding)

      return stanza
    end

    def generate_backup(name, databasase_stanza, storages_stanza, notifiers_stanza, gzip)
      current_dir = File.dirname(__FILE__)
      template_dir = "template/backup"
      template = "#{current_dir}/#{template_dir}/backup.erb"
 
      erb = ERB.new(File.read(template))
      stanza = erb.result(binding)

      return stanza
    end
  end
end
