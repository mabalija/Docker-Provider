#!/usr/local/bin/ruby
# frozen_string_literal: true

module Fluent
    require 'logger'
    require 'json'
    require_relative 'oms_common'
    require_relative 'HealthMonitorUtils'
    require_relative 'HealthMonitorState'
    require_relative "ApplicationInsightsUtility"


    class CAdvisor2HealthFilter < Filter
        Fluent::Plugin.register_filter('filter_cadvisor2health', self)

        config_param :log_path, :string, :default => '/var/opt/microsoft/docker-cimprov/log/health_monitors.log'
        config_param :metrics_to_collect, :string, :default => 'cpuUsageNanoCores,memoryRssBytes'
        config_param :container_resource_refresh_interval_minutes, :integer, :default => 5

        @@object_name_k8s_node = 'K8SNode'
        @@object_name_k8s_container = 'K8SContainer'

        @@counter_name_cpu = 'cpuusagenanocores'
        @@counter_name_memory_rss = 'memoryrssbytes'

        @@health_monitor_config = {}

        @@hostName = (OMS::Common.get_hostname)
        @@clusterName = KubernetesApiClient.getClusterName
        @@clusterId = KubernetesApiClient.getClusterId
        @@clusterRegion = KubernetesApiClient.getClusterRegion


        def initialize
            super
            @cpu_capacity = 0.0
            @memory_capacity = 0.0
            @last_resource_refresh = DateTime.now.to_time.to_i
            @metrics_to_collect_hash = {}
        end

        def configure(conf)
            super
            @log = HealthMonitorUtils.getLogHandle
            @log.debug {'Starting filter_cadvisor2health plugin'}
        end

        def start
            super
            @metrics_to_collect_hash = HealthMonitorUtils.build_metrics_hash(@metrics_to_collect)
            @log.debug "Calling ensure_cpu_memory_capacity_set cpu_capacity #{@cpu_capacity} memory_capacity #{@memory_capacity}"
            node_capacity = HealthMonitorUtils.ensure_cpu_memory_capacity_set(@cpu_capacity, @memory_capacity, @@hostName)
            @cpu_capacity = node_capacity[0]
            @memory_capacity = node_capacity[1]
            @log.info "CPU Capacity #{@cpu_capacity} Memory Capacity #{@memory_capacity}"
            HealthMonitorUtils.refreshKubernetesApiData(@log, @@hostName)
            @@health_monitor_config = HealthMonitorUtils.getHealthMonitorConfig
        end

        def filter_stream(tag, es)
            new_es = MultiEventStream.new
            HealthMonitorUtils.refreshKubernetesApiData(@log, @hostName)
            records_count = 0
            es.each { |time, record|
              begin
                filtered_record = filter(tag, time, record)
                if !filtered_record.nil?
                    new_es.add(time, filtered_record)
                    records_count += 1
                end
              rescue => e
                router.emit_error_event(tag, time, record, e)
              end
            }
            @log.debug "Filter Records Count #{records_count}"
            new_es
        end

        def filter(tag, time, record)
            begin
                if record.key?("MonitorLabels")
                    return record
                end
                object_name = record['DataItems'][0]['ObjectName']
                counter_name = record['DataItems'][0]['Collections'][0]['CounterName'].downcase
                if @metrics_to_collect_hash.key?(counter_name.downcase)
                    metric_value = record['DataItems'][0]['Collections'][0]['Value']
                    case object_name
                    when @@object_name_k8s_container
                        case counter_name.downcase
                        when @@counter_name_cpu
                            # @log.debug "Object Name #{object_name}"
                            # @log.debug "Counter Name #{counter_name}"
                            # @log.debug "Metric Value #{metric_value}"
                            return process_container_cpu_record(record, metric_value)
                        when @@counter_name_memory_rss
                            return process_container_memory_record(record, metric_value)
                        end
                    when @@object_name_k8s_node
                        case counter_name.downcase
                        when @@counter_name_cpu
                            process_node_cpu_record(record, metric_value)
                        when @@counter_name_memory_rss
                            process_node_memory_record(record, metric_value)
                        end
                    end
                end
            rescue => e
                @log.debug "Error in filter #{e}"
                @log.debug "record #{record}"
                @log.debug "backtrace #{e.backtrace}"
                ApplicationInsightsUtility.sendExceptionTelemetry(e)
                return nil
            end
        end

        def process_container_cpu_record(record, metric_value)
            monitor_id = HealthMonitorConstants::WORKLOAD_CONTAINER_CPU_PERCENTAGE_MONITOR_ID
            @log.debug "processing container cpu record"
            if record.nil?
                return nil
            else
                instance_name = record['DataItems'][0]['InstanceName']
                key = HealthMonitorUtils.getContainerKeyFromInstanceName(instance_name)
                container_metadata = HealthMonitorUtils.getContainerMetadata(key)
                if !container_metadata.nil?
                    cpu_limit = container_metadata['cpuLimit']
                end

                if cpu_limit.to_s.empty?
                    #@log.info "CPU Limit is nil"
                    cpu_limit = @cpu_capacity
                end

                #@log.info "cpu limit #{cpu_limit}"

                percent = (metric_value.to_f/cpu_limit*100).round(2)
                #@log.debug "Container #{key} | Percentage of CPU limit: #{percent}"
                state = HealthMonitorState.computeHealthMonitorState(@log, monitor_id, percent, @@health_monitor_config[HealthMonitorConstants::WORKLOAD_CONTAINER_CPU_PERCENTAGE_MONITOR_ID])
                #@log.debug "Computed State : #{state}"
                timestamp = record['DataItems'][0]['Timestamp']
                health_monitor_record = {"timestamp" => timestamp, "state" => state, "details" => {"cpuUsageMillicores" => metric_value/1000000.to_f, "cpuUtilizationPercentage" => percent}}
                #health_monitor_record = HealthMonitorRecord.new(timestamp, state, {"cpuUsageMillicores" => metric_value/1000000.to_f, "cpuUtilizationPercentage" => percent})
                #@log.info health_monitor_record

                monitor_instance_id = HealthMonitorUtils.getMonitorInstanceId(@log, monitor_id, {"cluster_id" => @@clusterId, "node_name" => @@hostName, "container_key" => key})
                #@log.info "Monitor Instance Id: #{monitor_instance_id}"
                HealthMonitorState.updateHealthMonitorState(@log, monitor_instance_id, health_monitor_record, @@health_monitor_config[monitor_id])
                record = HealthMonitorSignalReducer.reduceSignal(@log, monitor_id, monitor_instance_id, @@health_monitor_config[monitor_id])
                temp = record.nil? ? "Nil" : record["MonitorInstanceId"]
                @log.info "Processed Container CPU #{temp}"
                return record
            end
            return nil
        end

        def process_container_memory_record(record, metric_value)
            monitor_id = HealthMonitorConstants::WORKLOAD_CONTAINER_MEMORY_PERCENTAGE_MONITOR_ID
            #@log.debug "processing container memory record"
            if record.nil?
                return nil
            else
                instance_name = record['DataItems'][0]['InstanceName']
                key = HealthMonitorUtils.getContainerKeyFromInstanceName(instance_name)
                container_metadata = HealthMonitorUtils.getContainerMetadata(key)
                if !container_metadata.nil?
                    memory_limit = container_metadata['memoryLimit']
                end

                if memory_limit.to_s.empty?
                    #@log.info "Memory Limit is nil"
                    memory_limit = @memory_capacity
                end

                #@log.info "memory limit #{memory_limit}"

                percent = (metric_value.to_f/memory_limit*100).round(2)
                #@log.debug "Container #{key} | Percentage of Memory limit: #{percent}"
                state = HealthMonitorState.computeHealthMonitorState(@log, monitor_id, percent, @@health_monitor_config[HealthMonitorConstants::WORKLOAD_CONTAINER_MEMORY_PERCENTAGE_MONITOR_ID])
                #@log.debug "Computed State : #{state}"
                timestamp = record['DataItems'][0]['Timestamp']
                health_monitor_record = {"timestamp" => timestamp, "state" => state, "details" => {"memoryRssBytes" => metric_value.to_f, "memoryUtilizationPercentage" => percent}}
                #health_monitor_record = HealthMonitorRecord.new(timestamp, state, {"memoryRssBytes" => metric_value.to_f, "memoryUtilizationPercentage" => percent})
                #@log.info health_monitor_record

                monitor_instance_id = HealthMonitorUtils.getMonitorInstanceId(@log, monitor_id, {"cluster_id" => @@clusterId, "node_name" => @@hostName, "container_key" => key})
                #@log.info "Monitor Instance Id: #{monitor_instance_id}"
                HealthMonitorState.updateHealthMonitorState(@log, monitor_instance_id, health_monitor_record, @@health_monitor_config[monitor_id])
                record = HealthMonitorSignalReducer.reduceSignal(@log, monitor_id, monitor_instance_id, @@health_monitor_config[monitor_id])
                temp = record.nil? ? "Nil" : record["MonitorInstanceId"]
                @log.info "Processed Container Memory #{temp}"
                return record
            end
            return nil
        end

        def process_node_cpu_record(record, metric_value)
            monitor_id = HealthMonitorConstants::NODE_CPU_MONITOR_ID
            #@log.debug "processing node cpu record"
            if record.nil?
                return nil
            else
                instance_name = record['DataItems'][0]['InstanceName']
                #@log.info "CPU capacity #{@cpu_capacity}"

                percent = (metric_value.to_f/@cpu_capacity*100).round(2)
                #@log.debug "Percentage of CPU limit: #{percent}"
                state = HealthMonitorState.computeHealthMonitorState(@log, monitor_id, percent, @@health_monitor_config[HealthMonitorConstants::NODE_CPU_MONITOR_ID])
                #@log.debug "Computed State : #{state}"
                timestamp = record['DataItems'][0]['Timestamp']
                health_monitor_record = {"timestamp" => timestamp, "state" => state, "details" => {"cpuUsageMillicores" => metric_value/1000000.to_f, "cpuUtilizationPercentage" => percent}}

                monitor_instance_id = HealthMonitorUtils.getMonitorInstanceId(@log, monitor_id, {"cluster_id" => @@clusterId, "node_name" => @@hostName})
                HealthMonitorState.updateHealthMonitorState(@log, monitor_instance_id, health_monitor_record, @@health_monitor_config[monitor_id])
                record = HealthMonitorSignalReducer.reduceSignal(@log, monitor_id, monitor_instance_id, @@health_monitor_config[monitor_id])
                temp = record.nil? ? "Nil" : record["MonitorInstanceId"]
                @log.info "Processed Node CPU #{temp}"
                return record
            end
            return nil
        end

        def process_node_memory_record(record, metric_value)
            monitor_id = HealthMonitorConstants::NODE_MEMORY_MONITOR_ID
            #@log.debug "processing node memory record"
            if record.nil?
                return nil
            else
                instance_name = record['DataItems'][0]['InstanceName']
                #@log.info "Memory capacity #{@memory_capacity}"

                percent = (metric_value.to_f/@memory_capacity*100).round(2)
                #@log.debug "Percentage of Memory limit: #{percent}"
                state = HealthMonitorState.computeHealthMonitorState(@log, monitor_id, percent, @@health_monitor_config[HealthMonitorConstants::NODE_MEMORY_MONITOR_ID])
                #@log.debug "Computed State : #{state}"
                timestamp = record['DataItems'][0]['Timestamp']
                health_monitor_record = {"timestamp" => timestamp, "state" => state, "details" => {"memoryRssBytes" => metric_value.to_f, "memoryUtilizationPercentage" => percent}}
                #health_monitor_record = HealthMonitorRecord.new(timestamp, state, {"memoryRssBytes" => metric_value/1000000.to_f, "memoryUtilizationPercentage" => percent})
                #@log.info health_monitor_record

                monitor_instance_id = HealthMonitorUtils.getMonitorInstanceId(@log, monitor_id, {"cluster_id" => @@clusterId, "node_name" => @@hostName})
                #@log.info "Monitor Instance Id: #{monitor_instance_id}"
                HealthMonitorState.updateHealthMonitorState(@log, monitor_instance_id, health_monitor_record, @@health_monitor_config[monitor_id])
                record = HealthMonitorSignalReducer.reduceSignal(@log, monitor_id, monitor_instance_id, @@health_monitor_config[monitor_id])
                temp = record.nil? ? "Nil" : record["MonitorInstanceId"]
                @log.info "Processed Node Memory #{record}"
                return record
            end
            return nil
        end
    end
end
