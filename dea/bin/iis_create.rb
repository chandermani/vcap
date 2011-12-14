#!/usr/bin/env ruby -w

require 'yajl'
require 'tempfile'
require 'fileutils'

meta_instance_file = ARGV[0]

meta_instance = nil
if File.exists?(meta_instance_file)
  File.open(meta_instance_file, 'r') { |f| meta_instance = Yajl::Parser.parse(f) }
else
  exit 1
end

$out = Tempfile.new(['iis_create_', '.out'])
$out.close

$winpath = $out.path.gsub(File::SEPARATOR, File::ALT_SEPARATOR || File::SEPARATOR)

def run_appcmd(cmd, check_rval=true)
  syscmd = "#{cmd} >> #{$winpath} 2>&1"
  tries = 0
  rval = false
  while tries < 5
    rval = system(syscmd)
    if (rval)
      return
    else
      sleep 2
      tries += 1
    end
  end
  unless check_rval && rval
    $out.open('w') do |f|
      f.puts("ERROR: #{$?} : #{syscmd}")
    end
    exit false
  end
end

begin
  dea_appcmd  = meta_instance['dea_appcmd']
  log_path    = meta_instance['log_path']
  instance    = meta_instance['instance']
  app_env     = meta_instance['app_env']
  services    = meta_instance['services']
  mem         = meta_instance['mem']

  site_name = instance['win_site_name']
  site_port = instance['port']
  site_path = instance['win_site_path']
  log_path  = instance['win_log_path']

  mem_kbytes = (mem * 1024).to_i

  cmd = "#{dea_appcmd} add apppool /name:#{site_name}"
  run_appcmd(cmd)

  cmd = "#{dea_appcmd} set apppool #{site_name} /autoStart:true /managedRuntimeVersion:v4.0 /managedPipelineMode:Integrated /recycling.periodicRestart.privateMemory:#{mem_kbytes}"
  run_appcmd(cmd)

  cmd = "#{dea_appcmd} add site /name:#{site_name} /bindings:http/*:#{site_port}: /physicalPath:#{site_path}"
  run_appcmd(cmd)

  cmd = "#{dea_appcmd} set site #{site_name} /[path='/'].applicationPool:#{site_name}"
  run_appcmd(cmd)

  if not app_env.nil?
    app_env.each do |env|
      key, value = env.split('=', 2)

      # TODO T3CF determine better way to figure out if it's JSON
      # delete leading/trailing quotes
      value.sub!(/^["']/, '') if not value.nil?
      value.sub!(/["']$/, '') if not value.nil?
      value.gsub!(/"/, '\"') if not value.nil? # Escape embedded quotes

      cmd = %Q|#{dea_appcmd} set config #{site_name} /commit:site /section:appSettings "/-[key='#{key}']"|
      run_appcmd(cmd, false)

      cmd = %Q|#{dea_appcmd} set config #{site_name} /commit:site /section:appSettings "/+[key='#{key}',value='#{value}']"|
      run_appcmd(cmd)
    end
  end
  if not services.nil?
    services.each do |service|
      service_vendor = service['vendor']
      if service_vendor == 'mssql' # TODO T3CF
        hostname = service['credentials']['hostname'] || service['credentials']['host']
        port     = service['credentials']['port'] || 1433
        user     = service['credentials']['username'] || service['credentials']['user']
        password = service['credentials']['password']

        cmd = "#{dea_appcmd} set config #{site_name} /commit:site /section:connectionStrings /-[name='Default']"
        run_appcmd(cmd, false)

        conn_str = "server=#{hostname},#{port};uid=#{user};pwd=#{password};trusted_connection=false;" # TODO application name, other settings?
        cmd = "#{dea_appcmd} set config #{site_name} /commit:site /section:connectionStrings /+[name='Default',connectionString='#{conn_str}']"
        run_appcmd(cmd, false)
        break # only set one conn str TODO T3CF
      end
    end
  end
  true
ensure
  File.delete(meta_instance_file)
  FileUtils.mv($out.path, log_path + '/stdout.log')
end
