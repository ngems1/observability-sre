variable "cluster_name" {
  description = "EKS cluster name (also the prefix of the EBS CSI role)."
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version; pick one in EKS standard support."
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster runs in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the nodes and the control-plane ENIs."
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "Who may reach the public EKS API endpoint."
  type        = list(string)
}

variable "admin_principal_arns" {
  description = "Extra IAM users/roles that get cluster-admin through EKS access entries."
  type        = list(string)
  default     = []
}

variable "log_retention_days" {
  description = "Retention of the control-plane log group."
  type        = number
}

variable "node_instance_types" {
  description = "Instance types of the managed node group."
  type        = list(string)
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT."
  type        = string
}

variable "node_ami_type" {
  description = "EKS AMI type (x86_64 or ARM_64)."
  type        = string
}

variable "node_desired_size" {
  description = "Initial node count."
  type        = number
}

variable "node_min_size" {
  description = "Minimum node count (Cluster Autoscaler lower bound)."
  type        = number
}

variable "node_max_size" {
  description = "Maximum node count (Cluster Autoscaler upper bound)."
  type        = number
}
