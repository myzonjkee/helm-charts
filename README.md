### Install a new release

`helm install <namespace> <namespace> -n <namespace>`

Example:
`helm install prod-omegadent ./prod-omegadent -n prod-omegadent`

### Upgrade an existing release

`helm upgrade <namespace> <chart-directory> -n <namespace>`

### See what will be applied (dry run)

`helm install <namespace> <chart-directory> --dry-run --debug`

### Uninstall (delete) a release

`helm uninstall <namespace>`
