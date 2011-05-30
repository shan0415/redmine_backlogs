require 'fileutils'

namespace :redmine do
  namespace :backlogs do 

    desc "Install and configure Redmine Backlogs"
    task :install => :environment do |t|
      ENV["RAILS_ENV"] ||= "development"

      ['open-uri/cached', 'holidays', 'icalendar', 'prawn'].each{|gem|
        begin
          require gem
        rescue LoadError
          raise "You are missing the '#{gem}' gem"
        end
      }

      batch = (ENV['batch'] == 'true')
      corruption_test = (ENV['corruptiontest'] != 'false')

      redmine_supported = "1.2.0"

      platform = nil
      version = nil
      File.open('doc/CHANGELOG').each_line do |line|
        break if platform && version

        platform = :redmine if line.match(/^== Redmine changelog$/)
        
        m = line.match(/^== [0-9]{4}-[0-9]{2}-[0-9]{2} v([.0-9]+)$/)
        version = m[1] if m
      end

      raise "Only Redmine version #{redmine_supported} is supported at this time" unless platform == :redmine && version == redmine_supported

      begin
        Story.trackers
      rescue NoMethodError
        raise "Looks like there's a conflicting plugin that redefines the Story class"
      end

      if !corruption_test
        puts "Assuming no database corruption"
      else
        issues = []
        puts "Testing #{Issue.count(:all)} issues for database corruption..."
        Issue.all.each_with_index do |issue, i|
          puts i + 1 if ((i+1) % 100) == 0
          begin
            issue.save!
          rescue => e
            issues << [issue.id, "#{e}"]
          end
        end
        if issues.size == 0
          puts "Database OK!"
        else
          puts "The following issues have problems (how ironic is that?):"
          issues.each do |issue|
            puts "* #{issue[0]}: #{issue[1]}"
          end
        end
      end

      # Necessary because adding key-value pairs one by one doesn't seem to work
      settings = Setting.plugin_redmine_backlogs
      settings[:points_burn_direction] ||= 'down'
      settings[:wiki_template]         ||= ''

      puts "\n"
      puts "====================================================="
      puts "             Redmine Backlogs Installer"
      puts "====================================================="
      puts "Installing to the #{ENV['RAILS_ENV']} environment."

      if ! ['no', 'false'].include?("#{ENV['labels']}".downcase)
        print "Fetching card labels from http://git.gnome.org..."
        STDOUT.flush
        begin
          BacklogsCards::LabelStock.fetch_labels
          print "done!\n"
        rescue Exception => fetch_error
          print "\nCard labels could not be fetched (#{fetch_error}). Please try again later. Proceeding anyway...\n"
        end
      else
        if ! File.exist?(File.dirname(__FILE__) + '/../labels.yaml')
          print "Default labels installed\n"
          FileUtils.cp(File.dirname(__FILE__) + '/../labels.yaml.default', File.dirname(__FILE__) + '/../labels.yaml')
        end
      end
      settings[:card_spec] ||= BacklogsCards::LabelStock::LAYOUTS.keys[0] unless BacklogsCards::LabelStock::LAYOUTS.size == 0

      trackers = Tracker.find(:all)

      if !batch && Story.trackers.length == 0
        puts "Configuring story and task trackers..."
        invalid = true
        while invalid
          puts "-----------------------------------------------------"
          puts "Which trackers do you want to use for your stories?"
          trackers.each_with_index { |t, i| puts "  #{ i + 1 }. #{ t.name }" }
          print "Separate values with a space (e.g. 1 3): "
          STDOUT.flush
          selection = (STDIN.gets.chomp!).split(/\D+/)
          
          # Check that all values correspond to an items in the list
          invalid = false
          invalid_value = nil
          tracker_names = []
          selection.each do |s|
            if s.to_i > trackers.length
              invalid = true
              invalid_value = s
              break
            else
              tracker_names << trackers[s.to_i-1].name
            end
          end
        
          if invalid
            puts "Oooops! You entered an invalid value (#{invalid_value}). Please try again."
          else
            print "You selected the following trackers: #{tracker_names.join(', ')}. Is this correct? (y/n) "
            STDOUT.flush
            invalid = !(STDIN.gets.chomp!).match("y")
          end
        end

        settings[:story_trackers] = selection.map{ |s| trackers[s.to_i-1].id }
      end

      
      if !batch && !Task.tracker
        # Check if there is at least one tracker available
        puts "-----------------------------------------------------"
        if settings[:story_trackers].length < trackers.length
          invalid = true
          while invalid
            # If there's at least one, ask the user to pick one
            puts "Which tracker do you want to use for your tasks?"
            available_trackers = trackers.select{|t| !settings[:story_trackers].include? t.id}
            j = 0
            available_trackers.each_with_index { |t, i| puts "  #{ j = i + 1 }. #{ t.name }" }
            # puts "  #{ j + 1 }. <<new>>"
            print "Choose one from above (or choose none to create a new tracker): "
            STDOUT.flush
            selection = (STDIN.gets.chomp!).split(/\D+/)
                  
            if selection.length > 0 and selection.first.to_i <= available_trackers.length
              # If the user picked one, use that
              print "You selected #{available_trackers[selection.first.to_i-1].name}. Is this correct? (y/n) "
              STDOUT.flush
              if (STDIN.gets.chomp!).match("y")
                settings[:task_tracker] = available_trackers[selection.first.to_i-1].id
                invalid = false
              end
            # elsif selection.length == 0 or selection.first.to_i == j + 1
            #   # If the user chose to create a new one, then ask for the name
            #   settings[:task_tracker] = create_new_tracker
            #   invalid = false
            else
              puts "Oooops! That's not a valid selection. Please try again."
            end
          end
        else
          # If there's none, ask to create one
          # settings[:task_tracker] = create_new_tracker
          puts "You don't have any trackers available for use with tasks."
          puts "Please create a new tracker via the Redmine admin interface,"
          puts "then re-run this installer. Press any key to continue."
          STDOUT.flush
          STDIN.gets
        end
      end

      # Necessary because adding key-value pairs one by one doesn't seem to work
      Setting.plugin_redmine_backlogs = settings
      
      puts "Story and task trackers are now set."
      
      print "Migrating the database..."
      STDOUT.flush
      system('rake db:migrate_plugins --trace > redmine_backlogs_install.log')
      if $?==0
        puts "done!"
        puts "Installation complete. Please restart Redmine."
        puts "Thank you for trying out Redmine Backlogs!"
      else
        puts "ERROR!"
        puts "*******************************************************"
        puts " Whoa! An error occurred during database migration."
        puts " Please see redmine_backlogs_install.log for more info."
        puts "*******************************************************"
      end
    end
    
    def create_new_tracker
      repeat = true
      puts "Creating a new task tracker."
      while repeat
        print "Please type the tracker's name: "
        STDOUT.flush
        name = STDIN.gets.chomp!
        if Tracker.find(:first, :conditions => "name='#{name}'")
          puts "Ooops! That name is already taken."
          next
        end
        print "You typed '#{name}'. Is this correct? (y/n) "
        STDOUT.flush
        
        if (STDIN.gets.chomp!).match("y")
          tracker = Tracker.new(:name => name)
          tracker.save!
          repeat = false
        end
      end
      tracker.id
    end
  end
end
