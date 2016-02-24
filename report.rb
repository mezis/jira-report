#!/usr/bin/env ruby
#
# Export ticket timestamps and points from Jira
# 
require 'rubygems'
require 'bundler/setup'
require 'active_support/all'
require 'jira'
require 'term/ansicolor'
require 'logger'
require 'csv'
require 'pry'
require 'working_hours'
# require 'httplog'

Time.zone = 'UTC'

module JiraReport
  
  class Story
    attr_reader :errors

    def initialize(jira_issue)
      @issue = jira_issue
    end

    def valid?
      @errors = %i[ref started_at closed_at assignee estimate].map { |field|
        send(field).nil? ? field : nil
      }.compact
      !@errors.any?
    end

    def ref
      @issue.key
    end

    def started_at
      status_timestamp('In Progress') || status_timestamp('In Dev')
    end

    def closed_at
      status_timestamp('Closed') || status_timestamp('Done')
    end

    def assignee
      @issue.assignee&.emailAddress
    end

    def estimate
      # For some weird reason, Jira estimates end up in this field instead of
      # the "estimate" field.
      @issue.customfield_10008
    end

    private

    def status_timestamp(status)
      @issue.changelog['histories'].
      sort_by { |h| h['created'] }.
      find { |h|
        h['items'].any? { |i|
          i['field'] == 'status' && i['toString'] == status
        }
      }.tap do |h|
        return unless h
        return Time.zone.parse h['created']
      end
    end
  end


  class Logger
    protected

    Levels = {
      :debug   => :reset,
      :info    => :green,
      :warning => :yellow,
      :error   => :red
    }

    def log(color, message)
      mutex.synchronize do
        $stderr.puts Term::ANSIColor.send(color, message)
        $stderr.flush
      end
    end

    private

    def mutex
      @mutex ||= Mutex.new
    end

    public

    Levels.each_pair do |method_name, color|
      define_method(method_name) do |message|
        log(color, message)
      end
    end
  end



  class App
    WEEK_COUNT = 156

    def report(projects)
      start_date = Date.parse('2016-01-01')
      end_date = Date.today

      csv = CSV.open('report.csv', 'w') do |csv|
        csv << ['Project', 'Issue', 'User', 'Started At', 'Completed At', 'Week', 'Estimate', 'Duration']

        projects.each do |project|
          (start_date...end_date).each do |date|
            Logger.info("#{project} #{date}")
            issues = client.Issue.jql('project = %s AND updated >= %s AND updated < %s' % [project, date, date+1], expand: %w[changelog])
            issues.each do |issue|
              story = Story.new(issue)
              unless story.valid?
                Logger.warning("  #{issue.key} invalid: #{story.errors}")
                next
              end
              Logger.info("  #{issue.key} valid: #{story.estimate.to_i} points")
              csv << [
                project,
                story.ref,
                story.assignee,
                story.started_at,
                story.closed_at,
                story.closed_at.beginning_of_week.to_date,
                story.estimate.to_i,
                story.started_at.working_time_until(story.closed_at)
              ]
            end
          end
        end
      end
    end

    private

    Logger = Logger.new

    attr_reader :setup_complete

    def client
      return @client if @client
      options = {
                  :username => git_setting('jira.user', 'username'),
                  :password => git_setting('jira.password', 'password'),
                  :site     => git_setting('jira.site', 'url'),
                  :context_path => '/',
                  :auth_type => :basic,
                  :read_timeout => 120
                }

      @client = JIRA::Client.new(options)
    end

    private

    def git_setting(str, thing)
      value = `git config #{str}`.strip
      return value unless value.blank?

      Logger.error %Q{
        I don't know your Jira API #{thing}!
        Please set it with:
        $ git config #{str} <#{thing}>
      }
      exit 1
    end
  end
end


begin
  JiraReport::App.new.report(ARGV)
rescue StandardError => e
  JiraReport::Logger.new.error "Aborting (#{e.class.name}: #{e.message})"
  JiraReport::Logger.new.debug e.backtrace.join("\n")
end
