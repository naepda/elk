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
    echo "This script installs kibana on a dedicated VM in the elasticsearch ARM template cluster"
    echo "Parameters:"
    echo "-n elasticsearch cluster name"
    echo "-v kibana version e.g 4.2.1"
    echo "-e elasticsearch version e.g 2.3.1"
    echo "-u elasticsearch url e.g. http://10.0.0.4:9200"

    echo "-h view this help content"
}

# Custom logging with time so we can easily relate running times, also log to separate file so order is guaranteed.
# The Script extension output the stdout/err buffer in intervals with duplicates.
log()
{
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1"
    echo \[$(date +%d%m%Y-%H:%M:%S)\] "$1" >> /var/log/arm-install.log
}

log "Begin execution of Kibana script extension on ${HOSTNAME}"
START_TIME=$SECONDS

export DEBIAN_FRONTEND=noninteractive
export RETURN_HOME="/etc/kibana"

if service --status-all | grep -Fq 'kibana'; then
  log "Kibana already installed"
  exit 0
fi

#########################
# Parameter handling
#########################

#Script Parameters
CLUSTER_NAME="elasticsearch"
KIBANA_VERSION="5.3.0"
ES_VERSION="5.3.0"
#Default internal load balancer ip
ELASTICSEARCH_URL="http://10.0.0.4:9200"

#Loop through options passed
while getopts :n:v:e:u:h optname; do
  log "Option $optname set"
  case $optname in
    n) #set cluster name
      CLUSTER_NAME="${OPTARG}"
      ;;
    v) #kibana version number
      KIBANA_VERSION="${OPTARG}"
      ;;
    e) #elasticsearch version number
      ES_VERSION="${OPTARG}"
      ;;
    u) #elasticsearch url
      ELASTICSEARCH_URL="${OPTARG}"
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

log "installing kibana $KIBANA_VERSION for Elasticsearch $ES_VERSION cluster: $CLUSTER_NAME"
log "installing kibana plugins is set to: $INSTALL_PLUGINS"
log "Kibana will talk to elasticsearch over $ELASTICSEARCH_URL"

#########################
# Installation steps as functions
#########################

download_install_deb()
{
    log "[download_install_deb] starting download of package"
    local DOWNLOAD_URL="https://artifacts.elastic.co/downloads/kibana/kibana-$KIBANA_VERSION-amd64.deb"
    curl -o "kibana-$KIBANA_VERSION.deb" "$DOWNLOAD_URL"
    log "[download_install_deb] installing downloaded package"
    sudo dpkg -i "kibana-$KIBANA_VERSION.deb"
}

configuration_and_plugins()
{
    # backup the current config
    mv /etc/kibana/kibana.yml /etc/kibana/kibana.yml.bak

    log "[configuration_and_plugins] configuring kibana.yml"
    local KIBANA_CONF=/etc/kibana/kibana.yml
    # set the elasticsearch URL
    echo "elasticsearch.url: \"$ELASTICSEARCH_URL\"" >> $KIBANA_CONF
    echo "server.host:" $(hostname -I) >> $KIBANA_CONF
    # specify kibana log location
    echo "logging.dest: /var/log/kibana.log" >> $KIBANA_CONF
    sudo touch /var/log/kibana.log
    sudo chown kibana: /var/log/kibana.log
    # set logging to silent by default
    echo "logging.silent: true" >> $KIBANA_CONF
    # set elasticsearch.requestTimeout
    echo "elasticsearch.requestTimeout: 180000" >> $KIBANA_CONF

    # install plugins
    log "[install plugin] download kbn_searchtables plugin"
    local DOWNLOAD_URL="https://github.com/dlumbrer/kbn_searchtables/releases/download/6.X-1/kbn_searchtables.tar.gz"
    sudo wget -q "$DOWNLOAD_URL" -O kbn_searchtables.tar.gz

    sudo mkdir -p /usr/share/kibana/install_plugins
    sudo chmod 777 -R /usr/share/kibana/install_plugins/

    cd /usr/share/kibana/
    sudo chown kibana:kibana -R ./plugins
    sudo chmod 775 -R ./plugins

    adduser kibana --disabled-password

    log "[install plugin] move kbn_searchtables plugin"
    sudo mv kbn_searchtables.tar.gz /usr/share/kibana/install_plugins/kbn_searchtables.tar.gz
    cd /usr/share/kibana/install_plugins/
    sudo tar -xvf ./kbn_searchtables.tar.gz
    sudo mv /usr/share/kibana/install_plugins/kbn_searchtables /usr/share/kibana/plugins/kbn_searchtables
}

install_start_service()
{
    log "[install_start_service] configuring service for kibana to run at start"
    sudo update-rc.d kibana defaults 95 10
    log "[install_start_service] starting kibana!"
    sudo service kibana start
}

reboot_start()
{
    local REBOOT_START=/usr/share/kibana/commands/utils/reboot_start.sh
    sudo chmod 777 -R /var/log/kibana/
    # sudo chown elk4sa:elk4sa -R /usr/share/kibana
    sudo chmod 775 -R /usr/share/kibana
    sudo chmod 775 -R /etc/kibana/
    mkdir -p /usr/share/kibana/commands/utils/
    sudo touch $REBOOT_START
    sudo chmod 777 $REBOOT_START
    echo -e "#! /bin/bash\n\nsudo /usr/share/kibana/bin/kibana &" >> $REBOOT_START
    (sudo crontab -u root -l; echo "@reboot $REBOOT_START" ) | sudo crontab -u root -
}

install_sequence()
{
    log "[install_sequence] Starting installation"
    download_install_deb
    configuration_and_plugins
    install_start_service
    reboot_start
    log "[install_sequence] Finished installation"
}

#########################
# Installation sequence
#########################

install_sequence

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))
log "End execution of Kibana script extension in ${PRETTY}"
# exit 0