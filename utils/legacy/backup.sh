#!/usr/bin/env bash

BACKUPFOLDER="backup/$(date +%Y%m%d%s)"
mkdir -p $BACKUPFOLDER

RES=$(docker-compose exec app bash -c "python -c 'import makeit; print(makeit)'")
ASKCOSPATH=$(echo $RES | grep -o "/.*ASKCOS")

if [ -f ".env" ]; then
  source .env
fi
PROJECT_NAME=${COMPOSE_PROJECT_NAME:-deploy}

docker-compose exec app bash -c "cd $ASKCOSPATH/askcos && python manage.py dumpdata -o db.json"

docker cp ${PROJECT_NAME}_app_1:$ASKCOSPATH/askcos/db.json $BACKUPFOLDER
docker cp ${PROJECT_NAME}_app_1:$ASKCOSPATH/makeit/data/user_saves $BACKUPFOLDER

docker-compose exec mongo bash -c "mongoexport -u askcos -p askcos --authenticationDatabase admin -d results -c results -o results.mongo"
docker cp ${PROJECT_NAME}_mongo_1:/results.mongo $BACKUPFOLDER
