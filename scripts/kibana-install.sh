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
    # echo "-l install plugins true/false"
    # echo "-S kibana server password"
    # echo "-C kibana cert to encrypt communication between the browser and Kibana"
    # echo "-K kibana key to encrypt communication between the browser and Kibana"
    # echo "-P kibana key passphrase to decrypt the private key (optional as the key may not be encrypted)"
    # echo "-m <internal/external> hints whether to use the internal loadbalancer or internal client node (when external loadbalancing)"

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
# INSTALL_PLUGINS=0
# HOSTMODE="internal"
# USER_KIBANA4_SERVER_PWD="changeME"
# SSL_CERT=""
# SSL_KEY=""
# SSL_PASSPHRASE=""

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
    # S) #security kibana server pwd
    #   USER_KIBANA4_SERVER_PWD="${OPTARG}"
    #   ;;
    # m) #security kibana server pwd
    #   HOSTMODE="${OPTARG}"
    #   ;;
    # l) #install plugins
    #   #INSTALL_PLUGINS=1
    #   INSTALL_PLUGINS=0
    #   ;;
    # C) #kibana ssl cert
    #   SSL_CERT="${OPTARG}"
    #   ;;
    # K) #kibana ssl key
    #   SSL_KEY="${OPTARG}"
    #   ;;
    # P) #kibana ssl key passphrase
    #   SSL_PASSPHRASE="${OPTARG}"
    #   ;;
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

# old_add_kibana_os_user()
# {
#   log "[old_add_kibana_os_user] adding kibana user"
#   sudo groupadd -g 999 kibana
#   sudo useradd -u 999 -g 999 kibana
# }

# old_download_unzip_kibana()
# {
#   sudo mkdir -p /opt/kibana
#   if dpkg --compare-versions "$KIBANA_VERSION" ">=" "5.0.0"; then
#       DOWNLOAD_URL="https://artifacts.elastic.co/downloads/kibana/kibana-$KIBANA_VERSION-linux-x86_64.tar.gz"
#   elif dpkg --compare-versions "$KIBANA_VERSION" ">=" "4.6.0"; then
#       DOWNLOAD_URL="https://download.elastic.co/kibana/kibana/kibana-$KIBANA_VERSION-linux-x86_64.tar.gz"
#   else
#       DOWNLOAD_URL="https://download.elastic.co/kibana/kibana/kibana-$KIBANA_VERSION-linux-x64.tar.gz"
#   fi

#   log "[old_download_unzip_kibana] downloading kibana $KIBANA_VERSION from $DOWNLOAD_URL"
#   curl -o kibana.tar.gz "$DOWNLOAD_URL"
#   tar xvf kibana.tar.gz -C /opt/kibana/ --strip-components=1
#   log "kibana $KIBANA_VERSION downloaded"

#   sudo chown -R kibana: /opt/kibana

#   mv /opt/kibana/config/kibana.yml /opt/kibana/config/kibana.yml.bak
# }

download_install_deb()
{
    log "[download_install_deb] starting download of package"
    local DOWNLOAD_URL="https://artifacts.elastic.co/downloads/kibana/kibana-$KIBANA_VERSION-amd64.deb"
    curl -o "kibana-$KIBANA_VERSION.deb" "$DOWNLOAD_URL"
    log "[download_install_deb] installing downloaded package"
    sudo dpkg -i "kibana-$KIBANA_VERSION.deb"
}

## Security
##----------------------------------

# old_configuration_and_plugins()
# {
#     log "[old_configuration_and_plugins] configuring kibana.yml"
#     local KIBANA_CONF=/opt/kibana/config/kibana.yml
#     # set the elasticsearch URL
#     echo "elasticsearch.url: \"$ELASTICSEARCH_URL\"" >> $KIBANA_CONF
#     # specify kibana log location
#     echo "logging.dest: /var/log/kibana.log" >> $KIBANA_CONF
#     sudo touch /var/log/kibana.log
#     sudo chown kibana: /var/log/kibana.log
#     # set logging to silent by default
#     echo "logging.silent: true" >> $KIBANA_CONF

#     if [ ${INSTALL_PLUGINS} -ne 0 ]; then
#       echo "elasticsearch.username: es_kibana_server" >> $KIBANA_CONF
#       echo "elasticsearch.password: \"$USER_KIBANA4_SERVER_PWD\"" >> $KIBANA_CONF

#       # install shield only on Elasticsearch 2.4.0+ so that graph can be used.
#       # cannot be installed on earlier versions as
#       # they do not allow unsafe sessions (i.e. sending session cookie over HTTP)
#       if dpkg --compare-versions "$ES_VERSION" ">=" "2.4.0"; then
#         log "[old_configuration_and_plugins] installing latest shield"
#         /opt/kibana/bin/kibana plugin --install kibana/shield/$ES_VERSION
#         log "[old_configuration_and_plugins] shield plugin installed"

#         if [[ -z "${SSL_CERT}" || -z "${SSL_KEY}" ]]; then
#             # IMPORTANT: These settings allow security to work in Kibana without HTTPS.
#             # This is NOT recommended for production.
#             log "[old_configuration_and_plugins] set shield.useUnsafeSessions: true because no kibana .crt or .key provided"
#             echo "shield.useUnsafeSessions: true" >> $KIBANA_CONF
#             log "[old_configuration_and_plugins] set shield.skipSslCheck: true because no kibana .crt or .key provided"
#             echo "shield.skipSslCheck: true" >> $KIBANA_CONF
#         fi

#         install_pwgen

#         log "[old_configuration_and_plugins] generating security encryption key"
#         ENCRYPTION_KEY=$(pwgen 64 1)
#         echo "shield.encryptionKey: \"$ENCRYPTION_KEY\"" >> $KIBANA_CONF
#         log "[old_configuration_and_plugins] security encryption key generated"
#       fi

#       # install graph
#       if dpkg --compare-versions "$ES_VERSION" ">=" "2.3.0"; then
#         log "[old_configuration_and_plugins] installing graph plugin"
#         /opt/kibana/bin/kibana plugin --install elasticsearch/graph/$ES_VERSION
#         log "[old_configuration_and_plugins] graph plugin installed"
#       fi

#       # install reporting
#       if dpkg --compare-versions "$KIBANA_VERSION" ">=" "4.6.1"; then
#         log "[old_configuration_and_plugins] installing reporting plugin"
#         /opt/kibana/bin/kibana plugin --install kibana/reporting/$ES_VERSION
#         log "[old_configuration_and_plugins] reporting plugin installed"

#         log "[old_configuration_and_plugins] generating reporting encryption key"
#         install_pwgen
#         ENCRYPTION_KEY=$(pwgen 64 1)
#         echo "reporting.encryptionKey: \"$ENCRYPTION_KEY\"" >> $KIBANA_CONF
#         log "[old_configuration_and_plugins] reporting encryption key generated"
#       fi

#       log "[old_configuration_and_plugins] installing monitoring plugin"
#       /opt/kibana/bin/kibana plugin --install elasticsearch/marvel/$ES_VERSION
#       log "[old_configuration_and_plugins] monitoring plugin installed"
#     fi

#     # configure HTTPS if cert and private key supplied
#     if [[ -n "${SSL_CERT}" && -n "${SSL_KEY}" ]]; then
#         mkdir -p /opt/kibana/config/ssl
#         log "[old_configuration_and_plugins] save kibana cert blob to file"
#         echo ${SSL_CERT} | base64 -d | sudo tee /opt/kibana/config/ssl/kibana.crt
#         log "[old_configuration_and_plugins] save kibana key blob to file"
#         echo ${SSL_KEY} | base64 -d | sudo tee /opt/kibana/config/ssl/kibana.key
#         log "[old_configuration_and_plugins] configuring encrypted communication"
#         echo "server.ssl.key: /opt/kibana/config/ssl/kibana.key" >> $KIBANA_CONF
#         echo "server.ssl.cert: /opt/kibana/config/ssl/kibana.crt" >> $KIBANA_CONF
#         log "[old_configuration_and_plugins] configured encrypted communication"
#     fi

#     log "[old_configuration_and_plugins] installing sense plugin"
#     /opt/kibana/bin/kibana plugin --install elastic/sense
#     log "[old_configuration_and_plugins] sense plugin installed"

#     # sense default url to point at Elasticsearch on first load
#     echo "sense.defaultServerUrl: \"$ELASTICSEARCH_URL\"" >> $KIBANA_CONF
# }

# install_pwgen()
# {
#     log "[install_pwgen] installing pwgen tool if needed"
#     if [ $(dpkg-query -W -f='${Status}' pwgen 2>/dev/null | grep -c "ok installed") -eq 0 ]; then
#       (sudo apt-get -yq install pwgen || (sleep 15; sudo apt-get -yq install pwgen))
#     fi
# }

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

    log "[configure_kibana] configuring kibana default configuration"
    local ES_HEAP=`free -m |grep Mem | awk '{if ($2/2 >31744) print 31744;else print int($2/2+0.5);}'`

    log "[configure_kibana] Configure kibana 5.x & 6.x heap size - $1"
    echo "-Xmx$1m" >> ${RETURN_HOME}/jvm.options
    echo "-Xms$1m" >> ${RETURN_HOME}/jvm.options
    log "[configure_kibana] configured kibana default configuration"

    # install plugins
    log "[install plugin] download kbn_searchtables plugin"
    local DOWNLOAD_URL="https://github.com/dlumbrer/kbn_searchtables/releases/download/6.X-1/kbn_searchtables.tar.gz"
    sudo wget -q "$DOWNLOAD_URL" -O kbn_searchtables.tar.gz

    mkdir -p /usr/share/kibana/install_plugins
    chmod 777 -R /usr/share/kibana/install_plugins/

    cd /usr/share/kibana/
    chown kibana:kibana -R ./plugins
    chmod 775 -R ./plugins

    adduser kibana --disabled-password

    log "[install plugin] move kbn_searchtables plugin"
    sudo mv kbn_searchtables.tar.gz /usr/share/kibana/install_plugins/kbn_searchtables.tar.gz
    cd /usr/share/kibana/install_plugins/
    tar -xvf ./kbn_searchtables.tar.gz
    mv /usr/share/kibana/install_plugins/kbn_searchtables /usr/share/kibana/plugins/kbn_searchtables


    # if [ ${INSTALL_PLUGINS} -ne 0 ]; then
    #   echo "elasticsearch.username: kibana" >> $KIBANA_CONF
    #   echo "elasticsearch.password: $USER_KIBANA4_SERVER_PWD" >> $KIBANA_CONF

    #   install_pwgen
    #   local ENCRYPTION_KEY=$(pwgen 64 1)
    #   echo "xpack.security.encryptionKey: \"$ENCRYPTION_KEY\"" >> $KIBANA_CONF
    #   ENCRYPTION_KEY=$(pwgen 64 1)
    #   echo "xpack.reporting.encryptionKey: \"$ENCRYPTION_KEY\"" >> $KIBANA_CONF
    #   log "[configuration_and_plugins] x-pack security encryption key generated"

    #   log "[configuration_and_plugins] installing xpack plugin"
    #   sudo /usr/share/kibana/bin/kibana-plugin install x-pack
    #   log "[configuration_and_plugins] installed xpack plugin"
    # fi

    # configure HTTPS if cert and private key supplied
    # if [[ -n "${SSL_CERT}" && -n "${SSL_KEY}" ]]; then
    #   mkdir -p /etc/kibana/ssl
    #   log "[configuration_and_plugins] save kibana cert blob to file"
    #   echo ${SSL_CERT} | base64 -d | sudo tee /etc/kibana/ssl/kibana.crt
    #   log "[configuration_and_plugins] save kibana key blob to file"
    #   echo ${SSL_KEY} | base64 -d | sudo tee /etc/kibana/ssl/kibana.key

    #   log "[configuration_and_plugins] configuring encrypted communication"

    #   if dpkg --compare-versions "$KIBANA_VERSION" ">=" "5.3.0"; then
    #       echo "server.ssl.enabled: true" >> $KIBANA_CONF
    #       echo "server.ssl.key: /etc/kibana/ssl/kibana.key" >> $KIBANA_CONF
    #       echo "server.ssl.certificate: /etc/kibana/ssl/kibana.crt" >> $KIBANA_CONF

    #       if [[ -n "${SSL_PASSPHRASE}" ]]; then
    #           echo "server.ssl.keyPassphrase: \"$SSL_PASSPHRASE\"" >> $KIBANA_CONF
    #       fi
    #   else
    #       echo "server.ssl.key: /etc/kibana/ssl/kibana.key" >> $KIBANA_CONF
    #       echo "server.ssl.cert: /etc/kibana/ssl/kibana.crt" >> $KIBANA_CONF
    #   fi

    #   log "[configuration_and_plugins] configured encrypted communication"
    # fi
}

# old_install_service()
# {
#     log "[old_install_service] configuring makeshift service for kibana 4"
#     {
#       echo -e "# kibana"
#       echo -e "description \"Elasticsearch Kibana Service\""
#       echo -e ""
#       echo -e "start on starting"
#       echo -e "script"
#       echo -e "  /opt/kibana/bin/kibana"
#       echo -e "end script"
#       echo -e ""
#     } >> /etc/init/kibana.conf

#     chmod +x /etc/init/kibana.conf
#     sudo service kibana start
# }

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
    sudo chown elk4sa:elk4sa -R /usr/share/kibana
    sudo chmod 775 -R /usr/share/kibana
    sudo chmod 775 -R /etc/kibana/
    mkdir -p /usr/share/kibana/commands/utils/
    sudo touch $REBOOT_START
    sudo chmod 777 $REBOOT_START
    echo -e "#! /bin/bash\n\nsudo /usr/share/kibana/bin/kibana &" >> $REBOOT_START
    (sudo crontab -u root -l; echo "@reboot $REBOOT_START" ) | sudo crontab -u root -
}

# old_install_sequence()
# {
#     log "[old_install_sequence] Starting the old install sequence for kibana"
#     old_add_kibana_os_user
#     old_download_unzip_kibana
#     old_configuration_and_plugins
#     old_install_service
#     log "[old_install_sequence] Finished installation"
# }

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

# if dpkg --compare-versions "$KIBANA_VERSION" ">=" "5.0.0"; then
install_sequence
# else
#   old_install_sequence
# fi

ELAPSED_TIME=$(($SECONDS - $START_TIME))
PRETTY=$(printf '%dh:%dm:%ds\n' $(($ELAPSED_TIME/3600)) $(($ELAPSED_TIME%3600/60)) $(($ELAPSED_TIME%60)))
log "End execution of Kibana script extension in ${PRETTY}"
exit 0