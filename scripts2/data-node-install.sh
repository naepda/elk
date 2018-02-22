#!/bin/bash

# License: https://github.com/elastic/azure-marketplace/blob/master/LICENSE.txt
#
# Trent Swanson (Full Scale 180 Inc)
# Martijn Laarman, Greg Marzouka, Russ Cam (Elastic)
# Contributors
#

#########################
# HELP
#########################

help()
{
    echo "This script bootstraps an Elasticsearch cluster on a data node"
    echo "Parameters:"
    echo "-n elasticsearch cluster name"
    echo "-v elasticsearch version 2.3.3"
    echo "-p hostname prefix of nodes for unicast discovery"

    echo "-d cluster uses dedicated masters"
    echo "-Z <number of nodes> hint to the install script how many data nodes we are provisioning"

    echo "-h view this help content"
}
# Custom logging with time so we can easily relate running times, also log to separate file so order is guaranteed.
# The Script extension output the stdout/err buffer in intervals with duplicates.
log()
{
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1"
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1" >> /var/log/arm-install.log
}

log "Begin execution of Elasticsearch script extension on ${HOSTNAME}"
START_TIME=$SECONDS

export DEBIAN_FRONTEND=noninteractive

#########################
# Preconditions
#########################

if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi

# TEMP FIX - Re-evaluate and remove when possible
# This is an interim fix for hostname resolution in current VM
grep -q "${HOSTNAME}" /etc/hosts
if [ $? == 0 ]
then
  log "${HOSTNAME}found in /etc/hosts"
else
  log "${HOSTNAME} not found in /etc/hosts"
  # Append it to the hsots file if not there
  echo "127.0.0.1 ${HOSTNAME}" >> /etc/hosts
  log "hostname ${HOSTNAME} added to /etchosts"
fi

#########################
# Paramater handling
#########################

CLUSTER_NAME="elasticsearch"
NAMESPACE_PREFIX=""
ES_VERSION="5.3.0"

DATANODE_COUNT=0

CLIENT_ONLY_NODE=0
DATA_ONLY_NODE=0
MASTER_ONLY_NODE=0

CLUSTER_USES_DEDICATED_MASTERS=0

MINIMUM_MASTER_NODES=3
UNICAST_HOSTS='["'"$NAMESPACE_PREFIX"'master-0:9300","'"$NAMESPACE_PREFIX"'master-1:9300","'"$NAMESPACE_PREFIX"'master-2:9300"]'

UBUNTU_VERSION=$(lsb_release -sr)


#Loop through options passed
while getopts :n:v:Z:p:h optname; do
  log "Option $optname set"
  case $optname in
    n) #set cluster name
      CLUSTER_NAME="${OPTARG}"
      ;;
    v) #elasticsearch version number
      ES_VERSION="${OPTARG}"
      ;;
    Z) #number of data nodes hints (used to calculate minimum master nodes)
      DATANODE_COUNT=${OPTARG}
      ;;
    p) #namespace prefix for nodes
      NAMESPACE_PREFIX="${OPTARG}"
      ;;
    h) #show help
      help
      exit 2
      ;;
    \?) #unrecognized option - show help
      echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed."
      help
      exit 2
      ;;
  esac
done

#########################
# Parameter state changes
#########################

if [ ${CLUSTER_USES_DEDICATED_MASTERS} -ne 0 ]; then
    MINIMUM_MASTER_NODES=2
    UNICAST_HOSTS='["'"$NAMESPACE_PREFIX"'master-0:9300","'"$NAMESPACE_PREFIX"'master-1:9300","'"$NAMESPACE_PREFIX"'master-2:9300"]'
else
    MINIMUM_MASTER_NODES=$(((DATANODE_COUNT/2)+1))
    UNICAST_HOSTS='['
    for i in $(seq 0 $((DATANODE_COUNT-1))); do
        UNICAST_HOSTS="$UNICAST_HOSTS\"${NAMESPACE_PREFIX}data-$i:9300\","
    done
    UNICAST_HOSTS="${UNICAST_HOSTS%?}]"
fi

log "Bootstrapping an Elasticsearch $ES_VERSION cluster named '$CLUSTER_NAME' with minimum_master_nodes set to $MINIMUM_MASTER_NODES"
log "Cluster uses dedicated master nodes is set to $CLUSTER_USES_DEDICATED_MASTERS and unicast goes to $UNICAST_HOSTS"
log "Cluster install plugins is set to $INSTALL_PLUGINS"


#########################
# Installation steps as functions
#########################

# Format data disks (Find data disks then partition, format, and mount them as seperate drives)
format_data_disks()
{
    log "[format_data_disks] checking node role"
    if [ ${MASTER_ONLY_NODE} -eq 1 ]; then
        log "[format_data_disks] master node, no data disks attached"
    elif [ ${CLIENT_ONLY_NODE} -eq 1 ]; then
        log "[format_data_disks] client node, no data disks attached"
    else
        log "[format_data_disks] data node, data disks may be attached"
        log "[format_data_disks] starting partition and format attached disks"
        # using the -s paramater causing disks under /datadisk/* to be raid0'ed
        bash vm-disk-utils-0.1.sh -s
        EXIT_CODE=$?
        if [ $EXIT_CODE -ne 0 ]; then
          log "[format_data_disks] returned non-zero exit code: $EXIT_CODE"
          exit $EXIT_CODE
        fi
        log "[format_data_disks] finished partition and format attached disks"
    fi
}

# Configure Elasticsearch Data Disk Folder and Permissions
setup_data_disk()
{
    if [ -d "/datadisk" ]; then
        local RAIDDISK="/datadisk/disk1"
        log "[setup_data_disk] Configuring disk $RAIDDISK/elasticsearch/data"
        mkdir -p "$RAIDDISK/elasticsearch/data"
        chown -R elasticsearch:elasticsearch "$RAIDDISK/elasticsearch"
        chmod 775 "$RAIDDISK/elasticsearch"
    elif [ ${MASTER_ONLY_NODE} -eq 0 -a ${CLIENT_ONLY_NODE} -eq 0 ]; then
        local TEMPDISK="/mnt"
        log "[setup_data_disk] Configuring disk $TEMPDISK/elasticsearch/data"
        mkdir -p "$TEMPDISK/elasticsearch/data"
        chown -R elasticsearch:elasticsearch "$TEMPDISK/elasticsearch"
        chmod 775 "$TEMPDISK/elasticsearch"
    else
        #If we do not find folders/disks in our data disk mount directory then use the defaults
        log "[setup_data_disk] Configured data directory does not exist for ${HOSTNAME}. using defaults"
    fi
}

# Check Data Disk Folder and Permissions
check_data_disk()
{
    if [ ${MASTER_ONLY_NODE} -eq 0 -a ${CLIENT_ONLY_NODE} -eq 0 ]; then
        log "[check_data_disk] data node checking data directory"
        if [ -d "/datadisk" ]; then
            log "[check_data_disk] Data disks attached and mounted at /datadisk"
        elif [ -d "/mnt/elasticsearch/data" ]; then
            log "[check_data_disk] Data directory at /mnt/elasticsearch/data"
        else
            #this could happen when the temporary disk is lost and a new one mounted
            local TEMPDISK="/mnt"
            log "[check_data_disk] No data directory at /mnt/elasticsearch/data dir"
            log "[setup_data_disk] Configuring disk $TEMPDISK/elasticsearch/data"
            mkdir -p "$TEMPDISK/elasticsearch/data"
            chown -R elasticsearch:elasticsearch "$TEMPDISK/elasticsearch"
            chmod 775 "$TEMPDISK/elasticsearch"
        fi
    fi
}

# Install Oracle Java
install_java()
{
    log "[install_java] Adding apt repository for java 8"
    (add-apt-repository -y ppa:webupd8team/java || (sleep 15; add-apt-repository -y ppa:webupd8team/java))
    log "[install_java] updating apt-get"

    (apt-get -y update || (sleep 15; apt-get -y update)) > /dev/null
    log "[install_java] updated apt-get"
    echo debconf shared/accepted-oracle-license-v1-1 select true | sudo debconf-set-selections
    echo debconf shared/accepted-oracle-license-v1-1 seen true | sudo debconf-set-selections
    log "[install_java] Installing Java"
    (apt-get -yq install oracle-java8-installer || (sleep 15; apt-get -yq install oracle-java8-installer))
    command -v java >/dev/null 2>&1 || { sleep 15; sudo rm /var/cache/oracle-jdk8-installer/jdk-*; sudo apt-get install -f; }

    #if the previus did not install correctly we go nuclear, otherwise this loop will early exit
    for i in $(seq 30); do
      if $(command -v java >/dev/null 2>&1); then
        log "[install_java] Installed java!"
        return
      else
        sleep 5
        sudo rm /var/cache/oracle-jdk8-installer/jdk-*;
        sudo rm -f /var/lib/dpkg/info/oracle-java8-installer*
        sudo rm /etc/apt/sources.list.d/*java*
        sudo apt-get -yq purge oracle-java8-installer*
        sudo apt-get -yq autoremove
        sudo apt-get -yq clean
        (add-apt-repository -y ppa:webupd8team/java || (sleep 15; add-apt-repository -y ppa:webupd8team/java))
        sudo apt-get -yq update
        sudo apt-get -yq install --reinstall oracle-java8-installer
        log "[install_java] Seeing if java is Installed after nuclear retry ${i}/30"
      fi
    done
    command -v java >/dev/null 2>&1 || { log "Java did not get installed properly even after a retry and a forced installation" >&2; exit 50; }
}

# Install Elasticsearch
install_es()
{
    if [[ "${ES_VERSION}" == \2* ]]; then
        DOWNLOAD_URL="https://download.elasticsearch.org/elasticsearch/release/org/elasticsearch/distribution/deb/elasticsearch/$ES_VERSION/elasticsearch-$ES_VERSION.deb?ultron=msft&gambit=azure"
    elif [[ "${ES_VERSION}" == \5* ]]; then
        DOWNLOAD_URL="https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$ES_VERSION.deb?ultron=msft&gambit=azure"
    elif [[ "${ES_VERSION}" == \6* ]]; then
        DOWNLOAD_URL="https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-$ES_VERSION.deb?ultron=msft&gambit=azure"
    else
        DOWNLOAD_URL="https://download.elasticsearch.org/elasticsearch/elasticsearch/elasticsearch-$ES_VERSION.deb"
    fi
    log "[install_es] Installing Elasticsearch Version - $ES_VERSION"
    log "[install_es] Download location - $DOWNLOAD_URL"
    sudo wget -q "$DOWNLOAD_URL" -O elasticsearch.deb
    log "[install_es] Downloaded elasticsearch $ES_VERSION"
    sudo dpkg -i elasticsearch.deb
    log "[install_es] Installed Elasticsearch Version - $ES_VERSION"

    log "[install_es] Disable Elasticsearch System-V style init scripts (will be using monit)"
    sudo update-rc.d elasticsearch disable
}

# Configure Elasticsearch Folder and Permissions.
# Create sh file for daily remove expired eslogfiles.
permissions_es_and_remove_logfile()
{
    local REMOVE_LOGFILE=/usr/share/elasticsearch/commands/utils/daily_remove_expired_eslogfiles_v1_0_171228.sh
    sudo chmod 777 -R /datadisk
    sudo chown elk4sa:elk4sa -R /datadisk
    sudo chmod 777 -R /var/log/elasticsearch/
    sudo mkdir -p /usr/share/elasticsearch/commands/utils/
    sudo chown elk4sa:elk4sa -R /usr/share/elasticsearch
    sudo chmod 775 -R /usr/share/elasticsearch
    sudo chmod 775 -R /etc/elasticsearch/
    sudo touch $REMOVE_LOGFILE
    sudo chmod 777 $REMOVE_LOGFILE
    sudo echo -e "#! /bin/bash\n\n# daily (log files) deleted by crontab on Ubuntu 16.04 LTS\nsudo find /var/log/elasticsearch/ -type f -name \"elk4sa-prd-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log\" -mtime +7 -exec rm -f {} \;" >> $REMOVE_LOGFILE
    (sudo crontab -u root -l; echo "0 2 * * * $REMOVE_LOGFILE" ) | sudo crontab -u root -
}
## Configuration
##----------------------------------

configure_elasticsearch_yaml()
{
    # Backup the current Elasticsearch configuration file
    mv /etc/elasticsearch/elasticsearch.yml /etc/elasticsearch/elasticsearch.yml.bak
    local ES_CONF=/etc/elasticsearch/elasticsearch.yml
    # Set cluster and machine names - just use hostname for our node.name
    echo "cluster.name: $CLUSTER_NAME" >> $ES_CONF
    echo "node.name: ${HOSTNAME}" >> $ES_CONF

    # Check if data disks are attached. If they are then use them, otherwise if this is a data node, use the temporary disk
    local DATAPATH_CONFIG=""
    if [ -d "/datadisk" ]; then
        DATAPATH_CONFIG="/datadisk/disk1/elasticsearch/data"
    elif [ ${MASTER_ONLY_NODE} -eq 0 -a ${CLIENT_ONLY_NODE} -eq 0 ]; then
        DATAPATH_CONFIG="/mnt/elasticsearch/data"
    fi

    if [ -n "$DATAPATH_CONFIG" ]; then
        log "[configure_elasticsearch_yaml] Update configuration with data path list of $DATAPATH_CONFIG"
        echo "path.data: $DATAPATH_CONFIG" >> $ES_CONF
    fi

    # Configure discovery
    log "[configure_elasticsearch_yaml] Update configuration with hosts configuration of $UNICAST_HOSTS"
    echo "discovery.zen.ping.unicast.hosts: $UNICAST_HOSTS" >> $ES_CONF

    # Configure Elasticsearch node type
    log "[configure_elasticsearch_yaml] Configure master/client/data node type flags master-$MASTER_ONLY_NODE data-$DATA_ONLY_NODE"

    if [ ${MASTER_ONLY_NODE} -ne 0 ]; then
        log "[configure_elasticsearch_yaml] Configure node as master only"
        echo "node.master: true" >> $ES_CONF
        echo "node.data: false" >> $ES_CONF
        # echo "marvel.agent.enabled: false" >> $ES_CONF
    elif [ ${DATA_ONLY_NODE} -ne 0 ]; then
        log "[configure_elasticsearch_yaml] Configure node as data only"
        echo "node.master: false" >> $ES_CONF
        echo "node.data: true" >> $ES_CONF
        # echo "marvel.agent.enabled: false" >> $ES_CONF
    elif [ ${CLIENT_ONLY_NODE} -ne 0 ]; then
        log "[configure_elasticsearch_yaml] Configure node as client only"
        echo "node.master: false" >> $ES_CONF
        echo "node.data: false" >> $ES_CONF
        # echo "marvel.agent.enabled: false" >> $ES_CONF
    else
        log "[configure_elasticsearch_yaml] Configure node as master and data"
        echo "node.master: true" >> $ES_CONF
        echo "node.data: true" >> $ES_CONF
    fi

    echo "discovery.zen.minimum_master_nodes: $MINIMUM_MASTER_NODES" >> $ES_CONF

    if [[ "${ES_VERSION}" == \5* ]]; then
        echo "network.host: [_site_, _local_]" >> $ES_CONF
    elif [[ "${ES_VERSION}" == \6* ]]; then
        echo "network.host: [_site_, _local_]" >> $ES_CONF
    else
        echo "discovery.zen.ping.multicast.enabled: false" >> $ES_CONF
        echo "network.host: _non_loopback_" >> $ES_CONF
        echo "marvel.agent.enabled: true" >> $ES_CONF
    fi

    echo "node.max_local_storage_nodes: 1" >> $ES_CONF

    echo "script.painless.regex.enabled: true" >> $ES_CONF

    echo "thread_pool.search.queue_size: 10000" >> $ES_CONF
    echo "thread_pool.bulk.queue_size: 100" >> $ES_CONF
}

configure_elasticsearch()
{
    log "[configure_elasticsearch] configuring elasticsearch default configuration"
    local ES_HEAP=`free -m |grep Mem | awk '{if ($2/2 >31744) print 31744;else print int($2/2+0.5);}'`
    if [[ "${ES_VERSION}" == \5* ]]; then
      configure_elasticsearch5 $ES_HEAP
    elif [[ "${ES_VERSION}" == \6* ]]; then
      configure_elasticsearch6 $ES_HEAP
    else
      configure_elasticsearch5 $ES_HEAP
    fi
    log "[configure_elasticsearch] configured elasticsearch default configuration"
}

configure_elasticsearch5()
{
    log "[configure_elasticsearch] Configure elasticsearch 5.x heap size - $1"
    echo "-Xmx$1m" >> /etc/elasticsearch/jvm.options
    echo "-Xms$1m" >> /etc/elasticsearch/jvm.options
}

configure_elasticsearch6()
{
    log "[configure_elasticsearch] Configure elasticsearch 6.x heap size - $1"
    echo "-Xmx$1m" >> /etc/elasticsearch/jvm.options
    echo "-Xms$1m" >> /etc/elasticsearch/jvm.options
}

configure_os_properties()
{
    log "[configure_os_properties] configuring operating system level configuration"
    # DNS Retry
    echo "options timeout:10 attempts:5" >> /etc/resolvconf/resolv.conf.d/head
    resolvconf -u

    # Increase maximum mmap count
    echo "vm.max_map_count = 262144" >> /etc/sysctl.conf

    # Verify this is necessary on azure
    # ML: 80% certain i verified this but will do so again
    #echo "elasticsearch    -    nofile    65536" >> /etc/security/limits.conf
    #echo "elasticsearch     -    memlock   unlimited" >> /etc/security/limits.conf
    #echo "session    required    pam_limits.so" >> /etc/pam.d/su
    #echo "session    required    pam_limits.so" >> /etc/pam.d/common-session
    #echo "session    required    pam_limits.so" >> /etc/pam.d/common-session-noninteractive
    #echo "session    required    pam_limits.so" >> /etc/pam.d/sudo
    log "[configure_os_properties] configured operating system level configuration"
}

install_ntp()
{
    log "[install_ntp] installing ntp daemon"
    (apt-get -yq install ntp || (sleep 15; apt-get -yq install ntp))
    ntpdate pool.ntp.org
    log "[install_ntp] installed ntp daemon and ntpdate"
}

install_monit()
{
    log "[install_monit] installing monit"
    (apt-get -yq install monit || (sleep 15; apt-get -yq install monit))
    echo "set daemon 30" >> /etc/monit/monitrc
    echo "set httpd port 2812 and" >> /etc/monit/monitrc
    echo "    use address localhost" >> /etc/monit/monitrc
    echo "    allow localhost" >> /etc/monit/monitrc
    sudo touch /etc/monit/conf.d/elasticsearch.conf
    echo "check process elasticsearch with pidfile \"/var/run/elasticsearch/elasticsearch.pid\"" >> /etc/monit/conf.d/elasticsearch.conf
    echo "  group elasticsearch" >> /etc/monit/conf.d/elasticsearch.conf
    echo "  start program = \"/etc/init.d/elasticsearch start\"" >> /etc/monit/conf.d/elasticsearch.conf
    echo "  stop program = \"/etc/init.d/elasticsearch stop\"" >> /etc/monit/conf.d/elasticsearch.conf
    log "[install_monit] installed monit"
}

start_monit()
{
    log "[start_monit] starting monit"
    sudo /etc/init.d/monit start
    sudo monit reload # use the new configuration
    sudo monit start all
    log "[start_monit] started monit"
}

port_forward()
{
    log "[port_forward] setting up port forwarding from 9201 to 9200"
    #redirects 9201 > 9200 locally
    #this to overcome a limitation in ARM where to vm loadbalancers can route on the same backed ports
    sudo iptables -t nat -I PREROUTING -p tcp --dport 9201 -j REDIRECT --to-ports 9200
    sudo iptables -t nat -I OUTPUT -p tcp -o lo --dport 9201 -j REDIRECT --to-ports 9200

    #install iptables-persistent to restore configuration after reboot
    log "[port_forward] installing iptables-persistent"
    (apt-get -yq install iptables-persistent || (sleep 15; apt-get -yq install iptables-persistent))

    # iptables-persistent is different on 16 compared to 14
    if [[ "${UBUNTU_VERSION}" == "16"* ]]; then
      sudo service netfilter-persistent save
      sudo service netfilter-persistent start
      # add netfilter-persistent to startup before elasticsearch
      sudo update-rc.d netfilter-persistent defaults 90 15
    else
      #persist the rules to file
      sudo service iptables-persistent save
      sudo service iptables-persistent start
      # add iptables-persistent to startup before elasticsearch
      sudo update-rc.d iptables-persistent defaults 90 15
    fi

    log "[port_forward] installed iptables-persistent"
    log "[port_forward] port forwarding configured"
}

#########################
# Installation sequence
#########################


# if elasticsearch is already installed assume this is a redeploy
# change yaml configuration and only restart the server when needed
if sudo monit status elasticsearch >& /dev/null; then

  configure_elasticsearch_yaml

  # if this is a data node using temp disk, check existence and permissions
  check_data_disk

  # restart elasticsearch if the configuration has changed
  cmp --silent /etc/elasticsearch/elasticsearch.yml /etc/elasticsearch/elasticsearch.bak \
    || sudo monit restart elasticsearch

  exit 0
fi

format_data_disks

install_ntp

install_java

install_es

setup_data_disk

permissions_es_and_remove_logfile

install_monit

configure_elasticsearch_yaml

configure_elasticsearch

configure_os_properties

start_monit

port_forward

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

log "End execution of Elasticsearch script extension on ${HOSTNAME} in ${PRETTY}"
# exit 0