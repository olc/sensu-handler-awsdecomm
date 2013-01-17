#!/usr/bin/env ruby
#
# Sensu Handler: awsdecomm
#
# Copyright 2013, Bryan Brandau <agent462@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'sensu-handler'
require 'aws-sdk'
gem 'mail', '~> 2.4.0'
require 'mail'
require 'timeout'

class AwsDecomm < Sensu::Handler

    def delete_sensu_client
      puts "Sensu client #{@event['client']['name']} is being deleted"
      retries = 1
      begin
        if api_request(:DELETE, '/clients/' + @event['client']['name']).code != '202' then raise "Sensu API call failed;" end
      rescue StandardError => e
        if (retries -= 1) >= 0
          sleep 3
          puts e.message + " Deletion failed; retrying to delete sensu client #{@event['client']['name']}"
          retry
        else
          puts @b << e.message + " Deleting sensu client #{@event['client']['name']} failed permanently."
        end 
      end
    end

    def delete_chef_node
      require 'spice'
      Spice.setup do |s|
        s.server_url   = "http://#{@settings["awsdecomm"]["chef_server_host"]}:#{@settings["awsdecomm"]["chef_server_port"]}"
        s.client_name  = @settings["awsdecomm"]["chef_client_user"]
        s.client_key   = Spice.read_key_file( @settings["awsdecomm"]["chef_client_key_dir"] )
        s.chef_version = @settings["awsdecomm"]["chef_server_version"]
      end

      JSON.create_id = nil #this is needed because the json response has a json_class key
      retries = 1
      begin
        puts "Chef node #{@event['client']['name']} is being deleted"
        Spice.delete( "/nodes/#{@event['client']['name']}" )
      rescue Spice::Error => e
        if (retries -= 1) >= 0
          sleep 3
          puts e.message + " Deletion failed; retrying to delete chef node #{@event['client']['name']}"
          retry
        else
          puts @b << e.message + " Deleting chef node #{@event['client']['name']} failed permanently."
        end 
      end

      retries = 1
      begin
        puts "Chef client #{@event['client']['name']} is being deleted"
        Spice.delete( "/clients/#{@event['client']['name']}" )
      rescue Spice::Error => e
        if (retries -= 1) >= 0
          sleep 3
          puts e.message + " Deletion failed, retrying to delete chef client #{@event['client']['name']}"
          retry
        else
          puts @b << e.message + " Deleting chef client #{@event['client']['name']} failed permanently."
        end 
      end
    end

    def delete_foreman_node
      require 'foreman_api'
      hosts = ForemanApi::Resources::Host.new(:base_url => "#{@settings['awsdecomm']['foreman_server_url']}",
                                              :username => "#{@settings['awsdecomm']['foreman_client_user']}",
                                              :password => "#{@settings['awsdecomm']['foreman_client_password']}")
      retries = 3
      begin
        puts "Foreman node #{@event['client']['name']} is being deleted"
        hosts.destroy('id'=>@event['client']['name'])
      rescue
        if (retries -= 1) >= 0
          sleep 3
          puts "Deletion failed, retrying to delete foreman node #{@event['client']['name']}"
          retry
        else
          puts @b << "Deleting foreman node #{@event['client']['name']} failed permanently."
        end
      end
    end

  def delete_managed_node
    case @settings["awsdecomm"]["cfg_mgmt_type"]
      when 'chef'    then delete_chef_node
      when 'foreman' then delete_foreman_node
    end
  end

  def check_ec2
    instance = false
    %w{ ec2.us-east-1.amazonaws.com ec2.us-west-2.amazonaws.com ec2.eu-west-1.amazonaws.com }.each do |region|
      ec2 = AWS::EC2.new(
        :access_key_id => @settings["awsdecomm"]["access_key_id"],
        :secret_access_key => @settings["awsdecomm"]["secret_access_key"],
        :ec2_endpoint => region
      )

      retries = 1
      begin
        id = @event['client']['name'][Regexp.new(@settings['awsdecomm']['instance_id_filter']),1] || @event['client']['name']
        i = ec2.instances[id]
        if i.exists?
          puts "Instance #{@event['client']['name']} exists; Checking state"
          instance = true
          if i.status.to_s === "terminated" || i.status.to_s === "shutting_down"
            puts "Instance #{@event['client']['name']} is #{i.status}; I will proceed with decommission activities."
            delete_sensu_client
            delete_managed_node
          else
            puts "Client #{@event['client']['name']} is #{i.status}"
          end
        end
      rescue AWS::Errors::ClientError, AWS::Errors::ServerError => e
        if (retries -= 1) >= 0
          sleep 3
          puts e.message + " AWS lookup for #{@event['client']['name']} has failed; trying again."
          retry
        else
          @b << "AWS instance lookup failed permanently for #{@event['client']['name']} on #{region}. "
          mail
          bail(@b)
        end 
      end
    end
    if instance == false
      puts "Could not find that instance anywhere on ec2, proceeding with decommission anyway..."
      delete_sensu_client
      delete_managed_node
    end
  end
  
  def mail
    params = {
      :mail_to   => @settings['awsdecomm']['mail_to'],
      :mail_from => @settings['awsdecomm']['mail_from'],
      :smtp_addr => @settings['awsdecomm']['smtp_address'],
      :smtp_port => @settings['awsdecomm']['smtp_port'],
      :smtp_domain => @settings['awsdecomm']['smtp_domain']
    }

    body = <<-BODY.gsub(/^ {14}/, '')
            #{@event['check']['output']}
            Host: #{@event['client']['name']}
            Timestamp: #{Time.at(@event['check']['issued'])}
            Address:  #{@event['client']['address']}
            Check Name:  #{@event['check']['name']}
            Command:  #{@event['check']['command']}
            Status:  #{@event['check']['status']}
            Occurrences:  #{@event['occurrences']}
          BODY
    s_subject = "Decommission of #{@event['client']['name']} was successful."
    f_subject = "Failure: Decommission of #{@event['client']['name']} failed."

    @b != "" ? begin body = @b; sub = f_subject end : sub = s_subject

    Mail.defaults do
      delivery_method :smtp, {
        :address => params[:smtp_addr],
        :port    => params[:smtp_port],
        :domain  => params[:smtp_domain],
        :openssl_verify_mode => 'none'
      }
    end

    begin
      timeout 10 do
        Mail.deliver do
          to      params[:mail_to]
          from    params[:mail_from]
          subject sub
          body    body
        end

        puts "mail -- #{sub}"
      end
    rescue Timeout::Error
      puts "mail -- timed out while attempting to deliver message #{sub}"
    end
  end

  def handle
    @b = ""
    if @event['check']['name'].eql?('keepalive') and @event['action'].eql?('create')
      check_ec2
      mail
    end
  end

end
