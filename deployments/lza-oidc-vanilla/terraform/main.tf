locals {
  cluster_name = var.cluster_name
  region       = var.cluster_region
  eks_version  = var.eks_version
  environment  = var.environment
  aws_profile  = var.aws_profile

  using_gpu = var.node_instance_type_gpu != null

  # fix ordering using toset
  available_azs_cpu = toset(data.aws_ec2_instance_type_offerings.availability_zones_cpu.locations)
  available_azs_gpu = toset(try(data.aws_ec2_instance_type_offerings.availability_zones_gpu[0].locations, []))

  available_azs = local.using_gpu ? tolist(setintersection(local.available_azs_cpu, local.available_azs_gpu)) : tolist(local.available_azs_cpu)

  az_count = min(length(local.available_azs), 2)
  azs      = slice(local.available_azs, 0, local.az_count)

  tags = {
    Platform        = "kubeflow-on-aws"
    KubeflowVersion = "1.7"
  }

  kf_helm_repo_path = var.kf_helm_repo_path


  managed_node_group_cpu = {
    node_group_name = "managed-ondemand-cpu"
    instance_types  = [var.node_instance_type]
    min_size        = 5
    desired_size    = 5
    max_size        = 10
    subnet_ids      = [module.sea_network.app_subnet_a.id, module.sea_network.app_subnet_b.id]
  }

  managed_node_group_gpu = local.using_gpu ? {
    node_group_name = "managed-ondemand-gpu"
    instance_types  = [var.node_instance_type_gpu]
    min_size        = 3
    desired_size    = 3
    max_size        = 5
    ami_type        = "AL2_x86_64_GPU"
    subnet_ids      = [module.sea_network.app_subnet_a.id, module.sea_network.app_subnet_b.id]
  } : null

  potential_managed_node_groups = {
    mg_cpu = local.managed_node_group_cpu,
    mg_gpu = local.managed_node_group_gpu
  }

  managed_node_groups = { for k, v in local.potential_managed_node_groups : k => v if v != null }
}

data "aws_ec2_instance_type_offerings" "availability_zones_cpu" {
  filter {
    name   = "instance-type"
    values = [var.node_instance_type]
  }

  location_type = "availability-zone"
}

data "aws_ec2_instance_type_offerings" "availability_zones_gpu" {
  count = local.using_gpu ? 1 : 0

  filter {
    name   = "instance-type"
    values = [var.node_instance_type_gpu]
  }

  location_type = "availability-zone"
}

module "ceai_lib" {
  source = "github.com/CQEN-QDCE/ceai-cqen-terraform-lib?ref=dev"
}

module "sea_network" {
  source = "./.terraform/modules/ceai_lib/aws/sea-network"
  
  aws_profile = local.aws_profile
  workload_account_type = local.environment
}

#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.32.1"

  cluster_name    = local.cluster_name
  cluster_version = local.eks_version

  vpc_id             = module.sea_network.shared_vpc.id
  private_subnet_ids = [module.sea_network.app_subnet_a.id, module.sea_network.app_subnet_b.id]

  # configuration settings: https://github.com/aws-ia/terraform-aws-eks-blueprints/blob/main/modules/aws-eks-managed-node-groups/locals.tf
  managed_node_groups = local.managed_node_groups
  tags                = local.tags
}

resource "null_resource" "kubeconfig" {
  provisioner "local-exec" {
    command = "aws eks --region ${local.region} update-kubeconfig --name ${local.cluster_name} --profile ${local.aws_profile}"
  }
  depends_on = [ module.eks_blueprints ]
}

resource "null_resource" "storage_class" {
  provisioner "local-exec" {
    command = "kubectl apply -f .././base/sc-gp2.yml --force"
  }
  depends_on = [ null_resource.kubeconfig ]
}

module "eks_blueprints_kubernetes_addons" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints//modules/kubernetes-addons?ref=v4.32.1"

  eks_cluster_id       = module.eks_blueprints.eks_cluster_id
  eks_cluster_endpoint = module.eks_blueprints.eks_cluster_endpoint
  eks_oidc_provider    = module.eks_blueprints.oidc_provider
  eks_cluster_version  = module.eks_blueprints.eks_cluster_version

  # EKS Managed Add-ons
  enable_amazon_eks_vpc_cni            = true
  enable_amazon_eks_coredns            = true
  amazon_eks_coredns_config = {
    most_recent        = true
    kubernetes_version = local.eks_version
    resolve_conflicts  = "OVERWRITE"
  }

  enable_amazon_eks_kube_proxy         = true
  amazon_eks_kube_proxy_config = {
    most_recent        = true
    kubernetes_version = local.eks_version
    resolve_conflicts  = "OVERWRITE"
  }

  
  amazon_eks_aws_ebs_csi_driver_config = {
    resolve_conflicts        = "OVERWRITE"
    most_recent        = true
    kubernetes_version = local.eks_version
  }

  enable_amazon_eks_aws_ebs_csi_driver = true


  # EKS Blueprints Add-ons
  enable_cert_manager                 = true
  enable_aws_load_balancer_controller = true

  aws_efs_csi_driver_helm_config = {
    namespace = "kube-system"
    version   = "2.4.1"
  }

  enable_aws_efs_csi_driver = true

  enable_nvidia_device_plugin = local.using_gpu

  enable_karpenter = true

  tags = local.tags

  depends_on = [ null_resource.storage_class ]
}


#todo: update the blueprints repo code to export the desired values as outputs
module "eks_blueprints_outputs" {
  source = "../../../iaac/terraform/utils/blueprints-extended-outputs"

  eks_cluster_id       = module.eks_blueprints.eks_cluster_id
  eks_cluster_endpoint = module.eks_blueprints.eks_cluster_endpoint
  eks_oidc_provider    = module.eks_blueprints.oidc_provider
  eks_cluster_version  = module.eks_blueprints.eks_cluster_version

  tags = local.tags
}

module "kubeflow_components" {
  source = "./oidc-components"

  kf_helm_repo_path              = local.kf_helm_repo_path
  addon_context                  = module.eks_blueprints_outputs.addon_context
  enable_aws_telemetry           = var.enable_aws_telemetry
  notebook_enable_culling        = var.notebook_enable_culling
  notebook_cull_idle_time        = var.notebook_cull_idle_time
  notebook_idleness_check_period = var.notebook_idleness_check_period
  load_balancer_scheme           = var.load_balancer_scheme
  subnet_ids                     = var.subnet_ids
  certificate_arn                = var.certificate_arn
  
  tags = local.tags
}