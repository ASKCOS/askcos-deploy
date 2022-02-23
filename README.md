# askcos-deploy
[![askcos-base](https://img.shields.io/badge/-askcos--base-lightgray?style=flat-square)](https://github.com/ASKCOS/askcos-base)
[![askcos-data](https://img.shields.io/badge/-askcos--data-lightgray?style=flat-square)](https://github.com/ASKCOS/askcos-data)
[![askcos-core](https://img.shields.io/badge/-askcos--core-lightgray?style=flat-square)](https://github.com/ASKCOS/askcos-core)
[![askcos-site](https://img.shields.io/badge/-askcos--site-lightgray?style=flat-square)](https://github.com/ASKCOS/askcos-site)
[![askcos-deploy](https://img.shields.io/badge/-askcos--deploy-blue?style=flat-square)](https://github.com/ASKCOS/askcos-deploy)

Deployment scripts for the [`askcos-site`](https://github.com/ASKCOS/askcos-site) web application for the prediction of feasible synthetic routes towards a desired compound and associated tasks related to synthesis planning. Originally developed under the DARPA Make-It program and now being developed under the [MLPDS Consortium](http://mlpds.mit.edu).

## Getting Started

This package provides various deployment and management scripts for [`askcos-site`](https://github.com/ASKCOS/askcos-site).

Software requirements for deployment are Docker and Docker Compose. A basic configuration for Kubernetes is also provided.

The core functions needed for deployment are all contained in the `deploy.sh` script (or `deploy_k8.sh` for Kubernetes deployment). See `deploy.sh -h` for supported commands and options.

Additional information on deployment and releases can be found at [askcos.github.io](https://askcos.github.io).
