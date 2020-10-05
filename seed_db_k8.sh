#!/usr/bin/env bash

################################################################################
#
#   Mongo database seeding script for ASKCOS on Kubernetes
#
################################################################################

set -e  # exit with nonzero exit code if anything fails

usage() {
  echo
  echo "Mongo database seeding script for ASKCOS on Kubernetes"
  echo
  echo "Compatible with ASKCOS Helm chart v0.1.0"
  echo
  echo "Arguments:"
  echo "    -b,--buyables                 buyables data to import into mongo database"
  echo "    -c,--chemicals                chemicals data to import into mongo database"
  echo "    -x,--reactions                reactions data to import into mongo database"
  echo "    -r,--retro-templates          retrosynthetic template data to import into mongo database"
  echo "    -t,--forward-templates        forward template data to import into mongo database"
  echo "    -d,--drop                     drop existing collections before seeding new data"
  echo "    --count                       count documents in every collection"
  echo "    --help                        show help"
  echo
  echo "Example:"
  echo "    bash seed_db_k8.sh -r retro-templates.json.gz -b buyables.json.gz"
  echo
}

# Default argument values
BUYABLES=""
CHEMICALS=""
REACTIONS=""
RETRO_TEMPLATES=""
FORWARD_TEMPLATES=""
DROP=false
COUNT=false

while (( "$#" )); do
  case "$1" in
    --help)
      usage
      exit
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
    -d|--drop-collections)
      DROP=true
      shift 1
      ;;
    --count)
      COUNT=true
      shift 1
      ;;
    --) # end argument parsing
      shift
      break
      ;;
    -*) # any other flag
      echo "Error: Unsupported flag $1" >&2  # print to stderr
      usage
      exit 1
      ;;
    *) # ignore positional arguments
      shift
      ;;
  esac
done

MONGO_POD=$(kubectl get pod -l app.kubernetes.io/name=mongodb -o jsonpath="{.items[0].metadata.name}")

run_mongo_js() {
  # arg 1 is js command
  kubectl exec $MONGO_POD -- bash -c 'mongo --username ${MONGODB_USERNAME} --password ${MONGODB_PASSWORD} localhost/askcos --quiet --eval '"'$1'"
}

seed_collection() {
  # arg 1 is collection name
  # arg 2 is file path
  kubectl exec $MONGO_POD -- bash -c 'gunzip -c '$2' | mongoimport --username ${MONGODB_USERNAME} --password ${MONGODB_PASSWORD} --db askcos --collection '$1' --type json --jsonArray'${DROP:+ --drop}
}

copy_file() {
  # Copy file into $MONGO_POD
  kubectl cp "$1" "${MONGO_POD}:$2"
  }

seed_db() {
  if [ -n "$BUYABLES" ]; then
    echo "Importing buyables data from $BUYABLES..."
    temp_file="/tmp/$(basename "$BUYABLES")"
    copy_file "$BUYABLES" "$temp_file"
    seed_collection buyables "$temp_file" && echo "Finished importing buyables." &
  fi

  if [ -n "$CHEMICALS" ]; then
    echo "Importing chemicals data from $CHEMICALS..."
    temp_file="/tmp/$(basename "$CHEMICALS")"
    copy_file "$CHEMICALS" "$temp_file"
    seed_collection chemicals "$temp_file" && echo "Finished importing chemicals." &
  fi

  if [ -n "$REACTIONS" ]; then
    echo "Importing reactions data from $REACTIONS..."
    temp_file="/tmp/$(basename "$REACTIONS")"
    copy_file "$REACTIONS" "$temp_file"
    seed_collection reactions "$temp_file" && echo "Finished importing reactions." &
  fi

  if [ -n "$RETRO_TEMPLATES" ]; then
    echo "Importing retrosynthetic templates from $RETRO_TEMPLATES ..."
    temp_file="/tmp/$(basename "$RETRO_TEMPLATES")"
    copy_file "$RETRO_TEMPLATES" "$temp_file"
    seed_collection retro_templates "$temp_file" && echo "Finished importing retro templates." &
  fi

  if [ -n "$FORWARD_TEMPLATES" ]; then
    echo "Importing retrosynthetic templates from $FORWARD_TEMPLATES ..."
    temp_file="/tmp/$(basename "$FORWARD_TEMPLATES")"
    copy_file "$FORWARD_TEMPLATES" "$temp_file"
    seed_collection forward_templates "$temp_file" && echo "Finished importing forward templates." &
  fi

  wait
}

count_docs() {
  echo "Buyables collection:          $(run_mongo_js "db.buyables.estimatedDocumentCount()" | tr -d '\r') / 280469 expected (default)"
  echo "Chemicals collection:         $(run_mongo_js "db.chemicals.estimatedDocumentCount()" | tr -d '\r') / 17562038 expected (default)"
  echo "Reactions collection:         $(run_mongo_js "db.reactions.estimatedDocumentCount()" | tr -d '\r') / 0 expected (default)"
  echo "Retro template collection:    $(run_mongo_js "db.retro_templates.estimatedDocumentCount()" | tr -d '\r') / 163723 expected (default)"
  echo "Forward template collection:  $(run_mongo_js "db.forward_templates.estimatedDocumentCount()" | tr -d '\r') / 17089 expected (default)"
}

seed_db

if [ "$COUNT" = "true" ]; then
  count_docs
fi
