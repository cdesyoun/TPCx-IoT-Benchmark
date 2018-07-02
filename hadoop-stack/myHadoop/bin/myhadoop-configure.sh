#!/usr/bin/env bash
################################################################################
# myhadoop-configure.sh - establish a valid $HADOOP_CONF_DIR with all of the
#   configurations necessary to start a Hadoop cluster from within a HPC batch
#   environment.  Additionally format HDFS and leave everything in a state ready
#   for Hadoop to start up via start-all.sh.
#
#   Glenn K. Lockwood, San Diego Supercomputer Center
#   Sriram Krishnan, San Diego Supercomputer Center              Feburary 2014
################################################################################

MH_HOME="$(dirname $(readlink -f $0))/.."

function mh_print {
    echo "myHadoop: $@"
}

function print_usage {
    echo "Usage: $(basename $0) [options]" >&2
    cat <<EOF >&2
    -n <num> 
        specify number of nodes to use.  (default: all nodes from resource 
        manager)

    -p <dir> 
        use persistent HDFS and store namenode and datanode state on the shared 
        filesystem given by <dir> (default: n/a)

    -c <dir>
        build the resulting Hadoop config directory in <dr> (default: from 
        user environment's HADOOP_CONF_DIR or myhadoop.conf)

    -s <dir>
        location of node-local scratch directory where datanode and tasktracker
        will be stored.  (default: user environment's MH_SCRATCH_DIR or 
        myhadoop.conf)

    -h <dir>
        location of Hadoop installation containing the myHadoop configuration
        templates in <dir>/conf and the 'hadoop' executable in <dir>/bin/hadoop
        (default: user environment's HADOOP_HOME or myhadoop.conf)

    -i <regular expression>
        transformation (passed to sed -e) to turn each hostname provided by the
        resource manager into an IP over InfiniBand host.  (default: "")

    -?
        show this help message
EOF

}
if [ "z$1" == "z-?" ]; then
  print_usage
  exit 0
fi

function print_nodelist {
    if [ "z$RESOURCE_MGR" == "zpbs" ]; then
        cat $PBS_NODEFILE | sed -e "$MH_IPOIB_TRANSFORM"
    elif [ "z$RESOURCE_MGR" == "zsge" ]; then
        cat $PE_NODEFILE | sed -e "$MH_IPOIB_TRANSFORM"
    elif [ "z$RESOURCE_MGR" == "zslurm" ]; then
        scontrol show hostname $SLURM_NODELIST | sed -e "$MH_IPOIB_TRANSFORM"
    fi
}

### Read in some system-wide configurations (if applicable) but do not override
### the user's environment
if [ -e "$MH_HOME/etc/myhadoop.conf" ]; then
  while read line; do
    rex='^[^# ]*='
    if [[ $line =~ $rex ]]; then
      variable=$(cut -d = -f1 <<< $line)
      value=$(cut -d = -f 2- <<< $line)
      if [ "z${!variable}" == "z" ]; then
        eval "$variable=$value"
        mh_print "Setting $variable=$value from myhadoop.conf"
      else
        mh_print "Keeping $variable=${!variable} from user environment"
      fi
    fi
  done < $MH_HOME/etc/myhadoop.conf
fi

### Detect our resource manager and populate necessary environment variables
if [ "z$PBS_JOBID" != "z" ]; then
    RESOURCE_MGR="pbs"
elif [ "z$PE_NODEFILE" != "z" ]; then
    RESOURCE_MGR="sge"
elif [ "z$SLURM_JOBID" != "z" ]; then
    RESOURCE_MGR="slurm"
else
    echo "No resource manager detected.  Aborting." >&2
    print_usage
    exit 1
fi

if [ "z$RESOURCE_MGR" == "zpbs" ]; then
    NODES=$PBS_NUM_NODES
    NUMPROCS=$PBS_NP
    JOBID=$PBS_JOBID
elif [ "z$RESOURCE_MGR" == "zsge" ]; then
    NODES=$NHOSTS
    NUMPROCS=$NSLOTS
    JOBID=$JOB_ID
elif [ "z$RESOURCE_MGR" == "zslurm" ]; then
    NODES=$SLURM_NNODES
    NUMPROCS=$SLURM_NPROCS
    JOBID=$SLURM_JOBID
fi

### Parse arguments
args=`getopt n:p:c:s:h:i:? $*`
if test $? != 0
then
    print_usage
    exit 1
fi
set -- $args
for i
do
    case "$i" in
        -n) shift;
            NODES=$1
            shift;;

        -p) shift;
            MH_PERSIST_DIR=$1
            shift;;

        -c) shift;
            HADOOP_CONF_DIR=$1
            shift;;

        -s) shift;
            MH_SCRATCH_DIR=$1
            shift;;

        -h) shift;
            HADOOP_HOME=$1
            shift;;

        -i) shift;
            MH_IPOIB_TRANSFORM=$1
            shift;;
    esac
done

if [ "z$HADOOP_HOME" == "z" ]; then
    if [ "z$HADOOP_PREFIX" == "z" ]; then
        echo 'You must set $HADOOP_HOME before configuring a new cluster.' >&2
        exit 1
    else
        HADOOP_HOME=$HADOOP_PREFIX
    fi
fi
mh_print "Using HADOOP_HOME=$HADOOP_HOME"

if [ "z$MH_SCRATCH_DIR" == "z" ]; then
    echo "You must specify the local disk filesystem location with -s.  Aborting." >&2
    print_usage
    exit 1
fi
mh_print "Using MH_SCRATCH_DIR=$MH_SCRATCH_DIR"

if [ "z$JAVA_HOME" == "z" ]; then
    echo "JAVA_HOME is not defined.  Aborting." >&2
    print_usage
    exit 1
fi
mh_print "Using JAVA_HOME=$JAVA_HOME"

if [ "z$HADOOP_CONF_DIR" == "z" ]; then
    echo "Location of configuration directory not specified.  Aborting." >&2
    print_usage
    exit 1
fi
mh_print "Generating Hadoop configuration in directory in $HADOOP_CONF_DIR..."

### Support for persistent HDFS on a shared filesystem
if [ "z$MH_PERSIST_DIR" != "z" ]; then
    mh_print "Using directory $MH_PERSIST_DIR for persisting HDFS state..."
fi

   
### Create the config directory and begin populating it
if [ -d $HADOOP_CONF_DIR ]; then
    i=0
    while [ -d $HADOOP_CONF_DIR.$i ]
    do
        let i++
    done
    mh_print "Backing up old config dir to $HADOOP_CONF_DIR.$i..."
    mv -v $HADOOP_CONF_DIR $HADOOP_CONF_DIR.$i
fi
mkdir -p $HADOOP_CONF_DIR

### First copy over all default Hadoop configs
if [ -d $HADOOP_HOME/conf ]; then           # Hadoop 1.x
  cp $HADOOP_HOME/conf/* $HADOOP_CONF_DIR
  MH_HADOOP_VERS=1
elif [ -d $HADOOP_HOME/etc/hadoop ]; then   # Hadoop 2.x
  cp $HADOOP_HOME/etc/hadoop/* $HADOOP_CONF_DIR
  MH_HADOOP_VERS=2
fi

##Hbase configuration
HBASE_ZOOKEEPER_NODES=""
# HBASE_IP_NODES=""

if [ -d $HBASE_HOME/conf ]; then
  cp $HBASE_HOME/conf/* $HADOOP_CONF_DIR

  counter=0
  for node in $(print_nodelist);
  do
      if [[ "$counter" -lt 100 ]]; then
	  echo "$node" >> $HADOOP_CONF_DIR/hdfs-nodes
#      elif [[ "$counter" -lt 4 ]]; then
      else
	  echo "$node" >> $HADOOP_CONF_DIR/hbase-nodes
#      else
#	  echo "$node" >> $HADOOP_CONF_DIR/tpc-nodes
      fi
      counter=$(( $counter + 1 ))
  done

  # NODESONEMINUS=$(( $NODES - 1 ))
  # print_nodelist | awk '{print $1}' | sort -u | head -n $NODESONEMINUS > $HADOOP_CONF_DIR/hbase-nodes
  mh_print "The following nodes will be hdfs nodes:"
  cat $HADOOP_CONF_DIR/hdfs-nodes
  mh_print "The following nodes will be hbase nodes:"
  cat $HADOOP_CONF_DIR/hbase-nodes
  # print_nodelist | awk '{print $1}' | sort -u | tail -n 1 > $HADOOP_CONF_DIR/tpc-nodes
#  mh_print "The following nodes will be tpc-iot nodes:"
#  cat $HADOOP_CONF_DIR/tpc-nodes

#  for node in $(cat $HADOOP_CONF_DIR/tpc-nodes);
#  do
#      node1=$(echo ${node%.*})
#      node1="$node1.sdsc.edu"
#      node1=$(dig +short $node1)
#      echo "$node1" >> $HADOOP_CONF_DIR/tpc-nodes-ip
#  done
#  cat $HADOOP_CONF_DIR/tpc-nodes-ip

  cat $HADOOP_CONF_DIR/hdfs-nodes | head -n 1 > $HADOOP_CONF_DIR/hmasters
  cat $HADOOP_CONF_DIR/hdfs-nodes | tail -n 1 > $HADOOP_CONF_DIR/tpc-node
  cat $HADOOP_CONF_DIR/hdfs-nodes | tail -n +2 > $HADOOP_CONF_DIR/regionservers
  mh_print "The following nodes will be hbae master servers:"
  cat $HADOOP_CONF_DIR/hmasters
  mh_print "The following nodes will be region servers:"
  cat $HADOOP_CONF_DIR/regionservers

  for node in $(cat $HADOOP_CONF_DIR/hdfs-nodes);
  do
      node1=$(echo ${node%.*})
#      node1="$node1.local"
      node1="$node1.sdsc.edu"
      node1=$(dig +short $node1)

      HBASE_ZOOKEEPER_NODES="${HBASE_ZOOKEEPER_NODES}${HBASE_ZOOKEEPER_NODES:+,}$node1" 
      # HBASE_IP_NODES="${HBASE_IP_NODES}${HBASE_IP_NODES:+'\n'}$node1"
      # echo "$node1" >> $HADOOP_CONF_DIR/slaves-ip
  done
  # echo "$HBASE_IP_NODES" > $HADOOP_CONF_DIR/slaves-ip
  # echo "$(tail -n +2 $HADOOP_CONF_DIR/slaves-ip)" > $HADOOP_CONF_DIR/slaves-ip
  mh_print "The following nodes will be zookeeper servers:"
  echo "$HBASE_ZOOKEEPER_NODES"
# print_nodelist | awk '{print $1}' | sort -u | head -n $NODES > $HADOOP_CONF_DIR/regionservers
#  print_nodelist | awk '{print $1}' | sort -u | head -n $NODESONEMINUS | tail -n +2 > $HADOOP_CONF_DIR/regionservers

#  for node in $(cat $HADOOP_CONF_DIR/hbase-nodes | sort -u | head -n $NODESONEMINUS);
  for node in $(cat $HADOOP_CONF_DIR/hdfs-nodes);
  do
      node1=$(echo ${node%.*})
#      node1="$node1.local"
      node1="$node1.sdsc.edu"
      node1=$(dig +short $node1)
      echo "$node1" >> $HADOOP_CONF_DIR/slaves-ip
  done
  # echo "$HBASE_IP_NODES" > $HADOOP_CONF_DIR/slaves-ip
  echo "$(tail -n +2 $HADOOP_CONF_DIR/slaves-ip)" > $HADOOP_CONF_DIR/slaves-ip
fi

### Pick the master node as the first node in the nodefile
# MASTER_NODE=$(print_nodelist | /usr/bin/head -n1)
# mh_print "Designating $MASTER_NODE as master node (namenode, secondary namenode, and jobtracker)"
# echo $MASTER_NODE > $HADOOP_CONF_DIR/masters

MASTER_NODE=$(cat $HADOOP_CONF_DIR/hdfs-nodes | /usr/bin/head -n1)
mh_print "Designating $MASTER_NODE as master node (namenode, secondary namenode, and jobtracker)"
echo $MASTER_NODE > $HADOOP_CONF_DIR/masters
node1=$(echo ${MASTER_NODE%.*})
node1="$node1.sdsc.edu"
node1=$(dig +short $node1)
echo "$node1" > $HADOOP_CONF_DIR/masters-ip

### Make every node in the nodefile a slave
# NODESONEMINUS=$(( $NODES - 1 ))
# print_nodelist | awk '{print $1}' | sort -u | head -n $NODESONEMINUS | tail -n +2 > $HADOOP_CONF_DIR/slaves
cat $HADOOP_CONF_DIR/hdfs-nodes | tail -n +2 > $HADOOP_CONF_DIR/slaves
mh_print "The following nodes will be slaves (datanode, tasktracer):"
cat $HADOOP_CONF_DIR/slaves

### Set the Hadoop configuration files to be specific for our job.  Populate
### the subsitutions to be applied to the conf/*.xml files below.  If you update
### the config_subs hash, be sure to also update myhadoop-cleanup.sh to ensure 
### any new directories you define get properly deleted at the end of the job!
cat <<EOF > $HADOOP_CONF_DIR/myhadoop.conf
NODES=$NODES
declare -A config_subs
config_subs[MASTER_NODE]="$MASTER_NODE"
config_subs[MAPRED_LOCAL_DIR]="$MH_SCRATCH_DIR/mapred_scratch"
config_subs[HADOOP_TMP_DIR]="$MH_SCRATCH_DIR/tmp"
config_subs[DFS_NAME_DIR]="$MH_SCRATCH_DIR/namenode_data"
config_subs[DFS_DATA_DIR]="$MH_SCRATCH_DIR/hdfs_data"
config_subs[HADOOP_LOG_DIR]="$MH_SCRATCH_DIR/logs"
config_subs[HADOOP_PID_DIR]="$MH_SCRATCH_DIR/pids"
config_subs[HBASE_ROOTDIR]="$MH_SCRATCH_DIR/hbase"
config_subs[HBASE_ZOOKEEPER_DATADIR]="$MH_SCRATCH_DIR/zookeeper"
config_subs[HBASE_ZOOKEEPER_QUORUM]="$HBASE_ZOOKEEPER_NODES"
EOF

source $HADOOP_CONF_DIR/myhadoop.conf

### And actually apply those substitutions:
for key in "${!config_subs[@]}"; do
  for xml in mapred-site.xml core-site.xml hdfs-site.xml yarn-site.xml hbase-site.xml
  do
    if [ -f $HADOOP_CONF_DIR/$xml ]; then
      sed -i 's#'$key'#'${config_subs[$key]}'#g' $HADOOP_CONF_DIR/$xml
    fi
  done
done

### A few Hadoop file locations are set via environment variables:
cat << EOF >> $HADOOP_CONF_DIR/hadoop-env.sh

# myHadoop alterations for this job:
export HADOOP_LOG_DIR=${config_subs[HADOOP_LOG_DIR]}
export HADOOP_PID_DIR=${config_subs[HADOOP_PID_DIR]}
export YARN_LOG_DIR=${config_subs[HADOOP_LOG_DIR]} # no effect if using Hadoop 1
export YARN_PID_DIR=${config_subs[HADOOP_PID_DIR]} # no effect if using Hadoop 1
export HADOOP_SECURE_DN_PID_DIR=${config_subs[HADOOP_PID_DIR]}
export HADOOP_HOME_WARN_SUPPRESS=TRUE
export JAVA_HOME=$JAVA_HOME
### Jetty leaves garbage in /tmp no matter what \$TMPDIR is; this is an extreme 
### way of preventing that
# export _JAVA_OPTIONS="-Djava.io.tmpdir=${config_subs[HADOOP_TMP_DIR]} $_JAVA_OPTIONS"

# Other job-specific environment variables follow:
EOF

if [ "z$MH_PERSIST_DIR" != "z" ]; then
    ### Link HDFS data directories if persistent mode
    i=0
    for node in $(cat $HADOOP_CONF_DIR/slaves $HADOOP_CONF_DIR/masters | sort -u | head -n $NODES)
    do
        mkdir -p $MH_PERSIST_DIR/$i
        echo "Linking $MH_PERSIST_DIR/$i to ${config_subs[DFS_DATA_DIR]} on $node"
        ssh $node "mkdir -p $(dirname ${config_subs[DFS_DATA_DIR]}); ln -s $MH_PERSIST_DIR/$i ${config_subs[DFS_DATA_DIR]}"
        let i++
    done

    ### Also link namenode data directory so we don't lose metadata on shutdown
    namedir=$(basename ${config_subs[DFS_NAME_DIR]})
    mkdir -p $MH_PERSIST_DIR/$namedir
    for node in $(cat $HADOOP_CONF_DIR/masters | sort -u )
    do
        ssh $node "mkdir -p $(dirname ${config_subs[DFS_NAME_DIR]}); ln -s $MH_PERSIST_DIR/$namedir ${config_subs[DFS_NAME_DIR]}"
    done
fi

### Format HDFS if it does not already exist from persistent mode
if [ ! -e ${config_subs[DFS_NAME_DIR]}/current ]; then
  if [ $MH_HADOOP_VERS -eq 1 ]; then
    HADOOP_CONF_DIR=$HADOOP_CONF_DIR $HADOOP_HOME/bin/hadoop namenode -format -nonInteractive -force
  elif [ $MH_HADOOP_VERS -eq 2 ]; then
    HADOOP_CONF_DIR=$HADOOP_CONF_DIR $HADOOP_HOME/bin/hdfs namenode -format
  else
    mh_print "Unknown Hadoop version.  You must format namenode manually."
  fi
fi

### Enable Spark support if SPARK_HOME is defined
if [ "z$SPARK_HOME" != "z" ]; then
  mh_print " "
  mh_print "Enabling experimental Spark support"
  if [ "z$SPARK_CONF_DIR" == "z" ]; then
    SPARK_CONF_DIR=$HADOOP_CONF_DIR/spark
  fi
  mh_print "Using SPARK_CONF_DIR=$SPARK_CONF_DIR"
  mh_print " "

  mkdir -p $SPARK_CONF_DIR
  cp $SPARK_HOME/conf/* $SPARK_CONF_DIR/
  cp $HADOOP_CONF_DIR/slaves $SPARK_CONF_DIR/slaves

  cat <<EOF >> $SPARK_CONF_DIR/spark-env.sh
export SPARK_CONF_DIR=$SPARK_CONF_DIR
export SPARK_MASTER_IP=$MASTER_NODE
export SPARK_MASTER_PORT=7077
export SPARK_WORKER_DIR=$MH_SCRATCH_DIR/work
export SPARK_LOG_DIR=$MH_SCRATCH_DIR/logs

### pyspark shell requires this environment variable be set to work
export MASTER=spark://$MASTER_NODE:7077

### push out the local environment to all slaves so that any loaded modules
### from the user environment are honored by the execution environment
export PATH=$PATH
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH

### to prevent Spark from binding to the first address it can find
export SPARK_LOCAL_IP=\$(sed -e '$MH_IPOIB_TRANSFORM' <<< \$HOSTNAME)
EOF

cat <<EOF
To use Spark, you will want to type the following commands:"
  source $SPARK_CONF_DIR/spark-env.sh
  myspark start
EOF
fi