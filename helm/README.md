# Kubernetes Deployment Using Helm

This directory contains a helm chart for deploying ASKCOS to a Kubernetes cluster.

The basic command to install the chart is `helm install <release name> ./askcos`, but you will likely need to specify additional custom values. The release name is a custom identifier you would like to use to label the installation.

At minimum, you should provide the deploy token username and password to allow access to the GitLab registry for downloading images.

```bash
helm install --set imageCredentials.username=XXXX --set imageCredentials.password=YYYY mydeploy ./askcos
```

The ASKCOS image tag to deploy can be overridden by `app.image.tag` value.

```bash
helm install --set imageCredentials.username=XXXX --set imageCredentials.password=YYYY --set app.image.tag=2020.07 mydeploy ./askcos
```

There are many other options which can be changed. The best place to see them is in the `values.yaml` file. Additionally, since the ASKCOS chart uses bitnami charts for mongodb, mysql, rabbitmq, and redis, the full set of configuration options for those charts can be found from the bitnami documentation (specific links are provided in `values.yaml`).

If you are modifying multiple options, it can be useful to write your own `custom_values.yaml` file with those options instead of specifying all of them as command line arguments. Then you would only need to pass your custom values file.

```bash
helm install -f custom_values.yaml mydeploy ./askcos
```

The `custom_values.yaml` file may look like this:

```yaml
imageCredentials:
  username: XXXX
  password: YYYY

app:
  image:
    tag: 2020.07

env:
  ORGANIZATION: mycompany
  ENABLE_SMILES_RESOLVER: "True"

mongodb:
  auth:
    username: mongouser
    password: mongopw
```

Removing the ASKCOS deployment is as simple as `helm uninstall mydeploy`.
