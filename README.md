# Terraform Collection
A collection of terraform templates that *I* thought were useful.

## Usage
To specify environment variables, use `TF_VAR_<var_name_here>` to pass it to terraform. A `.env.example` is provided.

To run a project, use `./run.sh <subproject>` which loads `.env` for you and defaults to `terraform apply` and `terraform destroy` for you.
- You may also `./run.sh <subproject> <<terraform arg>` to effectively run `terraform <terraform arg>` with the `.env` loaded in the `<subproject>` directory.

## Sub-projects
Some sub-projects included in this repository include:

### `kubernetes-cluster` - A self-managed Kubernetes cluster.
My attempt at a Kubernetes cluster, with some limitations.

#### Features
- Calico Networking
    - Chosen because it seems to be a popular production-ready solution
        - also for the challenge
    - Current set up using `kubernetes-cluster/calico-custom-resources.yaml`
        - Configured with `canReach` on `1.1.1.1` IP detection
        - Uses `192.168.0.0/16` CIDR
- Generates `connect_<server>.sh` scripts for each server it creates
    - SSH keys are generated when TF is run and stored in this directory.
    - SSH session are started without impacting your `known_hosts` file

#### Limitations
- No `ExternalIP`s yet
    - This seems to be specialized to cloud providers, and I don't have a alternative for this yet
    - I tried `MetalLB` but since I'm practicing through cloud providers, it doesn't work.
