#!/bin/sh
#######################################################################################
# file:    deploy_stf.sh
# brief:   deploy components of stf with docker
# usage:   ./deploy_stf_docker.sh  Note: run it as ROOT user
#######################################################################################

# Get exported IP Adreess 
[ ! -z "$(echo ${NETWORK_INTERFACES} | grep "wlo1")" ]&&NETNAME="wlo1"
[ ! -z "$(echo ${NETWORK_INTERFACES} | grep "eno1")" ]&&NETNAME="eno1"
IP_ADDRESS=$(ifconfig ${NETNAME}|grep "inet "|awk -F: '{print $2}'|awk '{print $1}')
[ $# -gt 0 ]&&IP_ADDRESS=$1
echo "IP ADDRESS: ${IP_ADDRESS}"

check_return_code() {
  if [ $? -ne 0 ]; then
    echo "Failed to run last step!"     
    return 1
  fi
   
  return 0
}

assert_run_ok() {
  if [ $? -ne 0 ]; then
    echo "Failed to run last step!"     
    exit 1
  fi
   
  return 0
}

prepare() {
  echo "setup environment ..."

  # set proxy
  export all_proxy=http://proxy.zhenguanyu.com:8118

  # Given advantages of performance and stability, we run adb server and rethinkdb 
  # on host(physical) machine rather than on docker containers, so need to
  #  install package of android-tools-adb first [ thinkhy 2017-05-04 ]

  # install adb
  apt-get install -y android-tools-adb

  apt-get install -y docker.io
  assert_run_ok

  docker pull openstf/stf 
  assert_run_ok

  #docker pull sorccu/adb 
  #assert_run_ok

  docker pull rethinkdb 
  assert_run_ok

  docker pull openstf/ambassador 
  assert_run_ok

  docker pull nginx
  assert_run_ok

  cp -rf adbd.service.template /etc/systemd/system/adbd.service  
  assert_run_ok
}

# start local adb server
echo "start adb server"
systemctl start adbd 

# start rethinkdb
echo "start docker container: rethinkdb"
docker rm -f rethinkdb
docker run -d --name rethinkdb -v /srv/rethinkdb:/data --net host rethinkdb rethinkdb --bind all --cache-size 8192 --http-port 8090
check_return_code

# start nginx, note: generate nginx.conf first
# echo "start docker container: nginx"
# docker rm -f nginx
# docker run -d -v $(pwd)/nginx.conf:/etc/nginx/nginx.conf:ro --name nginx --net host nginx nginx
# check_return_code

# create tables 
echo "start docker container: stf-migrate"
docker rm -f stf-migrate
docker run -d --name stf-migrate --net host openstf/stf stf migrate
check_return_code

# create storage components 
echo "start docker container: storage-plugin-apk"
docker rm -f storage-plugin-apk
docker run -d --name storage-plugin-apk -net host openstf/stf stf storage-plugin-apk  --port 7104 --storage-url http://${IP_ADDRESS}:7100/
check_return_code

echo "start docker container: storage-plugin-image"
docker rm -f storage-plugin-image
docker run -d --name storage-plugin-image --net host openstf/stf stf storage-plugin-image  --port 7103 --storage-url http://${IP_ADDRESS}:7100/
check_return_code  

echo "start docker container: storage-temp"
docker rm -f storage-temp
docker run -d --name storage-temp -v /mnt/storage:/data -- host openstf/stf stf storage-temp  --port 7102 --save-dir /data
check_return_code

# tri-proxy
echo "start docker container: triproxy-app"
docker rm -f triproxy-app
docker run -d --name triproxy-app --net host openstf/stf stf triproxy app --bind-pub "tcp://127.0.0.1:7111" --bind-dealer "tcp://127.0.0.1:7112" --bind-pull "tcp://127.0.0.1:7113"
check_return_code

echo "start docker container: triproxy-dev"
docker rm -f triproxy-dev
docker run -d --name triproxy-dev --net host openstf/stf stf triproxy dev --bind-pub "tcp://*:7114" --bind-dealer "tcp://127.0.0.1:7115" --bind-pull "tcp://*:7116"
check_return_code

# auth
echo "start docker container: stf-auth"
docker rm -f stf-auth
docker run -d --name stf-auth -e "SECRET=YOUR_SESSION_SECRET_HERE" --net host --dns ${DNS_ADDRESS} openstf/stf stf auth-mock --port 7120 --app-url http://${IP_ADDRESS}:7100/
check_return_code

# api 
echo "start docker container: stf-api"
docker rm -f stf-api
docker run -d --name stf-api --net host -e "SECRET=YOUR_SESSION_SECRET_HERE"  openstf/stf stf api --port 7106 --connect-push tcp://127.0.0.1:7113 --connect-sub tcp://127.0.0.1:7111 --connect-push-dev tcp://127.0.0.1:7116 --connect-sub-dev tcp://127.0.0.1:7114
check_return_code

# stf APP
echo "start docker container: stf-app"
docker rm -f stf-app
docker run -d --name stf-app --net host -e "SECRET=YOUR_SESSION_SECRET_HERE" openstf/stf stf app --port 7105 --auth-url http://${IP_ADDRESS}:7100/auth/mock/ --websocket-url http://${IP_ADDRESS}:7110/
check_return_code


# processor
echo "start docker container: stf-processor"
docker rm -f stf-processor
docker run -d --name stf-processor --net host openstf/stf stf processor stf-processor.service --connect-app-dealer tcp://127.0.0.1:7112 --connect-dev-dealer tcp://127.0.0.1:7115
check_return_code

# websocket
echo "start docker container: websocket"
docker rm -f websocket
docker run -d --name websocket -e "SECRET=YOUR_SESSION_SECRET_HERE" --net host openstf/stf stf websocket --port 7110 --storage-url http:/127.0.0.1:7100/ --connect-sub tcp://127.0.0.1:7111 --connect-push tcp://127.0.0.1:7113
check_return_code

# reaper
echo "start docker container: reaper"
docker rm -f reaper
docker run -d --name reaper --net host openstf/stf stf reaper dev --connect-push tcp://127.0.0.1:7116 --connect-sub tcp://127.0.0.1:7111 --heartbeat-timeout 30000
check_return_code

# provider
# echo "start docker container: provider"
# docker rm -f provider
# docker run -d --name provider --net host openstf/stf stf provider --name provider --connect-sub tcp://${IP_ADDRESS}:7114 --connect-push tcp://${IP_ADDRESS}:7116 --storage-url http://${IP_ADDRESS} --public-ip ${IP_ADDRESS} --min-port=7399 --max-port=7400 --heartbeat-interval 20000 --screen-ws-url-pattern "ws://${IP_ADDRESS}:<%= publicPort %>/"
# check_return_code


# poorxy
echo "start docker container: poorxy"
docker rm -f poorxy
docker run -d --name poorxy --net host openstf/stf stf poorxy stf poorxy --port 7100 --app-url http://127.0.0.1:7105/ --auth-url http://127.0.0.1:7120/ --api-url http://127.0.0.1:7106/ --websocket-url http://127.0.0.1:7110/ --storage-url http://127.0.0.1:7102/ --storage-plugin-image-url http://127.0.0.1:7103/ --storage-plugin-apk-url http://127.0.0.1:7104/
