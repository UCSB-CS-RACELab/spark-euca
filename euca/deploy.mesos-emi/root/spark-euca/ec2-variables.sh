#!/usr/bin/env bash

#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# These variables are automatically filled in by the spark-euca script.
export MASTERS="{{master_list}}"
export SLAVES="{{slave_list}}"
export ZOOS="{{zoo_list}}"
export HDFS_DATA_DIRS="{{hdfs_data_dirs}}"
export MAPRED_LOCAL_DIRS="{{mapred_local_dirs}}"
export MODULES="{{modules}}"
export MESOS_INSTALL_VERSION="{{mesos_version}}"
export SWAP_MB="{{swap}}"
export CLUSTER_NAME="{{cluster_name}}"
export ACTIVE_MASTER="{{active_master}}"
export ACTIVE_MASTER_PRIVATE="{{active_master_private}}"
export MASTERS_DNS_MAPPINGS="{{masters_dns_mappings}}"
export SLAVES_DNS_MAPPINGS="{{slaves_dns_mappings}}"
export MASTERS_DNS_MAPPINGS_PUBLIC="{{masters_dns_mappings_public}}"
export SLAVES_DNS_MAPPINGS_PUBLIC="{{slaves_dns_mappings_public}}"
export PRIVATE_IP_ADDRESS="{{private_ip_address}}" #TODO: Set this