#!/bin/bash

# Make sure we are in the spark-euca directory
cd /root/spark-euca

# Load the cluster variables set by the deploy script
source ec2-variables.sh

echo $HOSTNAME > /etc/hostname

echo "Setting up Mesos on `hostname`..."

#Getting arguments
run_tests=$1
restore=$2
cohost=$3

export RESTORE=$restore #If it is a restore session the backup module will restore files from S3

# Set up the masters, slaves, etc files based on cluster env variables
echo "$MASTERS" > masters
echo "$SLAVES" > slaves

echo "$ZOOS" > zoos

echo "$ZOOS_PRIVATE_IP" > zoos_private #List with zoos private IPs needed on storm and kafka setup scripts

#If instances are co-hosted then masters will also act as Zoos
if [ "$cohost" == "True" ]; then
echo "cohost:$cohost"
fi

MASTERS=`cat masters`
NUM_MASTERS=`cat masters | wc -l`
OTHER_MASTERS=`cat masters | sed '1d'`
SLAVES=`cat slaves`
ZOOS=`cat zoos`

NAMENODES=`head -n 2 masters` #TODO: They should be the same with $NAMENODE and $STANDBY_NAMENODE but check
echo $NAMENODES > namenodes

#TODO: Change - should never go on the if statement - always at least 1 zoo
if [[ $ZOOS = *NONE* ]]; then
NUM_ZOOS=0
ZOOS=""
else
ZOOS=`cat zoos | wc -l`
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

if [[ "x$JAVA_HOME" == "x" ]] ; then
echo "Expected JAVA_HOME to be set in .bash_profile!"
exit 1
fi

if [[ "x$SCALA_HOME" == "x" ]] ; then
echo "Expected SCALA_HOME to be set in .bash_profile!"
exit 1
fi

if [[ `tty` == "not a tty" ]] ; then
echo "Expecting a tty or pty! (use the ssh -t option)."
exit 1
fi

echo "Setting executable permissions on scripts..."
find . -regex "^.+.\(sh\|py\)" | xargs chmod a+x

echo "Running setup-slave on master to mount filesystems, etc..."
source /root/spark-euca/setup-mesos-emi-slave.sh

echo "SSH'ing to master machine(s) to approve key(s)..."
for master in $MASTERS; do
echo $master
#Delete previous PUBLIC_DNS env variable if exists (restore session)
echo "Seding previous PUBLIC_DNS value..."
ssh $SSH_OPTS $master "sed -i '/PUBLIC_DNS=/d' /etc/environment"
ssh $SSH_OPTS $master "echo 'PUBLIC_DNS=$master' >> /etc/environment"
ssh $SSH_OPTS $master echo -n &
sleep 0.3
done

ssh $SSH_OPTS localhost echo -n &
ssh $SSH_OPTS `hostname` echo -n &
wait


#TODO: Replace hard-coded with $ZooDataDir
#if [[ $NUM_ZOOS != 0 ]] ; then
#echo "SSH'ing to ZooKeeper server(s) to approve keys..."
#zid=1
#for zoo in $ZOOS; do
#echo $zoo
#ssh $SSH_OPTS $zoo echo -n \; mkdir -p /mnt/zookeeper/dataDir/ \; echo $zid \> /mnt/zookeeper/dataDir/ &
#zid=$(($zid+1))
#sleep 0.3
#done
#fi

# Try to SSH to each cluster node to approve their key. Since some nodes may
# be slow in starting, we retry failed slaves up to 3 times.

if [ "$cohost" == "True" ]; then
INSTANCES="$SLAVES $ZOOS"
else
INSTANCES="$SLAVES $OTHER_MASTERS $ZOOS" # List of nodes to try (initially all)
fi

TRIES="0"                          # Number of times we've tried so far
echo "SSH'ing to other cluster nodes to approve keys..."
while [ "e$INSTANCES" != "e" ] && [ $TRIES -lt 4 ] ; do
NEW_INSTANCES=
for slave in $INSTANCES; do
echo $slave
ssh $SSH_OPTS $slave echo -n
if [ $? != 0 ] ; then
NEW_INSTANCES="$NEW_INSTANCES $slave"
fi
done
TRIES=$[$TRIES + 1]
if [ "e$NEW_INSTANCES" != "e" ] && [ $TRIES -lt 4 ] ; then
sleep 15
INSTANCES="$NEW_INSTANCES"
echo "Re-attempting SSH to cluster nodes to approve keys..."
else
break;
fi
done

echo "RSYNC'ing /root/spark-euca to other cluster nodes..."
for node in $INSTANCES; do
echo $node
rsync -e "ssh $SSH_OPTS" -az /root/spark-euca $node:/root &
scp $SSH_OPTS ~/.ssh/id_rsa $node:.ssh &
sleep 0.3
done
wait

# NOTE: We need to rsync spark-euca before we can run setup-mesos-slave.sh
# on other cluster nodes
echo "Running slave setup script on other cluster nodes..."
for node in $SLAVES; do
echo $node
ssh -t -t $SSH_OPTS root@$node "/root/spark-euca/setup-mesos-emi-slave.sh" & sleep 0.3
done
wait

echo "Setting up Mesos on `hostname`..."

echo "Configuring HDFS on `hostname`..."
echo "Creating Namenode directories on master..."

#Create hdfs name node directories on masters
for node in $MASTERS; do
echo $node
ssh -t -t $SSH_OPTS root@$node "chmod u+x /root/spark-euca/cloudera-hdfs/create-namenode-dirs.sh" & sleep 0.3
ssh -t -t $SSH_OPTS root@$node "/root/spark-euca/cloudera-hdfs/create-namenode-dirs.sh" & sleep 0.3
done
wait


echo "Creating Datanode directories on slaves..."
#Create hdfs data node directories on slaves
for node in $SLAVES; do
echo $node
ssh -t -t $SSH_OPTS root@$node "chmod u+x /root/spark-euca/cloudera-hdfs/create-datanode-dirs.sh" & sleep 0.3
ssh -t -t $SSH_OPTS root@$node "/root/spark-euca/cloudera-hdfs/create-datanode-dirs.sh" & sleep 0.3
done
wait

# Always include 'scala' module if it's not defined as a work around
# for older versions of the scripts.
#if [[ ! $MODULES =~ *scala* ]]; then
#MODULES=$(printf "%s\n%s\n" "scala" $MODULES)
#fi


#Necessary ungly hack: - Stop zookeeper daemon running on emi before deploying the new configuration
if [[ $NUM_ZOOS != 0 ]]; then
echo "Stoping old zooKeeper daemons running on emi..."
for zoo in $ZOOS; do
#ssh $SSH_OPTS $zoo "/root/mesos/third_party/zookeeper-*/bin/zkServer.sh start </dev/null >/dev/null" & sleep 0.1

echo "Creating zookeeper dirs..."
#Creating dirs on masters and other_masters even if it is not not needed when not co-hosting instances
#Creating zookeeper configuration directories
ssh -t -t $SSH_OPTS root@$zoo "mkdir -p /mnt/zookeeper/dataDir; mkdir -p /mnt/zookeeper/dataLogDir; chown -R zookeeper:zookeeper /mnt/zookeeper/; chmod -R g+w /mnt/zookeeper/" & sleep 10.0

ssh -t -t $SSH_OPTS root@$zoo "service zookeeper-server stop" & sleep 10.0
done
wait
sleep 5
fi

#Ungly hack because zookeeper is on the emi
#Disable zookeeper service from /etc/init.d if masters are not hosting zookeeper service
if [ "$cohost" == "False" ]; then
for node in $MASTERS; do
echo "Removing zookeeper daemon from node: $node"
ssh -t -t $SSH_OPTS root@$node "update-rc.d -f zookeeper-server remove" & sleep 0.3
done
wait
sleep 5
fi
# Deploy templates
# TODO: Move configuring templates to a per-module ?
echo "Creating local config files..."
./deploy_templates_mesos.py

chmod a+x /root/spark-euca/copy-dir

#Deploy all /etc/hadoop configuration
/root/spark-euca/copy-dir /etc/hadoop

#Deploy hosts-configuration
/root/spark-euca/copy-dir /etc/hosts

if [[ $NUM_ZOOS != 0 ]]; then

echo "Adding zookeeper hostnames and ports to configuration file..."
zid=1
for zoo in $ZOOS; do
echo "Adding configuration for zoo: $zoo"
echo "" >> /etc/zookeeper/conf.dist/zoo.cfg
echo "server.$zid=$zoo:2888:3888" >> /etc/zookeeper/conf.dist/zoo.cfg & sleep 0.3
zid=$(($zid+1))
sleep 0.3
done
wait
sleep 5

echo "RSYNC'ing config dirs and spark-euca dir to ZOOs and OTHER_MASTERS..."
#TODO: At the moment deploy everything but should clean up later - Probably only dirs: zookeeper, kafka and files: crontab and hosts are needed

if [ "$cohost" == "True" ]; then
NODES="$ZOOS"
else
NODES="$ZOOS $OTHER_MASTERS"
fi

for node in $ZOOS $OTHER_MASTERS; do
echo $node
rsync -e "ssh $SSH_OPTS" -az /root/spark-euca $node:/root
rsync -e "ssh $SSH_OPTS" -az /etc/zookeeper $node:/etc
rsync -e "ssh $SSH_OPTS" -az /etc/kafka $node:/etc
rsync -e "ssh $SSH_OPTS" -az /etc/hosts $node:/etc
rsync -e "ssh $SSH_OPTS" -az /etc/crontab $node:/etc
done
wait
sleep 5

echo "Starting up zookeeper ensemble..."
zid=1
for zoo in $ZOOS; do
ssh -t -t $SSH_OPTS root@$zoo "service zookeeper-server init --myid=$zid --force" & sleep 10.0
ssh -t -t $SSH_OPTS root@$zoo "service zookeeper-server start" & sleep 10.0

zid=$(($zid+1))
sleep 0.3
done
wait
sleep 5
fi

echo "Checking that zookeeper election finished and quorum is running..."
for zoo in $ZOOS; do
#ssh $SSH_OPTS $zoo "/root/mesos/third_party/zookeeper-*/bin/zkServer.sh start </dev/null >/dev/null" & sleep 0.1
ssh -t -t $SSH_OPTS root@$zoo "echo srvr | nc localhost 2181 | grep Mode" & sleep 0.3
done
wait
sleep 5

#Formatting namenode
ssh -t -t $SSH_OPTS root@$NAMENODE "sudo -u hdfs hdfs namenode -format -force" & sleep 5.0


#Initialize the HA state - run the command in one of the namenodes
echo "Initializing the HA state on namenode $NAMENODE..."
ssh -t -t $SSH_OPT root@$NAMENODE "hdfs zkfc -formatZK" & sleep 0.3

echo "Installing journal nodes..."
journals_no=1
for node in $MASTERS; do
echo $node
ssh -t -t $SSH_OPTS root@$node "apt-get --yes --force-yes install hadoop-hdfs-journalnode" & sleep 0.3
ssh -t -t $SSH_OPTS root@$node "service hadoop-hdfs-journalnode start" & sleep 0.3
journals_no=$(($journals_no+1))
done
wait
sleep 10

if [ "$journals_no" -lt "3" ]
then
    echo "ERROR: You need at least 3 journal daemonds to run namenode with HA!"
    exit
fi


echo "Starting namenode $NAMENODE..."
ssh -t -t $SSH_OPT root@$NAMENODE "service hadoop-hdfs-namenode start" & sleep 0.3

echo "Formating and starting standby namenode $STANDBY_NAMENODE..."
#Run only for the standby namenode
ssh -t -t $SSH_OPTS root@$STANDBY_NAMENODE "sudo -u hdfs hdfs namenode -bootstrapStandby" & sleep 0.3
ssh -t -t $SSH_OPTS root@$STANDBY_NAMENODE "service hadoop-hdfs-namenode start" & sleep 0.3

#TODO: Currently restarting to avoid previous running services from the bundle - Change to start after cleanning bundle image
#echo "Starting up HDFS and Jobtracker..."
#Startup HDFS + Zookeeper
#for node in $MASTERS; do
#echo $node
#service zookeeper stop doesn't work because zookeeper daemon on emi is running with the old configuration and doesn't have access to the new log dirs
#ssh -t -t $SSH_OPTS root@$node `ps ax | grep -i '/usr/lib/zookeeper' | grep -v grep | awk '{print $1}' | xargs kill -9` & sleep 10.0
#ssh -t -t $SSH_OPTS root@$node "service zookeeper-server init" & sleep 10.0
#ssh -t -t $SSH_OPTS root@$node "service zookeeper-server start" & sleep 10.0

#ssh -t -t $SSH_OPTS root@$node "sudo -u hdfs hdfs namenode -format -force" & sleep 10.0 #TODO: Can formatting be avoided?
#ssh -t -t $SSH_OPTS root@$node "service hadoop-hdfs-namenode start" & sleep 10.0
#ssh -t -t $SSH_OPTS root@$node "service hadoop-0.20-mapreduce-jobtracker restart" & sleep 10.0
#done


echo "Starting up datanodes..."
for node in $SLAVES; do
echo $node
ssh -t -t $SSH_OPTS root@$node "service hadoop-0.20-mapreduce-tasktracker stop" & sleep 10.0 #Making sure there is not tasktracker left running on the EMI
ssh -t -t $SSH_OPTS root@$node "service hadoop-hdfs-datanode restart" & sleep 10.0
done
wait
sleep 5

echo "Starting job trackers..."
for node in $MASTERS; do
echo $node
ssh -t -t $SSH_OPTS root@$node "service hadoop-0.20-mapreduce-jobtracker restart" & sleep 10.0
jps | grep Tracker
done
wait
sleep 5


echo "Starting Zookeeper failover controller on namenodes..."
for node in $NAMENODES; do
echo $node
ssh -t -t $SSH_OPTS root@$node "apt-get --yes --force-yes install hadoop-hdfs-zkfc" & sleep 0.3
ssh -t -t $SSH_OPTS root@$node "service hadoop-hdfs-zkfc start" & sleep 0.3
jps | grep Tracker
done
wait
sleep 5

echo "RSYNC'ing /root/mesos-installation to other cluster nodes..."
for node in $SLAVES $OTHER_MASTERS; do
echo $node
rsync -e "ssh $SSH_OPTS" -az /root/mesos-installation $node:/root
done
wait
sleep 5

echo "Adding master startup script to /etc/init.d and starting Mesos-master..."

for node in $MASTERS; do
echo $node
ssh $SSH_OPTS root@$node "update-rc.d -f start-mesos-master remove" & sleep 0.3 #remove previous service on emi
ssh $SSH_OPTS root@$node "chmod +x /root/mesos-installation/start-mesos-master.sh" & sleep 0.3
ssh $SSH_OPTS root@$node "cd /etc/init.d/; ln -s /root/mesos-installation/start-mesos-master.sh mesos-master-start; update-rc.d mesos-master-start defaults; service mesos-master-start" & sleep 10.0
done
wait
sleep 5


echo "Adding slave startup script to /etc/init.d and starting Mesos-slave..."

for node in $SLAVES; do
echo $node
ssh $SSH_OPTS root@$node "export LD_LIBRARY_PATH=/root/mesos-installation/lib/"
ssh $SSH_OPTS root@$node "chmod +x /root/mesos-installation/start-mesos-slave.sh; cd /etc/init.d/; ln -s /root/mesos-installation/start-mesos-slave.sh start-mesos-slave; update-rc.d start-mesos-slave defaults; service start-mesos-slave" & sleep 10.0
done
wait
sleep 5


echo "Initializing modules..."

# Install / Init module
for module in $MODULES; do
if [[ -e $module/init.sh ]]; then
echo "Initializing $module"
source $module/init.sh
fi
cd /root/spark-euca  # guard against init.sh changing the cwd
done

echo "Setting up modules..."
# Setup each module
for module in $MODULES; do
echo "Setting up $module"
source $module/setup.sh
sleep 1
cd /root/spark-euca  # guard against setup.sh changing the cwd
done

echo "Starting up modules..."
#Startup each module
for module in $MODULES; do
if [[ -e $module/startup.sh ]]; then
echo "Starting up $module"
source $module/startup.sh
sleep 1
fi
cd /root/spark-euca  # guard against setup.sh changing the cwd
done

# Test modules

echo "Testing modules..."
#echo "run_tests=$run_tests"
if [ "$run_tests" == "True" ]; then

# Add test code
for module in $MODULES; do
echo "Adding test code & running tests for $module"
if [[ -e $module/test.sh ]]; then
source $module/test.sh
sleep 1
fi
cd /root/spark-euca  # guard against setup-test.sh changing the cwd
done
fi

#Some modules setups (Kafka - Storm) modifies the configuration files on /etc/ and modules on /root dir.
#So this makes sure that instances have identical file structures
echo "Copying master files to other masters..."
for node in $OTHER_MASTERS; do
echo $node
rsync -e "ssh $SSH_OPTS" -az /root $node:/

rsync -e "ssh $SSH_OPTS" -az --exclude "/etc/hostname" /etc $node:/

rsync -e "ssh $SSH_OPTS" -az /mnt $node:/
done


echo "Checking if services are up..."
for node in $MASTERS $OTHER_MASTERS; do
echo $node
echo "ps -ef | grep storm"
ssh $SSH_OPTS root@$node "ps -ef | grep storm" & sleep 0.3

echo "ps -ef | grep kafka"
ssh $SSH_OPTS root@$node "ps -ef | grep kafka" & sleep 0.3

echo "ps -ef | grep zoo"
ssh $SSH_OPTS root@$node "ps -ef | grep zoo" & sleep 0.3

echo "ps -ef | grep mesos"
ssh $SSH_OPTS root@$node "ps -ef | grep mesos" & sleep 0.3
done

#reboot maschines to fix issue with starting up kafka and storm
echo "Rebooting nodes..."
for node in $SLAVES $ZOOS $OHER_MASTERS $MASTERS; do
echo Rebooting $node ...
ssh $SSH_OPTS root@$node "reboot" & sleep 10.0
done




