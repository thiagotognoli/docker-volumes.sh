#!/bin/bash


scriptPath="$(sourcePath=`readlink -f "$0"` && echo "${sourcePath%/*}")"
basePath="$(cd $scriptPath && pwd)"

CONTAINER="$1"
REMOTE_SSH="$2" #USER@HOST
REMOTE_DIRECTORY="$3"




cd "$basePath"

docker stop $CONTAINER

docker commit $CONTAINER $CONTAINER

docker save $CONTAINER | ssh $REMOTE_SSH docker load

"$basePath"/docker-volumes.sh $CONTAINER save $CONTAINER-volumes.tar

scp $CONTAINER-volumes.tar $REMOTE_SSH:$REMOTE_DIRECTORY

#docker create --name $CONTAINER [<PREVIOUS CONTAINER OPTIONS>] $CONTAINER

#ssh $REMOTE_SSH bash -c 'docker-volumes.sh $CONTAINER load $CONTAINER-volumes.tar'

#ssh $REMOTE_SSH bash -c 'docker start $CONTAINER'
