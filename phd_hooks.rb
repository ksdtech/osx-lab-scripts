#!/usr/bin/ruby

# phd_hook.rb 

# Login and shutdown script for Mac OS X 10.4 to do two things:
#   1. Redirect network users' ~/Library/Caches folder to the local hard disk
#      for better performance, and
#   2. Expire (remove) portable home directories on lab computers after 
#      a period of inactivity (default to 30 days)

# The cache folder part is adapted from a shell script by Nigel Kirsten
# http://lists.apple.com/archives/Macos-x-server/2006/Feb/msg01025.html

# The expiring mobile directories part is adapted from a login hook by 
# Zack Smith
# http://www.afp548.com/article.php?story=20070703021643108

# Rewritten in ruby (because shell scripts make me crazy) by Peter Zingg

# To install, copy this file (using ARD or PackageMaker) to a save place,
# such as /Library/Application Support/LoginHooks, then (using ARD or 
# PackageMaker), then call the script (as root) with the single argument 
# 'installme', e.g.
# sudo "/Library/Application Support/LoginHooks/phd_hook.rb" installme

# The installme invocation will set up the login hook to this file,
# and will create the shell script /etc/rc.shutdown.local,
# called by the system on shutdown.  The rc.shutdown.local script is a one-liner:
# /usr/bin/ruby <path_to_this_file> onshutdown

# To remove, call the script as root with the argument 'removeme', e.g.
# sudo "/Library/Application Support/LoginHooks/phd_hook.rb" removeme

# File names
LOGIN_FILE = '.lastlogin'
SHUTDOWN_SCRIPT = '/etc/rc.shutdown.local'

# It should be safe to use the /Search node, as that section of the script 
# shouldn't be  running for any local or mobile users, but Nigel prefers 
# to hardwire it as "/LDAPv3/your.od.domain".
# LDAP_SEARCH_NODE = '/Search'
LDAP_SEARCH_NODE = '/LDAPv3/10.4.51.70'
LOCAL_NODE = '.'

# List of logins that will NEVER be deleted or timestamped.
EXCLUDED_USERS = [ 'localadm', 'serveradm', 'bacich', 'kent' ]

# Set to true if you want to check for expiration on every login.
EXPIRE_ON_LOGIN = false 

# Expiration date for mobile accounts. Set to '-1' for testing (all mobile users).
EXPIRE_AFTER_DAYS = '+30' 

# Set to false to just echo commands that would be run.
# Test on a non-production machine before setting this to true!
GOOD_TO_GO = true 

require 'etc'

def logger(s)
  puts s
end

def perform(s)
  if GOOD_TO_GO
    system(s)
  else
    logger(s)
  end
end

unless ARGV.size > 0
  logger "LoginHook: No username supplied."
  exit 1 
end
USERNAME = ARGV[0].downcase
if USERNAME.empty?
  logger "LoginHook: Username is blank."
  exit 1
end

def user_type(username)
  if EXCLUDED_USERS.include? USERNAME
    'excluded'
  else
    lookup_local = ''
    IO.popen("/usr/bin/niutil -read . /users/#{USERNAME} 2> /dev/null") do |io|
      lookup_local = io.readline.chomp rescue ''
    end

    if lookup_local.empty?
      'network'
    else
      auth_prop = ''
      # This will grab local and mobile users, as they're both strictly 'local' users.
      IO.popen("/usr/bin/niutil -readprop . /users/#{USERNAME} authentication_authority 2> /dev/null") do |io|
        auth_prop = io.readline.chomp rescue ''
      end

      case auth_prop 
      when /LocalCachedUser/
        'mobile'
      else
        'local'
      end
    end
  end
end

def last_sync_time(username)
  last_sync = nil
  IO.popen("/usr/bin/find /Users/#{username}/Library/Mirrors -name \"djmirror.db.*\" -maxdepth 2") do |io|
    last_sync = File.stat(io.readline.chomp).mtime
  end
  logger "last sync in ~/Library/Mirrors is #{last_sync}"
end

def user_home_directory(directory_node, username)
  home_dir = ''
  IO.popen("/usr/bin/dscl #{directory_node} -read /Users/#{username} NFSHomeDirectory") do |io|
    home_dir = io.readline.chomp.gsub(/^NFSHomeDirectory: /, '') rescue ''
  end
  home_dir
end

def timestamp_mobile_user_login(username)
  home_dir = user_home_directory(LOCAL_NODE, username)
  logger "LoginHook: Timestamping login for mobile account #{username}, home directory #{home_dir}"
  system("/usr/bin/sudo -u #{username} echo #{username} > #{home_dir}/#{LOGIN_FILE}")
end

def redirect_network_user_caches_folder(username)
  home_dir = user_home_directory(LDAP_SEARCH_NODE, username)

  # Do your stuff for network users here.
  logger "LoginHook: Redirecting caches for network account #{username}, home directory #{home_dir}"
  perform "/bin/mkdir -p /Library/Caches/#{username}" 
  perform "/usr/sbin/chown #{username} /Library/Caches/#{username}" 
  perform "/usr/bin/sudo -u #{username} /bin/chmod 700 /Library/Caches/#{username}" 
  perform "/usr/bin/sudo -u #{username} /bin/rm -rf #{home_dir}/Library/Caches" 
  perform "/usr/bin/sudo -u #{username} /bin/ln -s /Library/Caches/#{username} #{home_dir}/Library/Caches"
end

# This can be called at shutdown, a la Mr. Smith's package
# Or with the "user_logging_in" parameter set to exclude the current user
def remove_expired_mobile_users(expire_after, user_logging_in = nil)
  logger "Expiration: Searching for expired users #{expire_after} days"
  stale_files = []
  IO.popen("/usr/bin/find /Users -name #{LOGIN_FILE} -maxdepth 2 -mtime #{expire_after}") do |io|
    stale_files = io.readlines rescue []
  end
  stale_files.each do |file_line|
    mod_file = file_line.chomp
    file_dir = mod_file[0,mod_file.length-(LOGIN_FILE.length+1)]
    username = File.read(mod_file).chomp
    utype = user_type(username)
    if utype != 'mobile'
      logger "Expiration: Skipping #{file_dir}: not a mobile user: #{utype}"
      next
    end
    if !user_logging_in.nil?
      home_dir = user_home_directory(LOCAL_NODE, user_logging_in)
      if home_dir == file_dir
        logger "Expiration: Skipping #{file_dir}: home for current login"
        next
      end
    end
    home_dir = user_home_directory(LOCAL_NODE, usernmae)
    if home_dir == file_dir
      last_login = File.stat(mod_file).ctime
      logger "Expiration: Removing #{home_dir}: last login #{last_login}"
      
      # We sudo the rm -rf command as the user (failsafe) which will get rid of the 
      # contents of the directory but not the directory itself.
      perform "/usr/bin/sudo -u #{username} /bin/rm -rf #{home_dir}"
      perform "/bin/rmdir #{home_dir}"
      if File.directory? home_dir
        logger "Expiration: Home directory #{home_dir} could not be removed"
        perform "/bin/mv -f #{home_dir} #{home_dir}.error"
      end 
    end
  end
end

def user_login_hook(username)
  utype = user_type(username)
  case utype
  when 'excluded'
    logger "LoginHook: Skipping checks for special user - #{username}"
  when 'mobile'
    # Do your stuff for mobile users here.
    timestamp_mobile_user_login(username)
  when 'local'
    # Do your stuff for local users here.
  when 'network'
    # Do your stuff for network users here.
    redirect_network_user_caches_folder(username)
  else
    logger "LoginHook: Unknown account type #{username}"
  end
  
  remove_expired_mobile_users(EXPIRE_AFTER_DAYS, username)
  logger "LoginHook: Finished for #{username}"
  exit 0
end

def create_shutdown_script(path_to_script)
  if GOOD_TO_GO
    File.open(SHUTDOWN_SCRIPT, "w") do |f|
      f.write("\#!/bin/bash\n/usr/bin/ruby #{path_to_script} onshutdown\n")
    end
  end
  perform "/bin/chmod 700 #{SHUTDOWN_SCRIPT}"
end

def install_this_hook
  current_hook = ''
  IO.popen("/usr/bin/defaults read /private/var/root/Library/Preferences/com.apple.loginwindow LoginHook 2>/dev/null") do |io|
    current_hook = io.readline.chomp rescue ''
  end
  my_path = File.expand_path(__FILE__)
  if current_hook == ''
    logger "InstallHook: Installing login hook"
    perform "/bin/chmod 700 #{my_path}"
    perform "/usr/bin/defaults write /private/var/root/Library/Preferences/com.apple.loginwindow LoginHook \"#{my_path}\""
 
    logger "InstallHook: Installing shutdown script"
    create_shutdown_script(my_path)
  elsif current_hook == my_path
    logger "InstallHook: Already installed"
  else
    logger "InstallHook: Another login hook installed: #{current_hook}"
  end
end

def remove_any_login_hook
  current_hook = ''
  IO.popen("/usr/bin/defaults read /private/var/root/Library/Preferences/com.apple.loginwindow LoginHook 2>/dev/null") do |io|
    current_hook = io.readline.chomp rescue ''
  end
  if current_hook != ''
    logger "RemoveHook: Removing existing login hook"
    perform "/usr/bin/defaults delete /private/var/root/Library/Preferences/com.apple.loginwindow LoginHook"
  else
    logger "RemoveHook: Nothing to remove"
  end
  
  logger "RemoveHook: Removing shutdown script"
  perform "/bin/rm -f #{SHUTDOWN_SCRIPT}"
end

case USERNAME
when 'installme'
  install_this_hook
when 'removeme'
  remove_any_login_hook
when 'onshutdown'
  remove_expired_mobile_users(EXPIRE_AFTER_DAYS)
else
  user_login_hook(USERNAME)
end
