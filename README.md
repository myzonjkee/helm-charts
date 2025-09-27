### Install a new release
`helm install <chart_name> <chart_folder> -n <namespace>`

### Upgrade an existing release
`helm upgrade <chart_name> <chart_folder> -n <namespace>`

helm uninstall managex-dev -n managex
helm install managex-dev ./managex/managex-dev -n managex
helm upgrade managex-dev ./managex/managex-dev -n managex

helm upgrade web-prod ./tenant-omegadent/web-prod -n tenant-omegadent

helm upgrade managex-prod ./tenant-omegadent/managex-prod -n tenant-omegadent

### See what will be applied (dry run)
`helm install <chart_name> <chart_folder> --dry-run --debug`

### Uninstall (delete) a release
`helm uninstall <chart_name> -n <namespace>`
