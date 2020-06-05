#!/usr/bin/env bash

################################################################################
#
#   ASKCOS Deployment Utilities for Kubernetes
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
  echo "    deploy:                   performs initial deployment steps using http"
  echo "    apply:                    apply all k8 configurations"
  echo "    seed-db:                  seed mongo database with data"
  echo "    clean:                    stop and remove a currently running deployment"
  echo
  echo "Optional arguments:"
  echo "    -b,--buyables             buyables data for reseeding mongo database"
  echo "    -c,--chemicals            chemicals data for reseeding mongo database"
  echo "    -x,--reactions            reactions data for reseeding mongo database"
  echo "    -r,--retro-templates      retrosynthetic template data for reseeding mongo database"
  echo "    -t,--forward-templates    forward template data for reseeding mongo database"
  echo "    -i|--drop-indexes         drop any existing indexes when indexing database with index-db command"
  echo "    -u|--username             deploy token username for docker registry"
  echo "    -p|--password             deploy token password for docker registry"
  echo
  echo "Examples:"
  echo "    bash deploy_k8.sh deploy"
  echo "    bash deploy_k8.sh update -v x.y.z"
  echo "    bash deploy_k8.sh seed-db -r retro-templates.json.gz -b buyables.json.gz"
  echo "    bash deploy_k8.sh clean"
  echo
}

# Default argument values
VERSION=""
BUYABLES=""
CHEMICALS=""
REACTIONS=""
RETRO_TEMPLATES=""
FORWARD_TEMPLATES=""
DROP_INDEXES=false

COMMANDS=""
while (( "$#" )); do
  case "$1" in
    -h|--help|help)
      usage
      exit
      ;;
    -v|--version)
      VERSION=$2
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
    -i|--drop-indexes)
      DROP_INDEXES=true
      shift 1
      ;;
    -u|--username)
      DEPLOY_TOKEN_USERNAME=$2
      shift 2
      ;;
    -p|--password)
      DEPLOY_TOKEN_PASSWORD=$2
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

# Define various functions
create-secret() {
  set +e
  if ! kubectl get secret/regcred &> /dev/null; then
    echo "Creating new secret..."
    if [ -z "$DEPLOY_TOKEN_USERNAME" ]; then
      read -rp 'Deploy token username: ' DEPLOY_TOKEN_USERNAME
    fi
    if [ -z "$DEPLOY_TOKEN_PASSWORD" ]; then
      read -rp 'Deploy token password: ' DEPLOY_TOKEN_PASSWORD
    fi
    kubectl create secret docker-registry regcred --docker-server=registry.gitlab.com --docker-username=$DEPLOY_TOKEN_USERNAME --docker-password=$DEPLOY_TOKEN_PASSWORD
  fi
  set -e
}

start-db-services() {
  echo "Starting database services..."
  kubectl apply -f k8/mysql
  kubectl apply -f k8/mongo
  kubectl apply -f k8/redis
  kubectl apply -f k8/rabbitmq
  echo "Start up complete."
  echo
}

wait-for-mongo() {
  while [[ $(kubectl get pods -l pod=mongo -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do
    echo "Waiting for mongo db to start..." && sleep 1
  done
}

wait-for-django() {
  while [[ $(kubectl get pods -l pod=django -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do
    echo "Waiting for django app to start..." && sleep 1
  done

  kubectl get svc/django
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
  kubectl exec $mongo -- bash -c 'mongo --username ${MONGO_USER} --password ${MONGO_PW} --authenticationDatabase admin ${MONGO_HOST}/askcos --quiet --eval '"'$1'"
}

seed-db-collection() {
  # arg 1 is collection name
  # arg 2 is file path
  kubectl exec $mongo -- bash -c 'gunzip -c '$2' | mongoimport --host ${MONGO_HOST} --username ${MONGO_USER} --password ${MONGO_PW} --authenticationDatabase admin --db askcos --collection '$1' --type json --jsonArray --drop'
}

copy-file() {
  # Convenience function for copying files using kubectl exec
  # Not using kubectl cp because it does not support symlinks
  src_pod=$1
  src_path=$2
  src_cont=$3
  dst_pod=$4
  dst_path=$5
  dst_cont=$6

  if [ -n "$src_pod" ] && [ -z "$dst_pod" ]; then
    # copying from pod to local
    if [ -n "$src_cont" ]; then
      kubectl exec "$src_pod" -c "$src_cont" -- tar cf - -C "$(dirname "$src_path")" "$(basename "$src_path")" | tar xf - -C "$(dirname "$dst_path")"
    else
      kubectl exec "$src_pod" -- tar cf - -C "$(dirname "$src_path")" "$(basename "$src_path")" | tar xf - -C "$(dirname "$dst_path")"
    fi
  elif [ -n "$src_pod" ] && [ -n "$dst_pod" ]; then
    # copying from pod to pod, copy to /tmp first
    tmp="$(mktemp -d /tmp/askcos.XXXXXXXX)/$(basename "$src_path")"
    if [ -n "$src_cont" ]; then
      kubectl exec "$src_pod" -c "$src_cont" -- tar cf - -C "$(dirname "$src_path")" "$(basename "$src_path")" | tar xf - -C "$(dirname "$tmp")"
    else
      kubectl exec "$src_pod" -- tar cf - -C "$(dirname "$src_path")" "$(basename "$src_path")" | tar xf - -C "$(dirname "$tmp")"
    fi
    src_path="$tmp"
  fi

  if [ -n "$dst_pod" ]; then
    # copying to a pod
    if [ -n "$dst_cont" ]; then
      tar cf - -C "$(dirname "$src_path")" "$(basename "$src_path")" | kubectl exec -i "$dst_pod" -c "$dst_cont" -- tar xf - -C "$(dirname "$dst_path")"
    else
      tar cf - -C "$(dirname "$src_path")" "$(basename "$src_path")" | kubectl exec -i "$dst_pod" -- tar xf - -C "$(dirname "$dst_path")"
    fi
  fi

  if [ -d "$tmp" ]; then
    rm -rf "$tmp"
  fi
}

seed-db() {
  if [ -z "$BUYABLES" ] && [ -z "$CHEMICALS" ] && [ -z "$REACTIONS" ] && [ -z "$RETRO_TEMPLATES" ] && [ -z "$FORWARD_TEMPLATES" ]; then
    echo "Nothing to seed!"
    echo "Example usages:"
    echo "    bash deploy_k8.sh seed-db -r default                  seed only the default retro templates"
    echo "    bash deploy_k8.sh seed-db -r <templates.json.gz>      seed retro templates from local file <templates.json.gz>"
    echo "    bash deploy_k8.sh set-db-defaults seed-db             seed all default collections"
    return
  fi

  echo "Seeding mongo database..."

  django=$(kubectl get pod -l pod=django -o jsonpath="{.items[0].metadata.name}")
  mongo=$(kubectl get pod -l pod=mongo -o jsonpath="{.items[0].metadata.name}")

  if [ -n "$BUYABLES" ]; then
    if [ "$BUYABLES" = "default" ]; then
      echo "Loading default buyables data in background..."
      buyables_src="/usr/local/ASKCOS/makeit/data/buyables/buyables.json.gz"
      buyables_dest="/data/buyables.json.gz"
      copy-file "$django" "$buyables_src" django "$mongo" "$buyables_dest" ""
    elif [ -n "$BUYABLES" ]; then
      echo "Loading buyables data from $BUYABLES in background..."
      buyables_src=$BUYABLES
      buyables_dest="/data/$(basename "$BUYABLES")"
      copy-file "" "$buyables_src" "" "$mongo" "$buyables_dest" ""
    fi
    seed-db-collection buyables "$buyables_dest" &> seed-buyables.log &
  fi

  if [ -n "$CHEMICALS" ]; then
    if [ "$CHEMICALS" = "default" ]; then
      echo "Loading default chemicals data in background..."
      chemicals_src="/usr/local/ASKCOS/makeit/data/historian/chemicals.json.gz"
      chemicals_dest="/data/chemicals.json.gz"
      copy-file "$django" "$chemicals_src" django "$mongo" "$chemicals_dest" ""
    elif [ -n "$CHEMICALS" ]; then
      echo "Loading chemicals data from $CHEMICALS in background..."
      chemicals_src=$CHEMICALS
      chemicals_dest="/data/$(basename "$CHEMICALS")"
      copy-file "" "$chemicals_src" "" "$mongo" "$chemicals_dest" ""
    fi
    seed-db-collection chemicals "$chemicals_dest" &> seed-chemicals.log &
  fi

  if [ -n "$REACTIONS" ]; then
    if [ "$REACTIONS" = "default" ]; then
      echo "Loading default reactions data in background..."
      reactions_src="/usr/local/ASKCOS/makeit/data/historian/reactions.json.gz"
      reactions_dest="/data/reactions.json.gz"
      copy-file "$django" "$reactions_src" django "$mongo" "$reactions_dest" ""
    elif [ -n "$REACTIONS" ]; then
      echo "Loading reactions data from $REACTIONS in background..."
      reactions_src=$REACTIONS
      reactions_dest="/data/$(basename "$REACTIONS")"
      copy-file "" "$reactions_src" "" "$mongo" "$reactions_dest" ""
    fi
    seed-db-collection reactions "$reactions_dest" &> seed-reactions.log &
  fi

  if [ -n "$RETRO_TEMPLATES" ]; then
    if [ "$RETRO_TEMPLATES" = "default" ]; then
      echo "Loading default retrosynthetic templates..."
      retro_src="/usr/local/ASKCOS/makeit/data/templates/retro.templates.json.gz"
      retro_dest="/data/retro.templates.json.gz"
      copy-file "$django" "$retro_src" django "$mongo" "$retro_dest" ""
    elif [ -n "$RETRO_TEMPLATES" ]; then
      echo "Loading retrosynthetic templates from $RETRO_TEMPLATES ..."
      retro_src=$RETRO_TEMPLATES
      retro_dest="/data/templates/$(basename "$RETRO_TEMPLATES")"
      copy-file "" "$retro_src" "" "$mongo" "$retro_dest" ""
    fi
    seed-db-collection retro_templates "$retro_dest"
  fi

  if [ -n "$FORWARD_TEMPLATES" ]; then
    if [ "$FORWARD_TEMPLATES" = "default" ]; then
      echo "Loading default retrosynthetic templates..."
      forward_src="/usr/local/ASKCOS/makeit/data/templates/forward.templates.json.gz"
      forward_dest="/data/forward.templates.json.gz"
      copy-file "$django" "$forward_src" django "$mongo" "$forward_dest" ""
    elif [ -n "$FORWARD_TEMPLATES" ]; then
      echo "Loading retrosynthetic templates from $FORWARD_TEMPLATES ..."
      forward_src=$FORWARD_TEMPLATES
      forward_dest="/data/$(basename "$FORWARD_TEMPLATES")"
      copy-file "" "$forward_src" "" "$mongo" "$forward_dest" ""
    fi
    seed-db-collection forward_templates "$forward_dest"
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
  mongo=$(kubectl get pod -l pod=mongo -o jsonpath="{.items[0].metadata.name}")
  echo "Buyables collection:          $(run-mongo-js "db.buyables.countDocuments({})" | tr -d '\r') / 106750 expected (default)"
  echo "Chemicals collection:         $(run-mongo-js "db.chemicals.countDocuments({})" | tr -d '\r') / 17562038 expected (default)"
  echo "Reactions collection:         $(run-mongo-js "db.reactions.countDocuments({})" | tr -d '\r') / 0 expected (default)"
  echo "Retro template collection:    $(run-mongo-js "db.retro_templates.countDocuments({})" | tr -d '\r') / 163723 expected (default)"
  echo "Forward template collection:  $(run-mongo-js "db.forward_templates.countDocuments({})" | tr -d '\r') / 17089 expected (default)"
}

create-config-maps() {
  echo "Creating config maps..."
  kubectl create configmap django-env --from-env-file=.env.example
  kubectl create configmap django-customization --from-env-file=customization.example
}

start-web-services() {
  echo "Starting web services..."
  kubectl apply -f k8/django
  echo "Start up complete."
  echo
}

start-tf-server() {
  echo "Starting tensorflow serving worker..."
  kubectl apply -f k8/tf-serving
  echo "Start up complete."
  echo
}

start-celery-workers() {
  echo "Starting celery workers..."
  kubectl apply -f k8/celery
  echo "Start up complete."
  echo
}

# Handle positional arguments, which should be commands
if [ $# -eq 0 ]; then
  # No arguments
  echo "Must provide a valid task, e.g. deploy|apply|update."
  echo "See 'deploy_k8.sh help' for more options."
  exit 1;
else
  for arg in "$@"
  do
    case "$arg" in
      create-secret | start-db-services | start-web-services | set-db-defaults | seed-db | count-mongo-docs | \
      start-tf-server | start-celery-workers | index-db | create-config-maps )
        # This is a defined function, so execute it
        $arg
        ;;
      deploy)
        # Normal first deployment, do everything
        create-secret
        create-config-maps
        start-db-services
        start-web-services
        wait-for-mongo
        wait-for-django
        set-db-defaults
        seed-db  # Must occur after starting app
        start-tf-server
        start-celery-workers
        ;;
      update)
        # Update an existing configuration, database seeding is not performed
        echo "Not implemented."
        ;;
      apply)
        # (Re)apply all configurations, no database seeding
        start-db-services
        start-web-services
        start-tf-server
        start-celery-workers
        ;;
      clean)
        # Clean up current deployment
        echo "This will delete all deployments, services, and pods. Are you sure you want to continue?"
        read -rp 'Continue (y/N): ' response
        case "$response" in
          [Yy] | [Yy][Ee][Ss])
            echo "Cleaning deployment."
            kubectl delete deployments -l app.kubernetes.io/part-of=askcos
            kubectl delete services -l app.kubernetes.io/part-of=askcos
            kubectl delete pods -l app.kubernetes.io/part-of=askcos
            ;;
          *)
            echo "Doing nothing."
            ;;
        esac
        ;;
      *)
        echo "Error: Unsupported command $1" >&2  # print to stderr
        exit 1
        ;;
    esac
  done
fi
