#!/bin/sh
#######################################################################################
# file:    deploy_stf_mac.sh
# brief:   deploy components of stf
# usage:   ./deploy_stf_mac.sh server/provider/stop
#######################################################################################

IP_ADDRESS=$(ifconfig | grep 'inet\b' | grep -v 127.0.0.1  | grep 10 | awk 'NR==1 {print $2}')
REMOTE_IP_ADDRESS=127.0.0.1
RETHINKDB_DIRECTORY=./
log_file=stf.log

assert_run_ok() {
  if [ $? -ne 0 ]; then
    echo "Failed to run last step!"     
    exit 1
  fi
  return 0
}

prepare_stf() {
    # start to install stf

    # install nvm
    nvm --version
    if [ $? -ne 0 ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.3/install.sh | bash    
    fi
    export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" # This loads nvm 

    #install Homebrew
    brew --version
    if [ $? -ne 0 ]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
        assert_run_ok 
    fi

    #install requirements
    brew cask install android-platform-tools
    assert_run_ok
    brew install rethinkdb graphicsmagick zeromq protobuf yasm pkg-config
    assert_run_ok

    nvm install 8.17.0
    assert_run_ok

    #install stf
    npm install
    assert_run_ok
    npm link
    if [ $? -ne 0 ]; then
        sudo npm link
    fi

    stf doctor
    if [ $? -ne 0 ]; then
        exit 1
    fi

    # add deploy-stf as global command
    basepath=$(cd `dirname $0`; pwd)
    ln -s ${basepath}/deploy_stf_mac.sh /usr/local/bin/deploy-stf
}

deploy_stf_server(){
    
    echo "IP_ADDRESS=${IP_ADDRESS}"
    echo "RETHINKDB_DIRECTORY=${RETHINKDB_DIRECTORY}"
    echo "log_file=${log_file}"
    echo "start to deploy the stf service"

    (rethinkdb -d ${RETHINKDB_DIRECTORY} --bind 127.0.0.1 --bind-http 127.0.0.1  --cache-size 8192 --no-update-check | tee ${log_file} ) &
    sleep 2
    assert_run_ok

    (stf migrate ) &
    sleep 2

    (stf triproxy app001 --bind-pub tcp://127.0.0.1:7111 --bind-dealer tcp://127.0.0.1:7112 --bind-pull tcp://127.0.0.1:7113 | tee ${log_file} ) &

    (stf triproxy dev001 --bind-pub tcp://*:7114 --bind-dealer tcp://127.0.0.1:7115 --bind-pull tcp://*:7116 | tee ${log_file} ) &

    (stf processor proc001 --connect-app-dealer tcp://127.0.0.1:7112 --connect-dev-dealer tcp://127.0.0.1:7115  | tee ${log_file} ) &

    (stf reaper reaper001 --connect-push tcp://127.0.0.1:7116 --connect-sub tcp://127.0.0.1:7111 | tee ${log_file} ) &

    (stf auth-mock --port 7120 --secret kute kittykat --app-url http://${IP_ADDRESS}:7100/ | tee ${log_file} ) &

    (stf app --port 7105 --secret kute kittykat --auth-url http://${IP_ADDRESS}:7100/auth/mock/ --websocket-url http://${IP_ADDRESS}:7110/ | tee ${log_file} ) &

    (stf api --port 7106 --secret kute kittykat --connect-push tcp://127.0.0.1:7113 --connect-sub tcp://127.0.0.1:7111 --connect-push-dev tcp://127.0.0.1:7116 --connect-sub-dev tcp://127.0.0.1:7114  | tee ${log_file} ) &

    (stf groups-engine --connect-push tcp://127.0.0.1:7113 --connect-sub tcp://127.0.0.1:7111 --connect-push-dev tcp://127.0.0.1:7116 --connect-sub-dev  tcp://127.0.0.1:7114 | tee ${log_file} ) &

    (stf websocket --port 7110 --secret kute kittykat --storage-url http:/127.0.0.1:7100/ --connect-sub tcp://127.0.0.1:7111 --connect-push tcp://127.0.0.1:7113 | tee ${log_file} ) &

    (stf storage-temp --port 7102 | tee ${log_file} ) &

    (stf storage-plugin-image --port 7103 --storage-url http://127.0.0.1:7100/ | tee ${log_file} ) &

    (stf storage-plugin-apk --port 7104 --storage-url http://127.0.0.1:7100/ | tee ${log_file} ) &

    (stf poorxy --port 7100 --app-url http://127.0.0.1:7105/ --auth-url http://127.0.0.1:7120/ --api-url http://127.0.0.1:7106/ --websocket-url http://127.0.0.1:7110/  --storage-url http://127.0.0.1:7102/ --storage-plugin-image-url http://127.0.0.1:7103/ --storage-plugin-apk-url http://127.0.0.1:7104/ | tee ${log_file} ) &

    sleep 20
}

deploy_stf_provider(){
    echo "REMOTE_IP_ADDRESS=${REMOTE_IP_ADDRESS}"
    (stf provider --name localhost --min-port 7399 --max-port 7700 --connect-sub tcp://${REMOTE_IP_ADDRESS}:7114 --connect-push tcp://${REMOTE_IP_ADDRESS}:7116 --group-timeout 900  --public-ip ${REMOTE_IP_ADDRESS} --storage-url http://${REMOTE_IP_ADDRESS}:7100/ --adb-host 127.0.0.1 --adb-port 5037 --vnc-initial-size 600x800 --mute-master never   --screen-ws-url-pattern "ws://${IP_ADDRESS}:<%= publicPort %>/" | tee ${log_file} ) &
    echo "stf server deployment succeed"
}

stf_stop(){
    sudo ps aux | grep "stf_deployment" | grep -v grep | awk '{printf $2" " }' | xargs kill -9
    sudo ps aux | grep "tee stf" | grep -v grep | awk '{printf $2" " }' | xargs kill -9
    sudo ps aux | grep "/usr/local/bin/stf" | grep -v grep | awk '{printf $2" " }' | xargs kill -9
    sudo ps aux | grep "rethinkdb" | grep -v grep | awk '{printf $2" " }' | xargs kill -9
}

if [ -z $1 ];then
    echo "Error usage! Usage: ./deploy_stf_mac.sh  server/provider/stop [-adhmo]"
    exit 1
fi
ACTION=$1; shift

case "$ACTION" in
    server)
    while getopts "a:ho:m:d:" opt
    do
        case $opt in
            a)
            IP_ADDRESS=$OPTARG
            ;;
            d)
            RETHINKDB_DIRECTORY=$OPTARG
            ;;
            h)
            echo "Description: delploy the stf server.\nOptions:\n    -a\tSpecify local ip address.\t\t[String]\n    -d\tSpecify directory to store data.\t[String]\n    -h\tShow help.\t\t\t\t[Boolean]\n    -o\tSpecify log file name.\t\t\t[String]\n"
            exit 0
            ;;
            o)
            log_file=$OPTARG
            ;;
            ?)
            echo "ERROR: unknow parameter"
            exit 1
            ;;
        esac
    done
    ;;
    provider)
    while getopts "a:ho:m:d:" opt
    do
        case $opt in
            a)
            IP_ADDRESS=$OPTARG
            ;;
            h)
            echo "Description: delploy the stf provider.\nOptions:\n    -a\tSpecify local ip address.\t\t[String]\n    -h\tShow help.\t\t\t\t[Boolean]\n    -m\tSpecify master server ip address.\t[String]\n    -o\tSpecify log file name.\t\t\t[String]\n"
            exit 0
            ;;
            m)
            REMOTE_IP_ADDRESS=$OPTARG
            ;;
            o)
            log_file=$OPTARG
            ;;
            ?)
            echo "ERROR: unknow parameter"
            exit 1
            ;;
        esac
    done
    ;;
    stop)
    while getopts "" opt
    do
        case $opt in
            ?)
            echo "ERROR: unknow parameter"
            exit 1
            ;;
        esac
    done
    ;;
esac

stf doctor >> /dev/null 
if [ $? -ne 0 ]; then
    prepare_stf
fi

if [ ${ACTION} == "server" ];then
    deploy_stf_server
elif [ ${ACTION} == "provider" ];then
    deploy_stf_provider
elif [ ${ACTION} == "stop" ];then
    stf_stop
else
    echo "Error usage! Usage: ./deploy_stf_mac.sh  server/provider/stop [-adhmo]"
fi