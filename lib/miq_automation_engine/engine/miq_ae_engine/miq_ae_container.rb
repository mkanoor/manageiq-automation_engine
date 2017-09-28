module MiqAeEngine
  class MiqAeContainer
    def initialize(aem, obj, inputs, bodies, script_info)
      @workspace = obj.workspace
      @inputs    = inputs
      @aem       = aem
      @rest_server = "http://my.rest.com:4000/api"
      @aw = AutomateWorkspace.create(:input  => serialize_workspace(inputs),
                                     :user   => @workspace.ae_user,
                                     :tenant => @workspace.ae_user.current_tenant)
      @contents = build_method_content(bodies, aem.name, @aw.guid, script_info)
    end

    def run
      run_using_docker
    end

    def run_using_orchestrator
      env = {
        'api_token' => Api::UserTokenService.new.generate_token(@workspace.ae_user.userid, 'api'),
        'api_url'   => MiqRegion.my_region.remote_ws_url,
        'guid'      => @aw.guid,
        'MIQ_SCRIPT' => @contents
      }
      co = ContainerOrchestrator.new()
      id = co.run_pod("#{@aem.name}_#{Time.now.to_s}",@inputs["image_name"],env,@inputs["command"])
      while co.pod_running?(id) do
        sleep(1)
      end
      exit_code = co.pod_return_code(id)
      $miq_ae_logger.info("Container Method Ended with exit code #{exit_code}")
      @aw.reload
      @workspace.update_workspace(aw.output)
    end

    def run_using_docker
      env = {
        'api_token'  => Api::UserTokenService.new.generate_token(@workspace.ae_user.userid, 'api'),
        'api_url'    => MiqRegion.my_region.remote_ws_url,
        'guid'       => @aw.guid,
        'MIQ_SCRIPT' => @contents,
        'miq_group'  => @workspace.ae_user.current_group.description
      }
      my_script = 'MIQ_SCRIPT=' +  @contents.unpack('H*').first
      params = []
      params << "run"
      params << "--add-host"
      params << "my.rest.com:172.16.222.111"
      params << "-v"
      params << "/tmp/junk:/junk"
      params << "-e"
      params << my_script
      params << "mkanoor/ruby"
      params << "bundle"
      params << "exec"
      params << "ruby"
      params << "/usr/app/runner.rb"
     # params << "-e"
     # params << %q{eval(ENV["MIQ_SCRIPT"])}
      ActiveRecord::Base.connection_pool.release_connection
      x = AwesomeSpawn.run("docker", :params => params)
      $miq_ae_logger.info("Container Method Ended with exit code #{x.exit_status}")
      if x.success?
        $miq_ae_logger.error("Container Method Ended with success #{x.output}")
        @aw.reload
        @workspace.update_workspace(@aw.output)
      else
        $miq_ae_logger.error("Container Method Ended with error #{x.error}")
      end
    end

    private 
    def serialize_workspace(inputs)
      {'workspace'         => @workspace.hash_workspace,
       'method_parameters' => MiqAeReference.encode(inputs),
       'current'           => current_info(@workspace),
       'state_vars'        => MiqAeReference.encode(@workspace.persist_state_hash)}
    end 
  
    def current_info(workspace)
      list = %w(namespace class instance message method)
      list.each.with_object({}) { |m, hash| hash[m] = workspace.send("current_#{m}".to_sym) }
    end 

    # code building
    def build_method_content(bodies, method_name, guid, script_info)
      [
        dynamic_preamble(method_name, guid, script_info),
        RUBY_METHOD_PREAMBLE,
        bodies,
        RUBY_METHOD_POSTSCRIPT
      ].flatten.join("\n")
    end

    def dynamic_preamble(method_name, workspace_guid, script_info)
      script_info_yaml = script_info.to_yaml
      <<~RUBY.chomp
        MIQ_URI = '#{@rest_server}'
        MIQ_GUID = '#{workspace_guid}'
        MIQ_GROUP = '#{@workspace.ae_user.current_group.description}'
        RUBY_METHOD_NAME = '#{method_name}'
        SCRIPT_INFO_YAML = '#{script_info_yaml}'
        RUBY_METHOD_PREAMBLE_LINES = #{RUBY_METHOD_PREAMBLE_LINES + 5 + script_info_yaml.lines.count}
      RUBY
    end

    RUBY_METHOD_PREAMBLE = <<~RUBY.chomp.freeze
      class AutomateMethodException < StandardError
      end
  
      begin
        require 'date'
        require 'rubygems'
        require 'yaml'
  
        MIQ_OK    = 0
        MIQ_WARN  = 4
        MIQ_ERROR = 8
        MIQ_STOP  = 8
        MIQ_ABORT = 16

        # Setup stdout and stderr to go through the logger on the MiqAeService instance ($evm)
        # silence_warnings { STDOUT = $stdout = $evm.stdout ; nil}
        # silence_warnings { STDERR = $stderr = $evm.stderr ; nil}

      rescue Exception => err
        STDERR.puts('The following error occurred during inline method preamble evaluation:')
        STDERR.puts("  \#{err.class}: \#{err.message}")
        STDERR.puts("  \#{err.backtrace.join('\n')}") unless err.kind_of?(AutomateMethodException)
        raise
      end

      class Exception
        def filter_backtrace(callers)
          return callers unless callers.respond_to?(:collect)
  
          callers.collect do |c|
            file, line, context = c.split(':')
            if file == "-"
              fqname, line = get_file_info(line.to_i - RUBY_METHOD_PREAMBLE_LINES)
              [fqname, line, context].join(':')
            else
              c
            end
          end
        end

        def backtrace_with_evm
          value = backtrace_without_evm
          value ? filter_backtrace(value) : value
        end

        def get_file_info(line)
          script_info = YAML.load(SCRIPT_INFO_YAML)
          script_info.each do |fqname, range|
            return fqname, line - range.begin if range.cover?(line)
          end
          return RUBY_METHOD_NAME, line
        end

        alias backtrace_without_evm backtrace
        alias backtrace backtrace_with_evm
      end

      begin
    RUBY

    RUBY_METHOD_PREAMBLE_LINES = RUBY_METHOD_PREAMBLE.lines.count

    RUBY_METHOD_POSTSCRIPT = <<~RUBY.freeze
      rescue Exception => err
      unless err.kind_of?(SystemExit)
        STDERR.puts('The following error occurred during method evaluation:')
        STDERR.puts("  \#{err.class}: \#{err.message}")
        STDERR.puts("  \#{err.backtrace[0..-2].join('\n')}")
      end
      raise
      ensure
      end
    RUBY
  end
end
