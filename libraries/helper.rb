# frozen_string_literal: true

# Copyright 2018-2021 Shine Solutions Group
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'ruby_aem_aws'

def read_config
  config_file = ENV['INSPEC_AEM_AWS_CONF'] || './conf/aem-aws.yml'
  config = YAML.load_file(config_file) if File.exist?(config_file)
  config_params = {}

  # a hotfix for ruby_aem_aws
  config_params[:region] = config['aws']['region']

  %w[profile access_key_id secret_access_key session_token s3_bucket region].each { |field|
    env_field = format('aws_%<field>s', field: field)
    if !ENV[env_field].nil?
      config_params[:"aws_#{field}"] = ENV[env_field]
    elsif !config.nil? && !config['aws'][field].nil?
      config_params[:"aws_#{field}"] = config['aws'][field]
    end
  }

  %w[stack_prefix component id].each { |field|
    env_field = format('aem_%<field>s', field: field)
    if !ENV[env_field].nil?
      config_params[:"aem_#{field}"] = ENV[env_field]
    elsif !config.nil? && !config['aem'][field].nil?
      config_params[:"aem_#{field}"] = config['aem'][field]
    end
  }
  config_params
end

def config_retries(task)
  config_file = ENV['INSPEC_AEM_AWS_CONF'] || './conf/aem-aws.yml'
  config = YAML.load_file(config_file) if File.exist?(config_file)
  config_params = {}
  %w[retry_counter retry_wait_in_seconds].each { |field|
    if !config.nil? && !config[task].nil? && !config[task][field].nil?
      config_params[:"#{field}"] = config[task][field]
    else
      field_value = 60
      config_params[:"#{field}"] = field_value
    end
  }
  config_params
end

def init_aem_aws_client(conf = {})
  RubyAemAws::AemAws.new(conf)
end

def init_aws_aem_instance_client(client, conf)
  if conf[:aem_component] == 'author-primary'
    client = client.full_set(conf[:aem_stack_prefix])
    [client, client.author.author_primary]
  elsif conf[:aem_component] == 'author-standby'
    client = client.full_set(conf[:aem_stack_prefix])
    [client, client.author.author_standby]
  elsif conf[:aem_component] == 'publish'
    client = client.full_set(conf[:aem_stack_prefix])
    [client, client.publish]
  elsif conf[:aem_component] == 'author-dispatcher'
    client = client.full_set(conf[:aem_stack_prefix])
    [client, client.author_dispatcher]
  elsif conf[:aem_component] == 'publish-dispatcher'
    client = client.full_set(conf[:aem_stack_prefix])
    [client, client.publish_dispatcher]
  elsif conf[:aem_component] == 'chaos-monkey'
    client = client.full_set(conf[:aem_stack_prefix])
    [client, client.chaos_monkey]
  elsif conf[:aem_component] == 'orchestrator'
    client = client.full_set(conf[:aem_stack_prefix])
    [client, client.orchestrator]
  elsif conf[:aem_component] == 'author-publish-dispatcher'
    client = client.consolidated(conf[:aem_stack_prefix])
    [client, client.author_publish_dispatcher]
  else
    client.full_set(conf[:aem_stack_prefix])
  end
end

def elb_instances_healthy?(task, client)
  conf = config_retries(task)
  return false if client.health_state.eql?(:misconfigured)

  counter = 0
  while counter < conf[:retry_counter]
    return true if client.health_state.eql?(:ready)

    sleep conf[:retry_wait_in_seconds]
    counter += 1
  end
  false
end

def elb_healthy?(task, client)
  conf = config_retries(task)
  return false if client.health_state_elb.eql?(:misconfigured)

  counter = 0
  while counter < conf[:retry_counter]
    return true if client.health_state_elb.eql?(:ready)

    sleep conf[:retry_wait_in_seconds]
    counter += 1
  end
  false
end

def instances_healthy?(task, client)
  conf = config_retries(task)
  counter = 0
  while counter < conf[:retry_counter]
    return true if client.healthy?

    sleep conf[:retry_wait_in_seconds]
    counter += 1
  end
  false
end

def asg_healthy?(task, client)
  conf = config_retries(task)
  counter = 0
  while counter < conf[:retry_counter]
    return true if client.healthy_asg?

    sleep conf[:retry_wait_in_seconds]
    counter += 1
  end
  false
end

def get_alarm_state(alarm_name, client)
  conf = config_retries(alarm_name)
  counter = 0
  while counter < conf[:retry_counter]
    response = client.get_alarm(alarm_name)

    counter += 1
    sleep conf[:retry_wait_in_seconds] if response.metric_alarms.empty?
    next if response.metric_alarms.empty?

    return true if response.metric_alarms[0].state_value.eql? 'OK'

    return false if response.metric_alarms[0].state_value.eql? 'ALARM'

    sleep conf[:retry_wait_in_seconds]
  end
  false
end

def wait_until_alarm_state_ok(alarm_name, client)
  conf = config_retries(alarm_name)
  counter = 0
  while counter < conf[:retry_counter]
    response = get_alarm_state(alarm_name, client)
    return true if response.eql? true

    counter += 1
    sleep conf[:retry_wait_in_seconds]
  end
  false
end

def successful_provisioned_component?(task, client)
  conf = config_retries(task)
  counter = 0
  while counter < conf[:retry_counter]
    component_init_state_tag = nil

    # Get component tags
    tags = client.get_tags

    # If no tags received try again
    next if tags.nil? || tags.empty?

    # Loop through the received tags
    tags.each do |tag|
      # If tag ComponentInitStatus exists
      # add ComponentInitStatus tag value to list
      component_init_state_tag = tag.value if tag.key.eql?('ComponentInitStatus')
    end

    # If no tags found try again
    next if component_init_state_tag.nil?

    # Fail if provisioning failed on one instance
    return false if component_init_state_tag.eql?('Failed')

    # Try again if one instance is still in provisioning
    next if component_init_state_tag.eql?('Running')

    # return true if all instances who responsed
    # with their tags successfully finished provisioning
    return true if component_init_state_tag.eql?('Success')

    sleep conf[:retry_wait_in_seconds]
    counter += 1
  end
  false
end

def successful_provisioned_components?(task, client, skip_component_failed_state = false)
  conf = config_retries(task)
  counter = 0
  while counter < conf[:retry_counter]
    component_init_state_tags = []
    component_init_state_success_count = 0
    tags = client.get_tags

    # If no tags received try again
    next if tags.nil? || tags.empty?

    # Check how many instances responsed their tags
    instances_count = tags.length

    # Loop through the found tags
    tags.each do |tag|
      # Loop through each instance tags
      tag.each do |tag_key|
        # If tag ComponentInitStatus exists
        # add ComponentInitStatus tag value to list
        component_init_state_tags.push(tag_key.value) if tag_key.key.eql?('ComponentInitStatus')
      end
    end

    # Fail if provisioning failed on one instance
    return false if component_init_state_tags.include?('Failed') && skip_component_failed_state.eql?(false)

    component_init_state_tags.each do |component_init_state_tag|
      component_init_state_success_count += 1 if component_init_state_tag.eql?('Success')
    end

    # return true if all instances who responsed
    # with their tags successfully finished provisioning
    return true if component_init_state_success_count.eql?(instances_count) && client.healthy_asg?

    sleep conf[:retry_wait_in_seconds]
    counter += 1
  end
  false
end
