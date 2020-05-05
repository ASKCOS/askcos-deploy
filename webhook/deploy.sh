#!/usr/bin/env bash

# Continuous Deployment Script for ASKCOS

echo 'Received POST request, executing deploy tasks...'

cd ..

git pull origin dev

bash deploy.sh update -v dev

echo 'Deploy tasks complete.'
