#!/usr/bin/env bash

# Copyright (c) 2019 The MINTD developers.
# All rights reserved.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

TMP_FOLDER=$(mktemp -d)
CONFIG_FILE='mintd.conf'
CONFIGFOLDER=${HOME}/.local/share/mintd
COIN_DAEMON='mintdd'
COIN_CLI='mintd-cli'
COIN_PATH='/usr/local/bin'
COIN_TGZ=$(curl -s https://api.github.com/repos/mintdcoin/MINTD/releases/latest | grep browser_download_url | grep -e "x86_64-linux-gnu.tar.gz"| cut -d '"' -f 4)
COIN_ZIP=$(echo $COIN_TGZ | awk -F'/' '{print $NF}')
COIN_NAME='MINTD'
COIN_PORT=19991
RPC_PORT=19992

NODEIP=$(curl -s4 icanhazip.com)

RED='\033[0;31m'
BOLD=$(tput bold)
NORMAL=$(tput sgr0)

function __compile_error {
    if [ "$?" -gt "0" ]; then
        echo -e "${RED}Failed to compile $COIN_NAME. Please investigate.${NORMAL}"
        exit 1
    fi
}

function __get_ip {
    declare -a NODE_IPS
    for ips in $(netstat -i | awk '!/Kernel|Iface|lo/ {print $1," "}')
    do
        NODE_IPS+=($(curl --interface $ips --connect-timeout 2 -s4 icanhazip.com))
    done

    if [ ${#NODE_IPS[@]} -gt 1 ]; then
        echo -e "${RED}More than one IP. Please type 0 to use the first IP, 1 for the second and so on...${NORMAL}"
        INDEX=0
        for ip in "${NODE_IPS[@]}"
        do
            echo ${INDEX} $ip
            let INDEX++
        done
        read -e choose_ip
        NODEIP=${NODE_IPS[$choose_ip]}
    else
        NODEIP=${NODE_IPS[0]}
    fi
}

function __create_config {
    mkdir $CONFIGFOLDER >/dev/null 2>&1
    RPCUSER=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w10 | head -n1)
    RPCPASSWORD=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w22 | head -n1)
    cat << EOF > $CONFIGFOLDER/$CONFIG_FILE
rpcuser=$RPCUSER
rpcpassword=$RPCPASSWORD
rpcport=$RPC_PORT
rpcallowip=127.0.0.1
listen=1
server=1
daemon=1
port=$COIN_PORT
EOF
}

function __create_key {
    echo -e "Creating a new $COIN_NAME Masternode GENKEY..."
    $COIN_PATH/$COIN_DAEMON -daemon
    sleep 30
    if [ -z "$(ps axo cmd:100 | grep $COIN_DAEMON)" ]; then
        echo -e "${RED}$COIN_NAME server could not start. Check /var/log/syslog for errors.{$NORMAL}"
        exit 1
    fi
    COINKEY=$($COIN_PATH/$COIN_CLI masternode genkey)
    if [ "$?" -gt "0" ]; then
        echo -e "Wallet not fully loaded. Retrying GENKEY in 30 seconds..."
        sleep 30
        COINKEY=$($COIN_PATH/$COIN_CLI masternode genkey)
    fi
    $COIN_PATH/$COIN_CLI stop
}

function __update_config {
    sed -i 's/daemon=1/daemon=0/' $CONFIGFOLDER/$CONFIG_FILE
    cat << EOF >> $CONFIGFOLDER/$CONFIG_FILE
logintimestamps=1
maxconnections=256
#bind=$NODEIP
masternode=1
externalip=$NODEIP:$COIN_PORT
masternodeprivkey=$COINKEY

#Addnodes
#addnode=

EOF
}

function __enable_firewall {
    echo -e "Installing and setting up firewall to allow ingress on port $COIN_PORT"
    ufw allow $COIN_PORT/tcp comment "$COIN_NAME Masternode port" >/dev/null
    ufw allow ssh comment "SSH" >/dev/null 2>&1
    ufw limit ssh/tcp >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    echo "y" | ufw enable >/dev/null 2>&1
}

function __important_information {
    echo
    echo -e "${BOLD}$COIN_NAME Masternode successfully configured. Listening on port $COIN_PORT.${NORMAL}"
    echo
    printf "Summary:\n"
    printf "  %-30s %s\n" "Wallet configuration file:" "$CONFIGFOLDER/$CONFIG_FILE"
    printf "  %-30s %s\n" "Masternode GENKEY:" "$COINKEY"
    printf "  %-30s %s\n" "Server IP:" "$NODEIP:$COIN_PORT"
    printf "  %-30s %s\n" "Wallet start:" "systemctl start $COIN_NAME.service"
    printf "  %-30s %s\n" "Wallet stop:" "systemctl stop $COIN_NAME.service"
    echo
    echo -e "Usage:"
    echo -e "  mintd-cli masternode status"
    echo -e "  mintd-cli getinfo"
    echo
    echo -e "Talk to us on Discord. ${BOLD}https://discordapp.com/invite/Q8tsgCw${NORMAL}"
    echo -e "${BOLD}Ensure Node is fully synced with blockchain.${NORMAL}"
    echo
}

function __configure_systemd {
    cat << EOF > /etc/systemd/system/$COIN_NAME.service
[Unit]
Description=$COIN_NAME service
After=network.target

[Service]
User=root
Group=root

Type=forking
#PIDFile=$CONFIGFOLDER/$COIN_NAME.pid

ExecStart=$COIN_PATH/$COIN_DAEMON -daemon -conf=$CONFIGFOLDER/$CONFIG_FILE -datadir=$CONFIGFOLDER
ExecStop=-$COIN_PATH/$COIN_CLI -conf=$CONFIGFOLDER/$CONFIG_FILE -datadir=$CONFIGFOLDER stop

Restart=always
PrivateTmp=true
TimeoutStopSec=60s
TimeoutStartSec=10s
StartLimitInterval=120s
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    sleep 3
    systemctl start $COIN_NAME.service
    systemctl enable $COIN_NAME.service >/dev/null 2>&1

    if [[ -z "$(ps axo cmd:100 | egrep $COIN_DAEMON)" ]]; then
        echo -e "${RED}$COIN_NAME is not running${NORMAL}, please investigate. You should start by running the following commands as root:"
        echo "  systemctl start $COIN_NAME.service"
        echo "  systemctl status $COIN_NAME.service"
        echo "  less /var/log/syslog"
        exit 1
    fi
}

function _purge_old_installation {
    echo -e "Searching and removing old $COIN_NAME files and configurations"
    sudo systemctl stop $COIN_NAME.service > /dev/null 2>&1
    sudo killall $COIN_DAEMON > /dev/null 2>&1
    sudo ufw delete allow $COIN_PORT/tcp > /dev/null 2>&1
    rm -- "$0" > /dev/null 2>&1
    sudo rm /root/$CONFIGFOLDER/bootstrap.dat.old > /dev/null 2>&1
    rm -rf ~/$CONFIGFOLDER > /dev/null 2>&1
    cd /usr/bin && sudo rm $COIN_CLI $COIN_DAEMON > /dev/null 2>&1 && cd
    cd /usr/local/bin && sudo rm $COIN_CLI $COIN_DAEMON > /dev/null 2>&1 && cd
    echo -e "* Done";
}

function _checks {
    if [[ $(lsb_release -d) != *18.04* ]]; then
        echo -e "${RED}You are not running Ubuntu 18.04. Installation is cancelled.${NORMAL}"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}$0 must be run as root.${NORMAL}"
        exit 1
    fi

    if [ -n "$(pidof $COIN_DAEMON)" ] || [ -e "$COIN_DAEMOM" ]; then
        echo -e "${RED}$COIN_NAME is already installed.${NORMAL}"
        exit 1
    fi
}

function _prepare_system {
    echo -e "Preparing server for $COIN_NAME Masternode. This may take a while..."
    apt-get update >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get update > /dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y -qq upgrade >/dev/null 2>&1
    apt install -y software-properties-common >/dev/null 2>&1
    echo -e "Adding Bitcoin PPA repository"
    apt-add-repository -y ppa:bitcoin/bitcoin >/dev/null 2>&1
    echo -e "Installing required packages. This may take a while..."
    apt-get update >/dev/null 2>&1
    apt-get install libzmq3-dev -y >/dev/null 2>&1
    apt-get install -y autoconf automake bsdmainutils build-essential curl git libboost-chrono-dev libboost-dev libboost-filesystem-dev libboost-program-options-dev libboost-system-dev libboost-test-dev libboost-thread-dev libdb4.8++-dev libdb4.8-dev libdb5.3++ libevent-dev libgmp3-dev libminiupnpc-dev libssl-dev libtool libzmq5 make pkg-config software-properties-common sudo ufw wget >/dev/null 2>&1
    if [ "$?" -gt "0" ]; then
        echo -e "${RED}Not all required packages were installed properly. Try to install them manually by running the following commands:${NORMAL}\n"
        echo "apt update"
        echo "apt -y install software-properties-common"
        echo "apt-add-repository -y ppa:bitcoin/bitcoin"
        echo "apt update"
        echo "apt install -y autoconf automake bsdmainutils build-essential curl git libboost-chrono-dev libboost-dev libboost-filesystem-dev libboost-program-options-dev libboost-system-dev libboost-test-dev libboost-thread-dev libdb4.8++-dev libdb4.8-dev libdb5.3++ libevent-dev libgmp3-dev libminiupnpc-dev libssl-dev libtool libzmq5 make pkg-config sudo ufw wget"
        exit 1
    fi
}

function _download_node {
    echo -e "Downloading and Installing $COIN_NAME Daemon"
    cd $TMP_FOLDER >/dev/null 2>&1
    wget -q $COIN_TGZ
    __compile_error
    tar xzvf $COIN_ZIP >/dev/null 2>&1
    find . -name $COIN_DAEMON | xargs mv -t $COIN_PATH/ >/dev/null 2>&1
    find . -name $COIN_CLI | xargs mv -t $COIN_PATH/ >/dev/null 2>&1
    chmod +x $COIN_PATH/$COIN_DAEMON $COIN_PATH/$COIN_CLI
    cd ~ >/dev/null 2>&1
    rm -rf $TMP_FOLDER >/dev/null 2>&1
}

function _setup_node {
    __get_ip
    __create_config
    __create_key
    __update_config
    __enable_firewall
    __important_information
    __configure_systemd
}

clear
_purge_old_installation
_checks
_prepare_system
_download_node
_setup_node
