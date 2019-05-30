#!/usr/bin/bash

start () {
  echo "Starting resources..."
  ##
  /etc/init.d/drbd start
  drbdadm -- primary r0
  mount /dev/drbd0 /gfs
  gitlab-ctl start
  ##
  echo "Done."
}

stop () {
  echo "Stopping resources..."
  ##
  /etc/init.d/drbd stop # This is rude to do it before stopping gitlab but protecting the storage is more important :-)
  gitlab-ctl stop
  ##
  echo "Done."
}

MASTER_HOST_KEY="master"
CONSUL_HOST="127.0.0.1"
LATCH_FILE="/tmp/.watch"
CURRENT_SESSION=""
LOCAL_HOST=$(hostname)

############################################################
# You should probably not touch anything beyond this point #
############################################################

function finish {
  stop
  rm -f $LATCH_FILE
}
trap finish SIGTERM INT

touch $LATCH_FILE

while [ -f $LATCH_FILE ]; do
  echo "Probing consul..."

  response=$(curl --silent -m 3 http://$CONSUL_HOST:8500/v1/kv/$MASTER_HOST_KEY)
  # Check local consul health
  if [[ $response == "" ]]; then
    # Local consul seems to be dead.
    # if currently master -> shut it down
    # otherwise, do nothing
    echo "Empty consul value. Cluster uninitiated !"
    if [[ $CURRENT_SESSION != "" ]]; then
      echo "Empty response from consul while being the master !!"
      CURRENT_SESSION=""
      stop
    fi
  else
    # Local consul seems to be up.
    echo "Non-empty response from consul !"
    if [[ $response == "No cluster leader" ]]; then
      echo "Consul out of sync !"
      if [[ $CURRENT_SESSION != "" ]]; then
        echo "Consul desync while being the master !!"
        CURRENT_SESSION=""
        stop
      fi
    else
      host=$(echo $response | jq -r '.[0].Value' | base64 -d)
      session=$(echo $response | jq -r '.[0].Session')

      # Check who is the current master according to consul
      if [[ $host != $LOCAL_HOST ]]; then
        # If the current master is another node, check that a valid session is linked
        # If a valid session is found, the master is UP
        # Otherwise, we should try to become master
        echo "master seems to be another node"
        if [[ $session != "null" ]]; then
          echo "master node is alive"
          if [[ $CURRENT_SESSION != "" ]]; then
            CURRENT_SESSION=""
            stop
          fi
        else #session is null -> let's try to become master
          echo "master node seems down - creating new session"
          response=$(curl --silent -m 3 -X PUT http://$CONSUL_HOST:8500/v1/session/create -d '{"TTL":"10s"}')
          if [[ $response != "" ]]; then
            CURRENT_SESSION=$(echo $response | jq -r '.ID')
            echo "Locking master key"
            result=$(curl --silent -m 3 -X PUT --write-out %{http_code} --silent --output /dev/null http://$CONSUL_HOST:8500/v1/kv/$MASTER_HOST_KEY?acquire=$CURRENT_SESSION -d "$LOCAL_HOST" -H "Content-Type: application/json")
            if [[ $result != "200" ]]; then
              echo "master election failed"
              CURRENT_SESSION=""
            else
              echo "master election succeeded"
              start
            fi
          else
            echo "Session creation failed"
          fi
        fi
      else
        # If the current master is this noe, check that we already have a session
        # If so, just renew it
        # Otherwise, create a new one and lock the master key
        if [[ $CURRENT_SESSION != "" ]]; then
          echo "Still the master - renewing session"
          result=$(curl --silent -m 3 -X PUT --write-out %{http_code} --silent --output /dev/null http://$CONSUL_HOST:8500/v1/session/renew/$CURRENT_SESSION?TTL=10s)
          if [[ $result != "200" ]]; then
            echo "Session renew failed"
            CURRENT_SESSION=""
            stop
          fi
        else
          echo "Creating new session"
          response=$(curl --silent -m 3 -X PUT http://$CONSUL_HOST:8500/v1/session/create -d '{"TTL":"10s"}' -H "Content-Type: application/json")
          if [[ $response != "" ]]; then
            CURRENT_SESSION=$(echo $response | jq -r '.ID')
            echo "Locking master key"
            result=$(curl --silent -m 3 -X PUT --write-out %{http_code} --silent --output /dev/null http://$CONSUL_HOST:8500/v1/kv/$MASTER_HOST_KEY?acquire=$CURRENT_SESSION -d "$LOCAL_HOST")
            if [[ $result != "200" ]]; then
              echo "master election failed"
              CURRENT_SESSION=""
            else
              echo "master election succeeded"
              start
            fi
          else
            echo "Session creation failed"
          fi
        fi
      fi
    fi
  fi
  sleep 5
done

echo "Over !"
