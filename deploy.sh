#!/usr/bin/env bash

################################################################################
#
#   ASKCOS Deployment Utilities
#
#    ~ To streamline deployment commands ~
#
################################################################################

set -e  # exit with nonzero exit code if anything fails

usage() {
  echo
  echo "Deployment Utilities for ASKCOS"
  echo
  echo "Specify a task to perform, along with any desired options."
  echo
  echo "Valid commands:"
  echo "    deploy:                   performs initial deployment steps using https"
  echo "    deploy-http:              performs initial deployment steps using http"
  echo "    update:                   update an existing deployment"
  echo "    seed-db:                  seed mongo database with data"
  echo "    migrate:                  perform user database migrations"
  echo "    start:                    (re)start an existing deployment"
  echo "    stop:                     stop a currently running deployment"
  echo "    clean:                    stop and remove a currently running deployment"
  echo "    backup:                   export database data from docker volumes to .tar.gz files"
  echo "    restore:                  import database data from .tar.gz files to docker volumes"
  echo
  echo "Optional arguments:"
  echo "    -f,--compose-file         specify docker-compose file(s) for deployment"
  echo "    -v,--version              specify desired version for updating a deployment"
  echo "    -b,--buyables             buyables data for reseeding mongo database"
  echo "    -c,--chemicals            chemicals data for reseeding mongo database"
  echo "    -x,--reactions            reactions data for reseeding mongo database"
  echo "    -r,--retro-templates      retrosynthetic template data for reseeding mongo database"
  echo "    -t,--forward-templates    forward template data for reseeding mongo database"
  echo "    -p,--project-name         specify project name to be used for services (prefix for docker container names)"
  echo "    -l,--local                use locally available docker images instead of pulling new image"
  echo "    -d,--backup-directory     specify absolute path to backup directory for backup and restore"
  echo "    -a|--append               append new documents when seeding database (instead of dropping old data)"
  echo "    -i|--drop-indexes         drop any existing indexes when indexing database with index-db command"
  echo "    -n|--ignore-diff          ignore differences in config files (.env and customization)"
  echo
  echo "Examples:"
  echo "    bash deploy.sh deploy -f docker-compose.yml"
  echo "    bash deploy.sh update -v x.y.z"
  echo "    bash deploy.sh seed-db -r retro-templates.json.gz -b buyables.json.gz"
  echo "    bash deploy.sh clean"
  echo "    bash deploy.sh backup -p my_project_name"
  echo "    bash deploy.sh restore -d /absolute/path/to/backups/ "
  echo
}

# Worker scales (i.e. number of celery workers)
n_cr_network_worker=1       # Context recommender neural network worker
n_tb_coordinator_mcts=2     # Tree builder coordinator
n_tb_coordinator_mcts_v2=2  # Tree builder v2 coordinator
n_tb_c_worker=1             # Tree builder chiral worker
n_sites_worker=1            # Site selectivity worker
n_impurity_worker=1         # Impurity worker
n_atom_mapping_worker=1     # Atom mapping worker
n_tffp_worker=1             # Template-free forward predictor worker
n_selec_worker=1            # General selectivity worker

# Create environment variable files from examples if they don't exist
if [ ! -f ".env" ]; then
  cp .env.example .env
fi
if [ ! -f "customization" ]; then
  cp customization.example customization
fi
if [ ! -f "custom_django_settings.py" ]; then
  echo
  echo "Setting a unique Django secret key is highly recommended."
  echo
  echo "Note that if this is not a new deployment, changing the secret key"
  echo "will invalidate user sessions. Passwords will not be affected."
  echo
  echo "Would you like to use a custom key (c), a random key (r), or the default key (d)?"
  read -rp ">>> " response
  case "$response" in
    [Cc])
      read -rp "New secret key: " new_secret
      sed "s/notsosecret/${new_secret}/g" custom_django_settings_example.py > custom_django_settings.py
      ;;
    [Rr])
      echo "Generating random secret key."
      new_secret=$(base64 /dev/urandom | tr -dc "[:alnum:]" | head -c 32)
      sed "s/notsosecret/${new_secret}/g" custom_django_settings_example.py > custom_django_settings.py
      ;;
    *)
      echo "Keeping default secret key."
      cp custom_django_settings_example.py custom_django_settings.py
      ;;
  esac
  echo
fi

# Get docker compose variables from .env
source .env

# Default argument values
BUYABLES=""
CHEMICALS=""
REACTIONS=""
RETRO_TEMPLATES=""
FORWARD_TEMPLATES=""
DB_DROP="--drop"
DROP_INDEXES=false
LOCAL=false
BACKUP_DIR=""
IGNORE_DIFF=false

COMMANDS=""
while (( "$#" )); do
  case "$1" in
    -h|--help|help)
      usage
      exit
      ;;
    -f|--compose-file)
      if [ -z "$COMPOSE_FILE" ]; then
        COMPOSE_FILE=$2
      else
        COMPOSE_FILE=$COMPOSE_FILE:$2
      fi
      shift 2
      ;;
    -p|--project-name)
      COMPOSE_PROJECT_NAME=$2
      shift 2
      ;;
    -l|--local)
      LOCAL=true
      shift 1
      ;;
    -v|--version)
      VERSION_NUMBER=$2
      shift 2
      ;;
    -b|--buyables)
      BUYABLES=$2
      shift 2
      ;;
    -c|--chemicals)
      CHEMICALS=$2
      shift 2
      ;;
    -x|--reactions)
      REACTIONS=$2
      shift 2
      ;;
    -r|--retro-templates)
      RETRO_TEMPLATES=$2
      shift 2
      ;;
    -t|--forward-templates)
      FORWARD_TEMPLATES=$2
      shift 2
      ;;
    -a|--append)
      DB_DROP=""
      shift 1
      ;;
    -i|--drop-indexes)
      DROP_INDEXES=true
      shift 1
      ;;
    -n|--ignore-diff)
      IGNORE_DIFF=true
      shift 1
      ;;
    -d|--backup-directory)
      BACKUP_DIR=$2
      shift 2
      ;;
    --) # end argument parsing
      shift
      break
      ;;
    -*) # any other flag
      echo "Error: Unsupported flag $1" >&2  # print to stderr
      exit 1
      ;;
    *) # preserve positional arguments
      COMMANDS="$COMMANDS $1"
      shift
      ;;
  esac
done

# Set positional arguments in their proper place
eval set -- "$COMMANDS"

# Export variables needed by docker-compose
export VERSION_NUMBER
export COMPOSE_FILE
export COMPOSE_PROJECT_NAME

# Define various functions
diff-env() {
  if [ "$IGNORE_DIFF" = "true" ]; then
    return 0
  fi

  output1="$(diff -u .env .env.example)" || true
  if [ -n "$output1" ]; then
    echo -e "\033[91m*** WARNING ***\033[00m"
    echo "Local .env file is different from .env.example"
    echo "This could be due to changes to the example or local changes."
    echo "Please review the diff to determine if any changes are necessary:"
    echo
    echo "$output1"
    echo
  fi

  output2="$(diff -u customization customization.example)" || true
  if [ -n "$output2" ]; then
    echo -e "\033[91m*** WARNING ***\033[00m"
    echo "Local customization file is different from customization.example"
    echo "This could be due to changes to the example or local changes."
    echo "Please review the diff to determine if any changes are necessary:"
    echo
    echo "$output2"
    echo
  fi

  if [ -n "$output1" ] || [ -n "$output2" ]; then
    echo "Local configuration files differ from examples (see above)! What would you like to do?"
    echo "  (c)ontinue without changes  (use -n flag to skip prompt and continue in the future)"
    echo "  (o)verwrite your local files with the examples  (the above diff(s) will be applied)"
    echo "  (s)top and make changes manually"
    read -rp '>>> ' response
    case "$response" in
      [Cc])
        echo "Continuing without changes."
        ;;
      [Oo])
        echo "Overwriting local files."
        cp .env.example .env
        cp customization.example customization
        ;;
      [Ss])
        echo "Stopping."
        exit 1
        ;;
      *)
        echo "Unrecognized option. Stopping."
        exit 1
        ;;
    esac
  fi
}

clean-data() {
  echo "Cleaning up application data volumes..."
  docker-compose stop app mongo nginx rabbit
  docker-compose rm -f app mongo nginx rabbit
  docker volume rm ${COMPOSE_PROJECT_NAME}_appdata
  docker volume rm ${COMPOSE_PROJECT_NAME}_staticdata
  echo "Clean up complete."
  echo
}

start-db-services() {
  echo "Starting database services..."
  docker-compose up -d mysql mongo redis rabbit
  sleep 1
  echo "Start up complete."
  echo
}

set-db-defaults() {
  # Set default values for seeding database if values are not already defined
  BUYABLES=${BUYABLES:-default}
  RETRO_TEMPLATES=${RETRO_TEMPLATES:-default}
  FORWARD_TEMPLATES=${FORWARD_TEMPLATES:-default}
  CHEMICALS=${CHEMICALS:-default}
}

run-mongo-js() {
  # arg 1 is js command
  docker-compose exec -T mongo bash -c 'mongo --username ${MONGO_USER} --password ${MONGO_PW} --authenticationDatabase admin ${MONGO_HOST}/askcos --quiet --eval '"'$1'"
}

seed-db-collection() {
  # arg 1 is collection name
  # arg 2 is file path
  # arg 3 is a flag to pass to docker-compose exec, e.g. -d to detach
  docker-compose exec -T $3 mongo bash -c 'gunzip -c '$2' | mongoimport --host ${MONGO_HOST} --username ${MONGO_USER} --password ${MONGO_PW} --authenticationDatabase admin --db askcos --collection '$1' --type json --jsonArray '${DB_DROP}
}

seed-db() {
  if [ -z "$BUYABLES" ] && [ -z "$CHEMICALS" ] && [ -z "$REACTIONS" ] && [ -z "$RETRO_TEMPLATES" ] && [ -z "$FORWARD_TEMPLATES" ]; then
    echo "Nothing to seed!"
    echo "Example usages:"
    echo "    bash deploy.sh seed-db -r default                  seed only the default retro templates"
    echo "    bash deploy.sh seed-db -r <templates.json.gz>      seed retro templates from local file <templates.json.gz>"
    echo "    bash deploy.sh set-db-defaults seed-db             seed all default collections"
    return
  fi

  echo "Seeding mongo database..."

  if [ "$BUYABLES" = "default" ]; then
    echo "Loading default buyables data in background..."
    buyables_file="/data/app/buyables/buyables.json.gz"
    seed-db-collection buyables "$buyables_file" -d
  elif [ -n "$BUYABLES" ]; then
    echo "Loading buyables data from $BUYABLES in background..."
    buyables_file="/data/app/buyables/$(basename $BUYABLES)"
    docker cp "$BUYABLES" ${COMPOSE_PROJECT_NAME}_mongo_1:"$buyables_file"
    run-mongo-js "db.buyables.remove({})"
    seed-db-collection buyables "$buyables_file" -d
  fi

  if [ "$CHEMICALS" = "default" ]; then
    echo "Loading default chemicals data in background..."
    chemicals_file="/data/app/historian/chemicals.json.gz"
    seed-db-collection chemicals "$chemicals_file" -d
  elif [ -n "$CHEMICALS" ]; then
    echo "Loading chemicals data from $CHEMICALS in background..."
    chemicals_file="/data/app/historian/$(basename $CHEMICALS)"
    docker cp "$CHEMICALS" ${COMPOSE_PROJECT_NAME}_mongo_1:"$chemicals_file"
    seed-db-collection chemicals "$chemicals_file" -d
  fi

  if [ "$REACTIONS" = "default" ]; then
    echo "Loading default reactions data in background..."
    reactions_file="/data/app/historian/reactions.json.gz"
    seed-db-collection reactions "$reactions_file" -d
  elif [ -n "$REACTIONS" ]; then
    echo "Loading reactions data from $REACTIONS in background..."
    reactions_file="/data/app/historian/$(basename $REACTIONS)"
    docker cp "$REACTIONS" ${COMPOSE_PROJECT_NAME}_mongo_1:"$reactions_file"
    seed-db-collection reactions "$reactions_file" -d
  fi

  if [ "$RETRO_TEMPLATES" = "default" ]; then
    echo "Loading default retrosynthetic templates..."
    retro_file="/data/app/templates/retro.templates.json.gz"
    seed-db-collection retro_templates "$retro_file"
  elif [ -n "$RETRO_TEMPLATES" ]; then
    echo "Loading retrosynthetic templates from $RETRO_TEMPLATES ..."
    retro_file="/data/app/templates/$(basename $RETRO_TEMPLATES)"
    docker cp "$RETRO_TEMPLATES" ${COMPOSE_PROJECT_NAME}_mongo_1:"$retro_file"
    seed-db-collection retro_templates "$retro_file"
  fi

  if [ "$FORWARD_TEMPLATES" = "default" ]; then
    echo "Loading default forward templates..."
    forward_file="/data/app/templates/forward.templates.json.gz"
    seed-db-collection forward_templates "$forward_file"
  elif [ -n "$FORWARD_TEMPLATES" ]; then
    echo "Loading forward templates from $FORWARD_TEMPLATES ..."
    forward_file="/data/app/templates/$(basename $FORWARD_TEMPLATES)"
    docker cp "$FORWARD_TEMPLATES" ${COMPOSE_PROJECT_NAME}_mongo_1:"$forward_file"
    seed-db-collection forward_templates "$forward_file"
  fi

  index-db
  echo "Seeding complete."
  echo
}

index-db() {
  if [ "$DROP_INDEXES" = "true" ]; then
    echo "Dropping existing indexes in mongo database..."
    run-mongo-js 'db.buyables.dropIndexes()'
    run-mongo-js 'db.chemicals.dropIndexes()'
    run-mongo-js 'db.reactions.dropIndexes()'
    run-mongo-js 'db.retro_templates.dropIndexes()'
  fi
  echo "Adding indexes to mongo database..."
  run-mongo-js 'db.buyables.createIndex({smiles: 1, source: 1})'
  run-mongo-js 'db.chemicals.createIndex({smiles: 1, template_set: 1})'
  run-mongo-js 'db.reactions.createIndex({reaction_id: 1, template_set: 1})'
  run-mongo-js 'db.retro_templates.createIndex({index: 1, template_set: 1})'
  echo "Indexing complete."
  echo
}

count-mongo-docs() {
  echo "Buyables collection:          $(run-mongo-js "db.buyables.countDocuments({})" | tr -d '\r') / 280469 expected (default)"
  echo "Chemicals collection:         $(run-mongo-js "db.chemicals.countDocuments({})" | tr -d '\r') / 17562038 expected (default)"
  echo "Reactions collection:         $(run-mongo-js "db.reactions.countDocuments({})" | tr -d '\r') / 0 expected (default)"
  echo "Retro template collection:    $(run-mongo-js "db.retro_templates.countDocuments({})" | tr -d '\r') / 163723 expected (default)"
  echo "Forward template collection:  $(run-mongo-js "db.forward_templates.countDocuments({})" | tr -d '\r') / 17089 expected (default)"
}

copy-http-conf() {
  echo "Using http nginx configuration."
  cp nginx.http.conf nginx.conf
}

copy-https-conf() {
  echo "Using https nginx configuration."
  cp nginx.https.conf nginx.conf
  echo
  create-ssl
}

create-ssl() {
  if [ ! -f "askcos.ssl.cert" ]; then
    echo "Creating SSL certificates."
    openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=US/ST=MA/L=BOS/O=askcos/CN=askcos.$RANDOM.com" -keyout askcos.ssl.key -out askcos.ssl.cert
    echo
  fi
}

pull-images() {
  if [ "$LOCAL" = "false" ]; then
    docker pull ${ASKCOS_IMAGE_REGISTRY}askcos-site:${VERSION_NUMBER}
  fi
}

get-image-date() {
  # Retrieve image build date for website footer
  UPDATE_DATE=$(docker inspect -f '{{ .Created }}' ${ASKCOS_IMAGE_REGISTRY}askcos-site:${VERSION_NUMBER})
  UPDATE_DATE=${UPDATE_DATE%T*}  # cut off time, only keeping date
  export UPDATE_DATE
}

start-web-services() {
  if [ ! -f "nginx.conf" ]; then
    echo "Missing nginx configuration file (nginx.conf)!"
    echo "Run 'bash deploy.sh copy-http-conf' or 'bash deploy.sh copy-https-conf' to create."
    echo
    exit 1
  fi
  echo "Starting web services..."
  get-image-date
  docker-compose up -d --remove-orphans nginx app
  echo "Start up complete."
  echo
}

start-tf-server() {
  echo "Starting tensorflow serving worker..."
  docker-compose up -d --remove-orphans template-relevance-reaxys fast-filter
  echo "Start up complete."
  echo
}

start-celery-workers() {
  echo "Starting celery workers..."
  docker-compose up -d --scale cr_network_worker=$n_cr_network_worker \
                       --scale tb_coordinator_mcts=$n_tb_coordinator_mcts \
                       --scale tb_coordinator_mcts_v2=$n_tb_coordinator_mcts_v2 \
                       --scale tb_c_worker=$n_tb_c_worker \
                       --scale sites_worker=$n_sites_worker \
                       --scale selec_worker=$n_selec_worker \
                       --scale impurity_worker=$n_impurity_worker \
                       --scale atom_mapping_worker=$n_atom_mapping_worker \
                       --scale tffp_worker=$n_tffp_worker \
                       --remove-orphans \
                       cr_network_worker tb_coordinator_mcts tb_coordinator_mcts_v2 tb_c_worker \
                       sites_worker selec_worker impurity_worker atom_mapping_worker tffp_worker
  echo "Start up complete."
  echo
}

migrate() {
  echo "Migrating user database..."
  docker-compose exec -T app bash -c "python /usr/local/askcos-site/manage.py makemigrations main"
  docker-compose exec -T app bash -c "python /usr/local/askcos-site/manage.py migrate"
  echo "Migration complete."
  echo
}

export_volume() {
  volume=$1
  directory=$2
  filename=$3
  volume_name=${COMPOSE_PROJECT_NAME}_${volume}
  docker run --rm -v ${volume_name}:/src -v ${directory}:/dest alpine tar -czf /dest/${filename} /src
}

import_volume() {
  volume=$1
  directory=$2
  filename=$3
  volume_name=${COMPOSE_PROJECT_NAME}_${volume}
  docker run --rm -v ${volume_name}:/dest -v ${directory}:/src alpine tar -xzf /src/${filename} -C /dest --strip 1
}

backup() {
  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$(pwd)/backup/$(date +%Y%m%d%s)"
  fi
  mkdir -p ${BACKUP_DIR}
  echo "Backing up data to ${BACKUP_DIR}"
  echo "This may take a few minutes..."
  export_volume mongo_data ${BACKUP_DIR} mongo_data.tar.gz
  export_volume mysql_data ${BACKUP_DIR} mysql_data.tar.gz
  echo "Backup complete."
}

restore() {
  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$(pwd)/backup/$(ls -t backup | head -1)"
  fi
  echo "Restoring data from ${BACKUP_DIR}"
  echo "This may take a few minutes..."
  import_volume mongo_data ${BACKUP_DIR} mongo_data.tar.gz
  import_volume mysql_data ${BACKUP_DIR} mysql_data.tar.gz
  echo "Restore complete."
}

# Handle positional arguments, which should be commands
if [ $# -eq 0 ]; then
  # No arguments
  echo "Must provide a valid task, e.g. deploy|update|migrate."
  echo "See 'deploy.sh help' for more options."
  exit 1;
else
  for arg in "$@"
  do
    case "$arg" in
      clean-data | start-db-services | seed-db | copy-http-conf | copy-https-conf | create-ssl | pull-images | \
      start-web-services | start-tf-server | start-celery-workers | migrate | set-db-defaults | count-mongo-docs | \
      backup | restore | index-db | diff-env )
        # This is a defined function, so execute it
        $arg
        ;;
      deploy)
        # Normal first deployment, do everything
        copy-https-conf
        pull-images
        diff-env
        start-db-services
        start-web-services
        set-db-defaults
        seed-db  # Must occur after starting app
        start-tf-server
        start-celery-workers
        migrate
        ;;
      deploy-http)
        # Deploy with http, only difference is ssl cert creation and nginx conf
        copy-http-conf
        pull-images
        diff-env
        start-db-services
        start-web-services
        set-db-defaults
        seed-db  # Must occur after starting app
        start-tf-server
        start-celery-workers
        migrate
        ;;
      update)
        # Update an existing configuration, database seeding is not performed
        pull-images
        diff-env
        clean-data
        start-db-services
        start-web-services
        start-tf-server
        start-celery-workers
        migrate
        ;;
      start)
        # (Re)start existing deployment
        start-db-services
        start-web-services
        start-tf-server
        start-celery-workers
        ;;
      stop)
        # Stop currently running containers
        docker-compose stop
        ;;
      clean)
        # Clean up current deployment
        echo "This will stop and remove all containers and also remove all data volumes. Are you sure you want to continue?"
        read -rp 'Continue (y/N): ' response
        case "$response" in
          [Yy] | [Yy][Ee][Ss])
            echo "Cleaning deployment."
            docker-compose down -v --remove-orphans
            ;;
          *)
            echo "Doing nothing."
            ;;
        esac
        ;;
      *)
        echo "Error: Unsupported command $1" >&2  # print to stderr
        exit 1;
    esac
  done
fi
