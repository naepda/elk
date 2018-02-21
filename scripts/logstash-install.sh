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
    echo "This script installs Logstash on Ubuntu"
    echo "Parameters:"
    echo "-n elasticsearch cluster name"
    echo "-v elasticsearch version 2.3.3"
    echo "-p hostname prefix of nodes for unicast discovery"

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

log "Begin execution of Logstash Install script extension"
START_TIME=$SECONDS

export DEBIAN_FRONTEND=noninteractive
export RETURN_HOME="/opt/logstash"
export SETTING_WORK_HOME="/datadisk/disk1"

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
    Z) #number of logstash hints (used to calculate minimum master nodes)
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
# Installation steps as functions
#########################

# Format data disks (Find data disks then partition, format, and mount them as seperate drives)
format_data_disks()
{
  log "[format_data_disks] starting partition and format attached disks"
  # using the -s paramater causing disks under /datadisk/* to be raid0'ed
  bash vm-disk-utils-0.1.sh -s
  EXIT_CODE=$?
  if [ $EXIT_CODE -ne 0 ]; then
    log "[format_data_disks] returned non-zero exit code: $EXIT_CODE"
    exit $EXIT_CODE
  fi
  log "[format_data_disks] finished partition and format attached disks"
}

# Configure Logstash Data Disk Folder and Permissions
setup_data_disk()
{
  local RAIDDISK="$SETTING_WORK_HOME"
  log "[setup_data_disk] Configuring disk $RAIDDISK/data"
  sudo mkdir -p "$RAIDDISK/data"
  sudo chown -R elk4sa:elk4sa "$RAIDDISK"
  sudo chmod -R 777 "$RAIDDISK"
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

# Install Logstash
install_logstash()
{
    if [[ "${ES_VERSION}" == \2* ]]; then
        DOWNLOAD_URL="https://download.elasticsearch.org/logstash/release/org/logstash/distribution/deb/logstash/$ES_VERSION/logstash-$ES_VERSION.deb?ultron=msft&gambit=azure"
    elif [[ "${ES_VERSION}" == \5* ]]; then
        DOWNLOAD_URL="https://artifacts.elastic.co/downloads/logstash/logstash-$ES_VERSION.tar.gz?ultron=msft&gambit=azure"
    elif [[ "${ES_VERSION}" == \6* ]]; then
        DOWNLOAD_URL="https://artifacts.elastic.co/downloads/logstash/logstash-$ES_VERSION.tar.gz?ultron=msft&gambit=azure"
    else
        DOWNLOAD_URL="https://download.elasticsearch.org/logstash/logstash/logstash-$ES_VERSION.deb"
    fi
    log "[install_logstash] Installing Logstash Version - $ES_VERSION"
    log "[install_logstash] Download location - $DOWNLOAD_URL"
    sudo wget -q "$DOWNLOAD_URL" -O logstash.tar.gz
    log "[install_logstash] Downloaded logstash $ES_VERSION"
    sudo mkdir -p ${RETURN_HOME}
    sudo mv logstash.tar.gz ${RETURN_HOME}/logstash.tar.gz
    cd ${RETURN_HOME}
    sudo tar -xvf ./logstash.tar.gz
    sudo cp -r ./logstash-$ES_VERSION ./cesa-selfserving
    sudo mv ./logstash-$ES_VERSION ./blobdownload

    sudo mkdir -p ${RETURN_HOME}/blobdownload/install_gem
    sudo mkdir -p ${RETURN_HOME}/cesa-selfserving/install_gem

    sudo adduser logstash --disabled-password

    sudo chown elk4sa:elk4sa -R ./blobdownload
    sudo chown elk4sa:elk4sa -R ./cesa-selfserving
    sudo chmod 775 -R ./blobdownload
    sudo chmod 775 -R ./cesa-selfserving

    sudo chmod 777 -R ${RETURN_HOME}/blobdownload/install_gem/
    sudo chmod 777 -R ${RETURN_HOME}/cesa-selfserving/install_gem/

    cd ${RETURN_HOME}
    DOWNLOAD_GEM_URL = "https://raw.githubusercontent.com/naepda/elk_environment/master/logstash_plugin/logstash-input-azureblobdownload-0.9.8.gem"
    sudo wget -q "$DOWNLOAD_GEM_URL" -O logstash-input-azureblobdownload-0.9.8.gem

    sudo cp ./logstash-input-azureblobdownload-0.9.8.gem ${RETURN_HOME}/cesa-selfserving/install_gem/
    sudo cp ./logstash-input-azureblobdownload-0.9.8.gem ${RETURN_HOME}/blobdownload/install_gem/


    cd ${RETURN_HOME}/cesa-selfserving/bin
    sudo ./logstash-plugin install logstash-input-azureblob
    sudo ./logstash-plugin install logstash-filter-date_formatter
    sudo ./logstash-plugin install ${RETURN_HOME}/cesa-selfserving/install_gem/logstash-input-azureblobdownload-0.9.8.gem

    cd ${RETURN_HOME}/blobdownload/bin
    cd ./bin
    sudo ./logstash-plugin install logstash-input-azureblob
    sudo ./logstash-plugin install logstash-filter-date_formatter
    sudo ./logstash-plugin install ${RETURN_HOME}/blobdownload/install_gem/logstash-input-azureblobdownload-0.9.8.gem

    cd ${RETURN_HOME}

    log "[install_logstash] Installed Logstash Version - $ES_VERSION"
}

configure_logstash()
{
    log "[configure_logstash] configuring logstash default configuration"
    local ES_HEAP=`free -m |grep Mem | awk '{if ($2/2 >31744) print 31744;else print int($2/2+0.5);}'`
    if [[ "${ES_VERSION}" == \5* ]]; then
      configure_logstash5 $ES_HEAP
    elif [[ "${ES_VERSION}" == \6* ]]; then
      configure_logstash6 $ES_HEAP
    else
      configure_logstash5 $ES_HEAP
    fi
    log "[configure_logstash] configured logstash default configuration"
}

configure_logstash5()
{
    log "[configure_logstash] Configure logstash 5.x heap size - $1"
    echo "-Xmx$1m" >> ${RETURN_HOME}/blobdownload/config/jvm.options
    echo "-Xms$1m" >> ${RETURN_HOME}/blobdownload/config/jvm.options
    echo "-Xmx$1m" >> ${RETURN_HOME}/cesa-selfserving/config/jvm.options
    echo "-Xms$1m" >> ${RETURN_HOME}/cesa-selfserving/config/jvm.options
}

configure_logstash6()
{
    log "[configure_logstash] Configure logstash 6.x heap size - $1"
    echo "-Xmx$1m" >> ${RETURN_HOME}/blobdownload/config/jvm.options
    echo "-Xms$1m" >> ${RETURN_HOME}/blobdownload/config/jvm.options
    echo "-Xmx$1m" >> ${RETURN_HOME}/cesa-selfserving/config/jvm.options
    echo "-Xms$1m" >> ${RETURN_HOME}/cesa-selfserving/config/jvm.options
}

format_data_disks

setup_data_disk

install_java

install_logstash


ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))

log "End execution of Logstash script extension on ${HOSTNAME} in ${PRETTY}"
# exit 0