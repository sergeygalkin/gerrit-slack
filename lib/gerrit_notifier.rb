class GerritNotifier
  extend Alias

  @@buffer = {}
  @@channel_config = nil
  @@semaphore = Mutex.new

  def self.start!
    @@channel_config = ChannelConfig.new
    start_buffer_daemon
    listen_for_updates
  end

  def self.psa!(msg)
    notify @@channel_config.all_channels, msg
  end

  def self.notify(channels, msg, emoji = '')
    channels.each do |channel|
      slack_channel = "##{channel}"
      add_to_buffer slack_channel, @@channel_config.format_message(channel, msg, emoji)
    end
  end

  def self.notify_user(user, msg)
    channel = "@#{slack_name_for user}"
    add_to_buffer channel, msg
  end

  def self.log(msg)
    puts "#{msg}"
    open('/var/log/slack-bot/slack-bot.log', 'a') do |f|
        f.puts "#{msg}"
    end
  end

  def self.notify_jira(msg, issue)
    log "[#{Time.now}] Issue  - #{issue}"
    id = (0...8).map { (65 + rand(26)).chr }.join
    add_to_buffer "jira-#{id}", msg, issue
  end

  def self.add_to_buffer(channel, msg, issue='')
    @@semaphore.synchronize do
      @@buffer[channel] ||= []
      @@buffer[channel] << msg
      @@buffer[channel] << issue
    end
  end

  def self.start_buffer_daemon
    # post every X seconds rather than truly in real-time to group messages
    # to conserve slack-log
    Thread.new do
      slack_config = YAML.load(File.read('config/slack.yml'))['slack']
      jira_config = YAML.load(File.read('config/jira.yml'))['jira']

      while true
        @@semaphore.synchronize do
          if @@buffer == {}
            log "[#{Time.now}] Buffer is empty"
          else
            log "[#{Time.now}] Current buffer:"
            ap @@buffer
          end
          if @@buffer.size > 0
            @@buffer.each do |channel, messages|
              if channel =~ /jira-\w{8}/
                  log "[#{Time.now}] JIRA comment found"
                  if messages[0] =~ /ToBuild/
                      # 711 is To Build
                      comment = { "transition" => { "id" => "711" }}.to_json
                      uri = URI.parse("https://#{jira_config['site']}/rest/api/2/issue/#{messages[1]}/transitions")
                  else
                      comment = { "body" => "#{messages[0]}" }.to_json
                      uri = URI.parse("https://#{jira_config['site']}/rest/api/2/issue/#{messages[1]}/comment")
                  end
                  https = Net::HTTP.new(uri.host,uri.port)
                  https.use_ssl = true
                  req = Net::HTTP::Post.new(uri.path, initheader = {'Content-Type' =>'application/json'})
                  req.basic_auth "#{jira_config['user']}", "#{jira_config['password']}"
                  req.body = "#{comment}"
                  res = https.request(req)
                  log "[#{Time.now}] Response #{res.code} #{res.message}: #{res.body}"
	            else
                  puts "send #{messages.join("\n\n")}to #{channel}"
                  notifier = Slack::Notifier.new slack_config['token']
                  notifier.ping(messages.join("\n\n"))
              end
           end
          end
          @@buffer = {}
        end
        sleep 15
      end
    end
  end

  def self.listen_for_updates
    stream = YAML.load(File.read('config/gerrit.yml'))['gerrit']['stream']
    log "[#{Time.now}] Listening to stream via #{stream}"

    IO.popen(stream).each do |line|
      update = Update.new(line)
      process_update(update)
    end

    puts "Connection to Gerrit server failed, trying to reconnect."
    sleep 3
    listen_for_updates
  end

  def self.process_update(update)
    if ENV['DEVELOPMENT']
      ap update.json
      log update.raw_json
    end
    channels = @@channel_config.channels_to_notify(update.project)
    return if channels.size == 0
    # New pachset
    if update.patchset_created? && update.first_patchset?
        #notify_jira "#{update.commit_jira}", update.get_issue[0]
        update.get_issue.each { |x| notify_jira "#{update.commit_jira}", x}
    end

    # Jenkins update
    if update.jenkins?
      if update.build_successful? && !update.wip?
        notify channels, "#{update.commit} *passed* Jenkins and is ready for *code review* :+1:"
      elsif update.build_failed? && !update.build_aborted?
        notify_user update.owner, "#{update.commit_without_owner} *failed* on Jenkins :-1:"
      end
    end

    # Code review +2
    if update.code_review_approved?
      notify channels, "<@#{update.author_slack_name}> has *+2'd* #{update.commit}: ready for *QA* :+1:"
    end

    # Code review +1
    if update.code_review_tentatively_approved?
      notify channels, "<@#{update.author_slack_name}> has *+1'd* #{update.commit}: needs another set of eyes for *code review* :+1: :eyes:"
    end

    # QA/Product
    if update.qa_approved? && update.product_approved?
      notify channels, "<@#{update.author_slack_name}> has *QA/Product-approved* #{update.commit}!", ":+1:"
    elsif update.qa_approved?
      notify channels, "<@#{update.author_slack_name}> has *QA-approved* #{update.commit}!", "+1:"
    elsif update.product_approved?
      notify channels, "<@#{update.author_slack_name}> has *Product-approved* #{update.commit}!", ":+1:"
    end

    # Any minuses (Code/Product/QA)
    if update.minus_1ed? || update.minus_2ed?
      verb = update.minus_1ed? ? "-1'd" : "-2'd"
      notify channels, "<@#{update.author_slack_name}> has *#{verb}* #{update.commit} :-1:"
    end

    # New comment added
    if update.comment_added? && update.human? && update.comment != ''
      notify channels, "<@#{update.author_slack_name}> has left comments on #{update.commit}: \"#{update.comment}\" :writing_hand:"
    end

    # Merged
    if update.merged?
      notify channels, "#{update.commit} was merged! \\o/", ":clap: :+1:"
      #notify_jira "ToBuild", update.get_issue[0]
      update.get_issue.each { |x| notify_jira "ToBuild", x}
    end
  end
end
